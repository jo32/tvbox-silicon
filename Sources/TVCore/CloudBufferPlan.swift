import Foundation
#if os(iOS) || os(tvOS) || os(visionOS)
import os
#endif

/// How far ahead of the player a cloud file is read, and how many chunks are kept: worked out from the
/// device's memory and the video's bitrate, not fixed numbers (#702). A 4K file at 10 MB/s was read 1.6
/// seconds ahead by the old 16 MB window; a low-bitrate file never needed that much.
struct CloudBufferPlan: Equatable {
    /// Chunks fetched ahead of where the player is reading.
    let readAhead: Int
    /// Chunks kept in memory.
    let cacheChunks: Int
    /// How many seconds of playback `readAhead` covers; 0 while the bitrate isn't known.
    let seconds: Double

    /// Before the duration is known, and for reads that aren't playback (remuxing, downloads).
    static let fallback = CloudBufferPlan(readAhead: CloudByteStream.readAhead, cacheChunks: CloudByteStream.cacheChunks, seconds: 0)
    /// What the buffer aims for when the device has the memory.
    static let targetSeconds = 90.0
    static let fewestAhead = 8
    static let fewestCached = 24, mostCached = 192

    /// `budget` is the bytes of memory the cache may use.
    static func make(length: Int, duration: Double?, budget: Int, chunkSize: Int) -> CloudBufferPlan {
        let cached = max(fewestCached, min(mostCached, budget / chunkSize))
        // Video and audio can be read in two places at once, each with its own window, and a few chunks are
        // behind the player for a short step back.
        let room = max(fewestAhead, (cached - 4) / 2)
        guard let duration, duration > 1, length > 0 else {
            return CloudBufferPlan(readAhead: min(CloudByteStream.readAhead, room), cacheChunks: cached, seconds: 0)
        }
        let bytesPerSecond = Double(length) / duration
        let wanted = Int((bytesPerSecond * targetSeconds / Double(chunkSize)).rounded(.up))
        let ahead = min(max(wanted, fewestAhead), room)
        return CloudBufferPlan(readAhead: ahead, cacheChunks: cached, seconds: Double(ahead * chunkSize) / bytesPerSecond)
    }
}

/// What this device can spare for streaming.
enum CloudDevice {
    /// Bytes of memory for the chunk cache: a share of what the system lets the app use, less when the device is
    /// saving power or hot.
    static var cacheBudget: Int {
        let info = ProcessInfo.processInfo
        #if os(macOS)
        var bytes = min(512 << 20, Int(info.physicalMemory / 32))
        #elseif os(tvOS)
        // Apple TV decodes 4K in the same memory.
        var bytes = min(192 << 20, max(48 << 20, Int(os_proc_available_memory()) / 10))
        #else
        var bytes = min(256 << 20, max(48 << 20, Int(os_proc_available_memory()) / 6))
        #endif
        if info.isLowPowerModeEnabled || info.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { bytes /= 2 }
        return bytes
    }

    /// The most connections a stream may grow to when the link can't keep up; it starts on fewer.
    static var maxConnections: Int {
        #if os(macOS)
        10
        #else
        8
        #endif
    }
}
