import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: Pictures, videos and the log
// What goes up with a message besides its text: pictures and videos the viewer adds, and the app's
// diagnostic log, which it adds itself. Each is uploaded to the error-report server first
// (Services/error-reports, /v1/feedback/uploads), which keeps it in the bucket behind
// download.getmegaportal.com; the message then names them. Pictures show in the public issue and
// videos are linked from it, so both lose where they were taken and the camera's details when they are
// added. The log goes to the developer only. Everything here runs when the viewer adds a file or sends:
// nothing while the app is in use otherwise.

extension Feedback {
    public struct Attachment: Identifiable, Equatable, Sendable {
        public enum Kind: String, Sendable { case image, video, log }
        public let id: UUID
        public let kind: Kind
        /// A copy of the app's own (in `folder`), deleted once it is sent or removed.
        public let file: URL
        /// The content type the server is told.
        public let type: String
        public let size: Int64
        /// A small JPEG for the page to show; none for the log.
        public let thumbnail: Data?

        init(kind: Kind, file: URL, type: String, thumbnail: Data? = nil) throws {
            id = UUID()
            self.kind = kind
            self.file = file
            self.type = type
            size = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            self.thumbnail = thumbnail
        }
    }

    /// Pictures and videos one message can take. The server takes one more file: the log.
    public static let attachmentLimit = 4

    /// The largest file of each kind, as the server takes it (UPLOADS in Services/error-reports/src/index.ts).
    public static func sizeLimit(_ kind: Attachment.Kind) -> Int64 {
        switch kind {
        case .image: 10 << 20
        case .video: 50 << 20
        case .log: 5 << 20
        }
    }

    /// Pictures are made no larger than this on their longer side.
    static let pictureSide = 4096
    static let thumbnailSide = 240

    /// Where the copies are kept until they are sent.
    static var folder: URL { FileManager.default.temporaryDirectory.appending(path: "Feedback", directoryHint: .isDirectory) }

    /// A picture or video the viewer chose, copied and ready to upload: a picture without its metadata
    /// (location, camera) and no larger than `pictureSide`; a video without where it was filmed or by whom.
    public static func attachment(from source: URL) async throws -> Attachment {
        let values = try? source.resourceValues(forKeys: [.contentTypeKey])
        guard let type = values?.contentType ?? UTType(filenameExtension: source.pathExtension) else { throw Failure.unsupportedAttachment }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let attachment: Attachment
        if type.conforms(to: .movie) || type.conforms(to: .video) {
            attachment = try await video(source)
        } else if type.conforms(to: .image) {
            attachment = try await Task.detached(priority: .userInitiated) { try picture(source, type: type) }.value
        } else {
            throw Failure.unsupportedAttachment
        }
        guard attachment.size <= sizeLimit(attachment.kind) else {
            discard([attachment])
            throw Failure.attachmentTooLarge(attachment.kind)
        }
        return attachment
    }

