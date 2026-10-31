import AVFoundation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import TVCore

private func scratch(_ name: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "feedback-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appending(path: name)
}

/// A picture of `width`×`height`, with a GPS location and a camera when `metadata` is set.
private func picture(_ name: String, type: UTType, width: Int, height: Int, metadata: Bool = true) throws -> URL {
    let file = try scratch(name)
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, type.identifier as CFString, 1, nil))
    let properties: [CFString: Any] = metadata ? [
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1.29, kCGImagePropertyGPSLatitudeRef: "N",
                                        kCGImagePropertyGPSLongitude: 103.85, kCGImagePropertyGPSLongitudeRef: "E"],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Test Camera"],
    ] : [:]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return file
}

private func properties(_ file: URL) throws -> [CFString: Any] {
    let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
    return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
}

@Test func feedbackPicturesLoseTheirLocationAndCamera() async throws {
    let photo = try picture("photo.heic", type: .heic, width: 600, height: 400)
    #expect(try properties(photo)[kCGImagePropertyGPSDictionary] != nil)
    let attachment = try await Feedback.attachment(from: photo)
    defer { Feedback.discard([attachment]) }
    // HEIC becomes JPEG, which every browser shows.
    #expect(attachment.kind == .image && attachment.type == "image/jpeg" && attachment.file.pathExtension == "jpg")
    let kept = try properties(attachment.file)
    #expect(kept[kCGImagePropertyGPSDictionary] == nil)
    #expect((kept[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] == nil)
    #expect(kept[kCGImagePropertyPixelWidth] as? Int == 600)
    #expect(attachment.size > 0 && attachment.thumbnail != nil)
    #expect(attachment.file.path.hasPrefix(Feedback.folder.path))

    // A screenshot stays PNG; a huge one is made smaller.
    let screenshot = try picture("screen.png", type: .png, width: 6000, height: 300, metadata: false)
    let small = try await Feedback.attachment(from: screenshot)
    defer { Feedback.discard([small]) }
    #expect(small.type == "image/png")
    #expect(try properties(small.file)[kCGImagePropertyPixelWidth] as? Int == Feedback.pictureSide)
}

@Test func feedbackTakesOnlyPicturesAndVideos() async throws {
    let text = try scratch("notes.txt")
    try Data("hello".utf8).write(to: text)
    await #expect(throws: Feedback.Failure.unsupportedAttachment) { try await Feedback.attachment(from: text) }
    let broken = try scratch("broken.jpg")
    try Data("not a picture".utf8).write(to: broken)
    await #expect(throws: Feedback.Failure.unsupportedAttachment) { try await Feedback.attachment(from: broken) }
}

/// A second of video, tagged with where it was filmed.
private func video() async throws -> URL {
    let file = try scratch("clip.mov")
    let writer = try AVAssetWriter(outputURL: file, fileType: .mov)
    let location = AVMutableMetadataItem()
    location.identifier = .quickTimeMetadataLocationISO6709
    location.value = "+01.2900+103.8500/" as NSString
    location.dataType = kCMMetadataBaseDataType_UTF8 as String
    writer.metadata = [location]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
    ])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<10 {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 20), CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
    return file
}

@Test func feedbackVideosLoseWhereTheyWereFilmed() async throws {
    let clip = try await video()
    let tagged = try await AVURLAsset(url: clip).load(.metadata)
    #expect(tagged.contains { $0.identifier == .quickTimeMetadataLocationISO6709 })
    let attachment = try await Feedback.attachment(from: clip)
    defer { Feedback.discard([attachment]) }
    #expect(attachment.kind == .video && attachment.type == "video/quicktime" && attachment.thumbnail != nil)
    let asset = AVURLAsset(url: attachment.file)
    let kept = try await asset.load(.metadata)
    #expect(!kept.contains { $0.identifier == .quickTimeMetadataLocationISO6709 || $0.commonKey == .commonKeyLocation })
    #expect(try await asset.load(.duration).seconds > 0.5)
}

@Test func feedbackSendsTheLogGzipped() async throws {
    let diagnostics = Diagnostics(directory: try scratch("Logs"))
    diagnostics.record(.error, "player", "start failed error=NSURLErrorDomain -1001")
    let log = try #require(await Feedback.diagnosticLog(diagnostics))
    defer { Feedback.discard([log]) }
    #expect(log.kind == .log && log.type == "application/gzip" && log.thumbnail == nil)
    let gunzip = Process()
    gunzip.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
    gunzip.arguments = ["-c", log.file.path]
    let output = Pipe()
    gunzip.standardOutput = output
    try gunzip.run()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    gunzip.waitUntilExit()
    #expect(gunzip.terminationStatus == 0)
    #expect(text.contains("start failed error=NSURLErrorDomain -1001"))
    #expect(Feedback.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
}

