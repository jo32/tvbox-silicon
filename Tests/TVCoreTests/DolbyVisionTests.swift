import CoreVideo
import Foundation
import Testing
import TVMedia
@testable import TVCore

/// Dolby Vision 5 reshaped into BT.2020 PQ: `tvm_dovi_pixel` on the CPU, `tvm_compose` on the GPU.
struct DolbyVisionTests {
    /// A mapping that keeps its reshaped samples as they are: no offset, LMS and RGB unchanged.
    private func passThrough() -> TVMReshaping {
        var mapping = TVMReshaping()
        for i in [0, 4, 8] { mapping.set(\.toLMS, i, Float(1)); mapping.set(\.toRGB, i, Float(1)) }
        return mapping
    }

    private func pixel(_ mapping: TVMReshaping, _ y: Float, _ cb: Float, _ cr: Float) -> [Float] {
        var mapping = mapping
        let ycc = [y, cb, cr]
        var rgb = [Float](repeating: 0, count: 3)
        tvm_dovi_pixel(&mapping, ycc, &rgb)
        return rgb
    }

    @Test func samplesAreReshapedPieceByPiece() {
        var mapping = passThrough()
        // Y: x below 0.5, 0.1 + 0.5x + 0.4x² from there to 0.9.
        mapping.set(\.pieces, 0, Int32(2))
        for (i, pivot) in [Float(0), 0.5, 0.9].enumerated() { mapping.set(\.pivots, i, pivot) }
        mapping.set(\.poly, 1, Float(1))
        for (k, value) in [Float(0.1), 0.5, 0.4].enumerated() { mapping.set(\.poly, 3 + k, value) }
        // Cb: a regression on all three, of order 2: 0.2 + 0.1y + 0.2cb + 0.3cr + 0.5y².
        mapping.set(\.pieces, 1, Int32(1))
        mapping.set(\.pivots, 9 + 1, Float(1))
        mapping.set(\.method, 8, Int32(1))
        mapping.set(\.order, 8, Int32(2))
        mapping.set(\.mmrConstant, 8, Float(0.2))
        for (k, value) in [Float(0.1), 0.2, 0.3].enumerated() { mapping.set(\.mmr, 8 * 3 * 7 + k, value) }
        mapping.set(\.mmr, 8 * 3 * 7 + 7, Float(0.5))
        // Cr: 0.3 whatever it was.
        mapping.set(\.pieces, 2, Int32(1))
        mapping.set(\.pivots, 18 + 1, Float(1))
        mapping.set(\.poly, 16 * 3, Float(0.3))
        func close(_ a: [Float], _ b: [Float]) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) < 0.001 } }
        #expect(close(pixel(mapping, 0.25, 0.5, 0.25), [0.25, 0.43125, 0.3]))
        // Y is held at its last pivot, also where Cb's regression reads it.
        #expect(close(pixel(mapping, 0.95, 0.5, 0.25), [0.874, 0.87, 0.3]))
        #expect(close(pixel(mapping, 0.75, 0.5, 0.25), [0.7, 0.73125, 0.3]))
    }

    @Test func theGPUMapsAsTheCPUDoes() throws {
        let file = try #require(Bundle.module.url(forResource: "remux-dv5-reshape", withExtension: "mkv", subdirectory: "Fixtures"))
        var error = [CChar](repeating: 0, count: 256)
        let input = try #require(tvm_open_file(file.path, &error, Int32(error.count)))
        defer { tvm_close(input) }
        var mapping = TVMReshaping()
        #expect(tvm_dovi_first(input, 0, &mapping) == 0)
        #expect(mapping.pieces.0 > 0 && mapping.pieces.1 > 0 && mapping.pieces.2 > 0 && mapping.offset.1 > 0.4)
        let composer = try #require(tvm_composer_create())
        defer { tvm_composer_free(composer) }
        let (width, height) = (64, 32)
        // A ramp of Y in each picture, its chroma the same throughout (so sampling it can't differ).
        for (cb, cr) in [(512, 512), (400, 600), (620, 450), (300, 300)] {
            let source = try buffer(width, height), target = try buffer(width, height)
            fill(source) { plane, x, y in plane == 0 ? 64 + (x + y * width) * 876 / (width * height - 1) : x % 2 == 0 ? cb : cr }
            #expect(tvm_compose(composer, &mapping, Unmanaged.passUnretained(source).toOpaque(), Unmanaged.passUnretained(target).toOpaque()) == 0)
            var worst = 0
            read(target) { luma, chroma in
                for y in 0..<height {
                    for x in 0..<width {
                        let rgb = pixel(mapping, Float(64 + (x + y * width) * 876 / (width * height - 1)) / 1024, Float(cb) / 1024, Float(cr) / 1024)
                        let expected = 0.2627 * rgb[0] + 0.678 * rgb[1] + 0.0593 * rgb[2]
                        worst = max(worst, abs(luma(x, y) - Int((64 + 876 * expected).rounded())))
                        if x % 2 == 0, y % 2 == 0 {
                            // Its chroma is the 2×2 block's average; a flat Cb and Cr give the same at each pixel only
                            // where Y is flat too, so the block's own four are averaged.
                            var sums: (Float, Float) = (0, 0)
                            for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                                let value = Float(64 + (x + dx + (y + dy) * width) * 876 / (width * height - 1)) / 1024
                                let c = pixel(mapping, value, Float(cb) / 1024, Float(cr) / 1024)
                                let luma = 0.2627 * c[0] + 0.678 * c[1] + 0.0593 * c[2]
                                sums.0 += (c[2] - luma) / 1.8814 / 4; sums.1 += (c[0] - luma) / 1.4746 / 4
                            }
                            worst = max(worst, abs(chroma(x / 2, y / 2, 0) - Int((512 + 896 * sums.0).rounded())))
                            worst = max(worst, abs(chroma(x / 2, y / 2, 1) - Int((512 + 896 * sums.1).rounded())))
                        }
                    }
                }
            }
            // Within a few 10-bit codes: the GPU's arithmetic is its own.
            #expect(worst <= 3, "cb=\(cb) cr=\(cr) worst=\(worst)")
        }
    }

    /// A 10-bit 4:2:0 picture in limited range (`x420`) the GPU can use.
    private func buffer(_ width: Int, _ height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, attributes as CFDictionary, &buffer)
        return try #require(buffer)
    }

    /// Sets each 10-bit code: `value(plane, x, y)`, x counting Cb and Cr apart in the chroma plane.
    private func fill(_ buffer: CVPixelBuffer, _ value: (Int, Int, Int) -> Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!, stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let columns = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
            for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                let row = (base + y * stride).assumingMemoryBound(to: UInt16.self)
                for x in 0..<columns { row[x] = UInt16(value(plane, x, y) << 6) }
            }
        }
    }

    /// Hands `body` the 10-bit codes of Y at (x, y) and of chroma `component` (0 Cb, 1 Cr) at its own (x, y).
    private func read(_ buffer: CVPixelBuffer, _ body: ((Int, Int) -> Int, (Int, Int, Int) -> Int) -> Void) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!, lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!, chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        body({ x, y in Int((luma + y * lumaStride).assumingMemoryBound(to: UInt16.self)[x] >> 6) },
             { x, y, component in Int((chroma + y * chromaStride).assumingMemoryBound(to: UInt16.self)[x * 2 + component] >> 6) })
    }
}

private extension TVMReshaping {
    /// Sets the `index`th value of the (C array) field at `key`, counted as if it were flat.
    mutating func set<Field, Value>(_ key: WritableKeyPath<TVMReshaping, Field>, _ index: Int, _ value: Value) {
        let offset = MemoryLayout<TVMReshaping>.offset(of: key)! + index * MemoryLayout<Value>.stride
        withUnsafeMutableBytes(of: &self) { $0.storeBytes(of: value, toByteOffset: offset, as: Value.self) }
    }
}