    static func picture(_ source: URL, type: UTType) throws -> Attachment {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(image) > 0,
              let thumbnail = thumbnail(image) else { throw Failure.unsupportedAttachment }
        // A GIF keeps its frames as it is: it has no location or camera details to lose.
        if type.conforms(to: .gif) {
            let file = folder.appending(path: UUID().uuidString + ".gif")
            try FileManager.default.copyItem(at: source, to: file)
            // The copy keeps the original's date; `discardStale` goes by when it was added.
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return try Attachment(kind: .image, file: file, type: "image/gif", thumbnail: thumbnail)
        }
        // Screenshots stay sharp as PNG; photos (HEIC and the rest) become JPEG, which every browser shows.
        // Drawn again from the pixels, so none of the original's metadata goes with them.
        let png = type.conforms(to: .png)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pictureSide, kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let pixels = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary) else { throw Failure.unsupportedAttachment }
        let file = folder.appending(path: UUID().uuidString + (png ? ".png" : ".jpg"))
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, (png ? UTType.png : .jpeg).identifier as CFString, 1, nil)
        else { throw Failure.unsupportedAttachment }
        CGImageDestinationAddImage(destination, pixels, png ? nil : [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unsupportedAttachment }
        return try Attachment(kind: .image, file: file, type: png ? "image/png" : "image/jpeg", thumbnail: thumbnail)
    }

    static func video(_ source: URL) async throws -> Attachment {
        let asset = AVURLAsset(url: source)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty,
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { throw Failure.unsupportedAttachment }
        // The same picture and sound, without the location and the owner's details.
        session.metadataItemFilter = .forSharing()
        let mp4 = ["mp4", "m4v"].contains(source.pathExtension.lowercased()) && session.supportedFileTypes.contains(.mp4)
        let file = folder.appending(path: UUID().uuidString + (mp4 ? ".mp4" : ".mov"))
        if #available(macOS 15, iOS 18, tvOS 18, *) {
            try await session.export(to: file, as: mp4 ? .mp4 : .mov)
        } else {
            session.outputURL = file
            session.outputFileType = mp4 ? .mp4 : .mov
            await session.export()
            guard session.status == .completed else { throw session.error ?? Failure.unsupportedAttachment }
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbnailSide, height: thumbnailSide)
        let frame = try? await generator.image(at: .zero).image
        return try Attachment(kind: .video, file: file, type: mp4 ? "video/mp4" : "video/quicktime", thumbnail: frame.flatMap(jpeg))
    }

    /// A small JPEG of the first picture in `source`.
    static func thumbnail(_ source: CGImageSource) -> Data? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: thumbnailSide]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).flatMap(jpeg)
    }

    static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// The diagnostic log (Diagnostics.export: this launch's and the ones kept from before, already
    /// redacted), gzipped. nil when there is none or it can't be read: the message goes without it.
    public static func diagnosticLog(_ diagnostics: Diagnostics = .shared) async -> Attachment? {
        guard let export = try? await diagnostics.export() else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> Attachment? in
            guard let data = try? Data(contentsOf: export, options: .mappedIfSafe), !data.isEmpty,
                  let packed = gzip(data), packed.count <= sizeLimit(.log) else { return nil }
            let file = folder.appending(path: UUID().uuidString + ".jsonl.gz")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try packed.write(to: file)
                return try Attachment(kind: .log, file: file, type: "application/gzip")
            } catch { return nil }
        }.value
    }

    /// `data` as a .gz file (RFC 1952): Foundation's raw DEFLATE with gzip's header and trailer.
    static func gzip(_ data: Data) -> Data? {
        guard let deflated = try? (data as NSData).compressed(using: .zlib) as Data else { return nil }
        var result = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff])
        result.append(deflated)
        for value in [crc32(data), UInt32(truncatingIfNeeded: data.count)] {
            withUnsafeBytes(of: value.littleEndian) { result.append(contentsOf: $0) }
        }
        return result
    }

    private static let crcTable: [UInt32] = (0..<256).map { byte in
        (0..<8).reduce(UInt32(byte)) { value, _ in value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
    }

    static func crc32(_ data: Data) -> UInt32 {
        let table = crcTable
        var crc = ~UInt32(0)
        data.withUnsafeBytes { bytes in
            for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        }
        return ~crc
    }

    /// Deletes the copies: once sent, or when the viewer removes one.
    public static func discard(_ attachments: [Attachment]) {
        for attachment in attachments { try? FileManager.default.removeItem(at: attachment.file) }
    }

    /// How old a copy is before `discardStale` takes it.
    static let staleAge: TimeInterval = 86400

    /// Deletes the copies left from before (a page closed without sending) once they are a day old. Not
    /// the newer ones: on the Mac, a page in another window may be about to send them.
    public static func discardStale(now: Date = .now) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > staleAge { try? manager.removeItem(at: file) }
        }
    }

    /// Uploads one file and answers the id the message names it by.
    static func upload(_ attachment: Attachment, to base: URL, install: String, sent: @escaping @Sendable (Int64) -> Void) async throws -> String {
        let address = base.appending(path: "uploads").appending(queryItems: [
            URLQueryItem(name: "install", value: install), URLQueryItem(name: "kind", value: attachment.kind.rawValue),
        ])
        // Seconds without progress, not for the whole upload.
        var request = URLRequest(url: address, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue(attachment.type, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: attachment.file, delegate: UploadProgress(sent))
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300:
            struct Body: Decodable { let id: String }
            guard let body = try? JSONDecoder().decode(Body.self, from: data) else { throw Failure.failed }
            return body.id
        case 413: throw Failure.attachmentTooLarge(attachment.kind)
        case 429: throw refusal(data)
        default: throw Failure.failed
        }
    }

    /// How far the uploads together have got, as a fraction, told only when it moves by a percent.
    final class UploadMeter: @unchecked Sendable {
        private let lock = NSLock()
        private let total: Double
        private let report: @Sendable (Double) -> Void
        private var done: Int64 = 0
        private var told = -1

        init(total: Int64, report: @escaping @Sendable (Double) -> Void) {
            self.total = Double(max(total, 1))
            self.report = report
        }

        /// `sent` bytes of the file being uploaded.
        func sending(_ sent: Int64) { tell { done + sent } }

        /// A file of `size` bytes is up.
        func finished(_ size: Int64) { tell { done += size; return done } }

        private func tell(_ bytes: () -> Int64) {
            lock.lock()
            let fraction = min(Double(bytes()) / total, 1)
            let percent = Int(fraction * 100)
            let changed = percent > told
            if changed { told = percent }
            lock.unlock()
            if changed { report(fraction) }
        }
    }
}

/// Bytes sent so far, from URLSession's upload task.
private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let sent: @Sendable (Int64) -> Void
    init(_ sent: @escaping @Sendable (Int64) -> Void) { self.sent = sent }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        sent(totalBytesSent)
    }
}
