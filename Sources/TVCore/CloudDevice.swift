import Foundation
#if os(iOS) || os(tvOS) || os(visionOS)
import os
#endif

/// Which device this is, and what streaming may use on it (#702): an Apple TV HD, an Apple TV 4K, an iPhone SE
/// and an iPad Pro have very different memory, so the cache and the connections are sized per device.
enum CloudDevice {
    enum Family: String, Sendable { case mac, iPhone, iPad, appleTV, other }

    struct Profile: Equatable, Sendable {
        /// "iPhone16,2", "AppleTV14,1", "Mac15,6"; what the system reports.
        let identifier: String
        let family: Family
        /// The most bytes of chunk cache this device gets, and the least.
        let cap: Int, floor: Int
        /// The cache is at most 1/share of the memory the app may still use.
        let share: Int
        /// Connections a stream may grow to.
        let maxConnections: Int
        /// One line for the log.
        let label: String
    }

    private static let mb = 1 << 20

    /// The profile for a device. `memory` is its installed RAM in bytes.
    static func profile(identifier: String, memory: UInt64, appleSilicon: Bool = true, iOSAppOnMac: Bool = false) -> Profile {
        let gb = Double(memory) / Double(1 << 30)
        func make(_ family: Family, _ name: String, cap: Int, floor: Int = 32, share: Int, connections: Int) -> Profile {
            Profile(identifier: identifier, family: family, cap: cap * mb, floor: floor * mb, share: share, maxConnections: connections,
                    label: "\(name) \(identifier) \(String(format: "%.0f", gb)) GB")
        }
        if iOSAppOnMac || identifier.hasPrefix("Mac") || identifier.hasPrefix("iMac") || identifier.hasPrefix("VirtualMac") {
            // The Mac has memory to spare; an Intel Mac's CPU and fans are tighter.
            return appleSilicon ? make(.mac, "Mac", cap: 512, share: 32, connections: 10)
                                : make(.mac, "Intel Mac", cap: 256, share: 48, connections: 8)
        }
        if identifier.hasPrefix("AppleTV") {
            // Apple TV HD (AppleTV5,3) has 2 GB and plays no 4K; the first 4K (AppleTV6,2) has 3 GB; the 2021 and 2022
            // models (AppleTV11,1 and AppleTV14,1) have 4 GB. All decode video in the same memory.
            switch identifier {
            case "AppleTV5,3": return make(.appleTV, "Apple TV HD", cap: 48, floor: 24, share: 10, connections: 4)
            case "AppleTV6,2": return make(.appleTV, "Apple TV 4K (1st gen)", cap: 96, share: 10, connections: 6)
            case "AppleTV11,1", "AppleTV14,1": return make(.appleTV, "Apple TV 4K", cap: 192, share: 10, connections: 8)
            default:
                // A model this build doesn't know: by its memory.
                return gb <= 2.5 ? make(.appleTV, "Apple TV", cap: 48, floor: 24, share: 10, connections: 4)
                    : gb <= 3.5 ? make(.appleTV, "Apple TV", cap: 96, share: 10, connections: 6)
                    : make(.appleTV, "Apple TV", cap: 192, share: 10, connections: 8)
            }
        }
        if identifier.hasPrefix("iPhone") || identifier.hasPrefix("iPad") || identifier.hasPrefix("iPod") {
            let family: Family = identifier.hasPrefix("iPad") ? .iPad : .iPhone
            let name = family == .iPad ? "iPad" : "iPhone"
            // By memory: 3 GB and less (iPhone SE, older iPads), 4 GB, 6 GB, and 8 GB or more (Pro iPads, Pro iPhones).
            if gb <= 3.5 { return make(family, name, cap: 96, share: 8, connections: 6) }
            if gb <= 4.5 { return make(family, name, cap: 160, share: 6, connections: 8) }
            if gb <= 6.5 { return make(family, name, cap: 256, share: 6, connections: 8) }
            return make(family, name, cap: 320, share: 6, connections: 10)
        }
        return make(.other, "Device", cap: 96, share: 8, connections: 6)
    }

    /// Bytes of cache for a profile, given how much memory the app may still use. Halved when the device is saving
    /// power or hot, for it should do less work, not more.
    static func budget(for profile: Profile, available: UInt64, constrained: Bool) -> Int {
        var bytes = min(profile.cap, max(profile.floor, Int(available / UInt64(profile.share))))
        if constrained { bytes = max(profile.floor, bytes / 2) }
        return bytes
    }

    // MARK: This device

    static let current: Profile = {
        let info = ProcessInfo.processInfo
        #if os(macOS)
        let onMac = false
        #elseif os(iOS)
        let onMac = info.isiOSAppOnMac
        #else
        let onMac = false
        #endif
        return profile(identifier: identifier, memory: info.physicalMemory, appleSilicon: appleSilicon, iOSAppOnMac: onMac)
    }()

    static var maxConnections: Int { current.maxConnections }

    static var cacheBudget: Int {
        let info = ProcessInfo.processInfo
        #if os(macOS)
        let available = info.physicalMemory
        #else
        // What the system still lets this app use, not the installed memory.
        let left = UInt64(max(0, os_proc_available_memory()))
        let available = left > 0 ? left : info.physicalMemory / 2
        #endif
        let constrained = info.isLowPowerModeEnabled || info.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        return budget(for: current, available: current.family == .mac ? info.physicalMemory : available, constrained: constrained)
    }

    /// The model identifier. The simulator reports the device it pretends to be in an environment variable.
    static var identifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty { return simulated }
        #if os(macOS)
        return sysctlString("hw.model")
        #else
        return sysctlString("hw.machine")
        #endif
    }

    private static var appleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        // An Intel build on an Apple silicon Mac (Rosetta) still has the fast machine under it.
        var value: Int32 = 0, size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0) == 0 && value == 1
        #endif
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }
}