@Test func feedbackSendsTheUploadsIdsWithTheMessage() throws {
    let payload = Feedback.payload("Look", kind: .bug, install: "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0", attachments: ["a", "b"])
    let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
    #expect(json["attachments"] as? [String] == ["a", "b"])
    #expect(Feedback.refusal(Data(#"{"limit":"uploads","max":30,"retryAfter":600}"#.utf8), now: Date(timeIntervalSince1970: 0))
        == .uploadLimit(until: Date(timeIntervalSince1970: 600)))
}

@Test func feedbackUploadProgressCountsEveryFileOncePerPercent() {
    final class Told: @unchecked Sendable { var values: [Double] = [] }
    let told = Told()
    let meter = Feedback.UploadMeter(total: 1000) { told.values.append($0) }
    for sent in stride(from: 0, through: 600, by: 3) { meter.sending(Int64(sent)) }
    meter.finished(600)
    for sent in stride(from: 0, through: 400, by: 1) { meter.sending(Int64(sent)) }
    meter.finished(400)
    #expect(told.values.first == 0 && told.values.last == 1)
    #expect(told.values == told.values.sorted() && told.values.count == 101)
}

/// The server takes the same sizes (UPLOADS in Services/error-reports/src/index.ts).
@Test func feedbackSizeLimitsMatchTheServer() throws {
    let server = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Services/error-reports/src/index.ts")
    let source = try String(contentsOf: server, encoding: .utf8)
    for kind in [Feedback.Attachment.Kind.image, .video, .log] {
        let megabytes = Feedback.sizeLimit(kind) >> 20
        #expect(source.contains("  \(kind.rawValue): { max: \(megabytes) * MB,"), "\(kind)")
    }
    #expect(source.contains("const ATTACHMENTS_MAX = \(Feedback.attachmentLimit + 1);"))
}

/// A server for feedback.test only: uploads of pictures work, the log's fail, and the message is posted.
private final class FeedbackServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var posted: [String: Any] = [:]
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "feedback.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let (status, body): (Int, String)
        if url.path.hasSuffix("/uploads") {
            (status, body) = url.query?.contains("kind=log") == true ? (404, "") : (201, #"{"id":"picture-1"}"#)
        } else {
            let stream = request.httpBodyStream!
            stream.open()
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
            Self.posted = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            (status, body) = (201, #"{"number":7,"url":"https://github.com/x/y/issues/7"}"#)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func feedbackGoesWithoutTheLogWhenTheServerWontTakeIt() async throws {
    URLProtocol.registerClass(FeedbackServer.self)
    defer { URLProtocol.unregisterClass(FeedbackServer.self) }
    let defaults = try #require(UserDefaults(suiteName: "feedback-log-\(UUID().uuidString)"))
    defaults.set("https://feedback.test/v1/feedback", forKey: "qaFeedback")
    let picture = try await Feedback.attachment(from: try picture("shot.png", type: .png, width: 40, height: 40, metadata: false))
    let diagnostics = Diagnostics(directory: try scratch("Logs"))
    diagnostics.record(.info, "test", "line")
    let log = try #require(await Feedback.diagnosticLog(diagnostics))
    defer { Feedback.discard([picture, log]) }
    let issue = try await Feedback.send("Look", kind: .bug, attachments: [picture, log], defaults: defaults)
    #expect(issue.number == 7)
    #expect(FeedbackServer.posted["attachments"] as? [String] == ["picture-1"])
}

/// Another window's page (on the Mac) can be about to send its copies: opening the page only clears day-old ones.
@Test func feedbackKeepsCopiesAnotherPageMaySend() async throws {
    let manager = FileManager.default
    try manager.createDirectory(at: Feedback.folder, withIntermediateDirectories: true)
    let old = Feedback.folder.appending(path: "stale-\(UUID().uuidString).jpg")
    try Data([1]).write(to: old)
    try manager.setAttributes([.modificationDate: Date.now.addingTimeInterval(-2 * Feedback.staleAge)], ofItemAtPath: old.path)
    // A GIF is copied as it is, so the copy starts with the original's date.
    let gif = try picture("old.gif", type: .gif, width: 40, height: 30, metadata: false)
    try manager.setAttributes([.modificationDate: Date.now.addingTimeInterval(-400 * 86400)], ofItemAtPath: gif.path)
    let fresh = try await Feedback.attachment(from: gif)
    defer { Feedback.discard([fresh]) }
    #expect(fresh.type == "image/gif")

    Feedback.discardStale()
    #expect(!manager.fileExists(atPath: old.path))
    #expect(manager.fileExists(atPath: fresh.file.path))
}
