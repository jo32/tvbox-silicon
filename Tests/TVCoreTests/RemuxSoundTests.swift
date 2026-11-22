import AVFoundation
import Foundation
import Testing
@testable import TVCore

/// The sound a file AVPlayer can't play becomes: converted surround keeps the level it was mixed at (#1406).
extension RemuxTests {
    /// 7.1 folded into 5.1 for AAC: FFmpeg's default scaled the whole mix down by the worst case of every folded
    /// channel peaking at once, 4.6 dB quieter, the dialogue in the centre too.
    @Test func foldedSurroundKeepsItsLevel() async throws {
        let movie = try await Self.surroundMovie()
        defer { try? FileManager.default.removeItem(at: movie) }
        let url = try await Remux.open(try Remux.fileSource(movie))
        defer { Remux.stop(url) }
        let levels = try await Self.levels(of: url, seconds: 3)
        // The centre's tone, then a back surround's, each at -12 dBFS (0.177 RMS) in the 7.1 file: the centre as loud
        // as it was, the back surround -3 dB into the side one.
        let centre = 20 * log10(levels.rms[0] / 0.1768), back = 20 * log10(levels.rms[1] / 0.1768)
        #expect(abs(centre) < 0.5, "centre \(centre) dB, back \(back) dB, \(levels.channels) channels")
        #expect(abs(back + 3) < 0.5, "centre \(centre) dB, back \(back) dB")
        // Every channel near full scale at once: the side and back surrounds together go over, and are rounded off
        // under full scale, not wrapped around or cut flat.
        #expect(levels.peak[2] < 1.02 && levels.rms[2] > 0.6, "peak \(levels.peak[2]), RMS \(levels.rms[2])")
    }

    /// The loudest channel's RMS, and peak, in each second of the converted sound.
    static func levels(of master: URL, seconds: Int) async throws -> (rms: [Double], peak: [Double], channels: Int) {
        let folder = master.deletingLastPathComponent()
        let text = String(decoding: try await URLSession.shared.data(from: master).0, as: UTF8.self)
        // The audio rendition's playlist: the one EXT-X-MEDIA TYPE=AUDIO names.
        let line = try #require(text.split(separator: "\n").first { $0.contains("TYPE=AUDIO") })
        let name = try #require(line.split(separator: "URI=\"").last?.split(separator: "\"").first)
        let playlist = String(decoding: try await URLSession.shared.data(from: folder.appending(path: String(name))).0, as: UTF8.self)
        var data = Data()
        for line in playlist.split(separator: "\n") {
            let part: Substring
            if line.hasPrefix("#EXT-X-MAP:URI=\"") { part = line.dropFirst(16).dropLast() } else if !line.hasPrefix("#") { part = line } else { continue }
            data += try await URLSession.shared.data(from: folder.appending(path: String(part))).0
        }
        let file = FileManager.default.temporaryDirectory.appending(path: "sound-\(UUID().uuidString).mp4")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let asset = AVURLAsset(url: file)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
        reader.add(output)
        reader.startReading()
        var channels = 0, frame = 0
        var sums = [[Double]](repeating: [], count: seconds), counts = [Int](repeating: 0, count: seconds)
        var peaks = [Double](repeating: 0, count: seconds)
        while let buffer = output.copyNextSampleBuffer() {
            guard let format = CMSampleBufferGetFormatDescription(buffer),
                  let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            channels = Int(description.mChannelsPerFrame)
            if sums[0].isEmpty { sums = [[Double]](repeating: [Double](repeating: 0, count: channels), count: seconds) }
            var length = 0, pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            guard let pointer else { continue }
            let samples = UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self), count: length / 4)
            for start in stride(from: 0, to: samples.count, by: channels) {
                defer { frame += 1 }
                // The middle of each second, clear of the encoder's delay and the change between them.
                let rate = Int(description.mSampleRate), at = frame % rate, second = frame / rate
                guard second < seconds, at > rate / 5, at < rate * 4 / 5 else { continue }
                for channel in 0..<channels {
                    let sample = Double(samples[start + channel])
                    sums[second][channel] += sample * sample
                    peaks[second] = max(peaks[second], abs(sample))
                }
                counts[second] += 1
            }
        }
        let rms = (0..<seconds).map { second in sums[second].map { ($0 / Double(max(counts[second], 1))).squareRoot() }.max() ?? 0 }
        return (rms, peaks, channels)
    }

    /// Three seconds of 7.1 LPCM in a QuickTime movie, with a picture: a 1 kHz tone at -12 dBFS in the centre for
    /// the first second, then in the left back surround, then at -1 dBFS in every channel.
    static func surroundMovie() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "surround-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let pictures = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        var layout = AudioChannelLayout(); layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_7_1_C
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 8, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)])
        video.expectsMediaDataInRealTime = false; audio.expectsMediaDataInRealTime = false
        writer.add(video); writer.add(audio)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        // L R C LFE Ls Rs Rls Rrs: the centre is the third, the left back surround the seventh.
        let rate = 48000, chunk = 4800
        var description = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                                      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                                      mBytesPerPacket: 16, mFramesPerPacket: 1, mBytesPerFrame: 16, mChannelsPerFrame: 8,
                                                      mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        func sound(_ start: Int) -> CMSampleBuffer {
            var samples = [Int16](repeating: 0, count: chunk * 8)
            for index in 0..<chunk {
                let frame = start + index, tone = sin(2 * Double.pi * 1000 * Double(frame) / Double(rate))
                if frame < rate * 2 { samples[index * 8 + (frame < rate ? 2 : 6)] = Int16(0.25 * 32767 * tone) }
                else { for channel in 0..<8 { samples[index * 8 + channel] = Int16(0.89 * 32767 * tone) } }
            }
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: samples.count * 2, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: samples.count * 2, flags: 0, blockBufferOut: &block)
            samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: $0.count) }
            var buffer: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: chunk,
                                                                 presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(rate)),
                                                                 packetDescriptions: nil, sampleBufferOut: &buffer)
            return buffer!
        }
        // Ten pictures and ten chunks of sound a second, each given when its input takes more: the writer holds one
        // back until the other catches up, to interleave them.
        var pictureAt = 0, soundAt = 0
        let end = rate * 3
        while pictureAt < end || soundAt < end {
            var moved = false
            if pictureAt < end, video.isReadyForMoreMediaData {
                var picture: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, try #require(pictures.pixelBufferPool), &picture)
                pictures.append(try #require(picture), withPresentationTime: CMTime(value: CMTimeValue(pictureAt), timescale: CMTimeScale(rate)))
                pictureAt += chunk; moved = true
                if pictureAt >= end { video.markAsFinished() }
            }
            if soundAt < end, audio.isReadyForMoreMediaData {
                audio.append(sound(soundAt))
                soundAt += chunk; moved = true
                if soundAt >= end { audio.markAsFinished() }
            }
            if !moved { try await Task.sleep(for: .milliseconds(5)) }
        }
        await writer.finishWriting()
        #expect(writer.status == .completed, "\(String(describing: writer.error))")
        return url
    }
}
