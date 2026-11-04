import SwiftUI
import TVCore
import Network
import Darwin

/// Owns the Web Cast server lifecycle: starts and stops it with the feature switch, and hands the
/// server the app's data source. The data source itself is `Store` (see `Store+WebCast.swift`), so the
/// web UI lists and drives the same sources the app shows.
@MainActor @Observable final class WebCastController {
    /// The LAN address a computer opens, once the server is running. nil when off or not started.
    private(set) var address: String?
    /// The reason the server failed to start, shown in Settings instead of a blank page.
    private(set) var errorMessage: String?

    private var attached = false

    /// Binds the server to `store` (once), wires the web UI's hide/show commands, and applies the
    /// current switch.
    func start(with store: Store) async {
        NSLog("[webcast] start(with:) attached=\(attached)")
        if !attached {
            attached = true
            WebCastCommands.shared.hide = { [weak store] key in store?.webCastSetHidden(key, hidden: true) }
            WebCastCommands.shared.show = { [weak store] key in store?.webCastSetHidden(key, hidden: false) }
            WebCastCommands.shared.apply = { [weak self] in Task { await self?.apply() } }
            WebCastServer.shared.attach(store)
        }
        await apply()
    }

    /// Starts or stops the server to match the current enabled/port settings.
    func apply() async {
        #if WEBCAST
        let settings = WebCastSettings.shared
        NSLog("[webcast] apply() enabled=\(settings.enabled) port=\(settings.port)")
        Diagnostics.shared.record(.info, "webcast", "apply enabled=\(settings.enabled) port=\(settings.port)")
        guard settings.enabled else {
            await WebCastServer.shared.stop()
            address = nil
            errorMessage = nil
            return
        }
        do {
            let port = try await WebCastServer.shared.start(on: settings.port)
            address = Self.lanAddress(port: Int(port))
            errorMessage = nil
            NSLog("[webcast] listening on \(Int(port)) address=\(address ?? "nil")")
            Diagnostics.shared.record(.info, "webcast", "listening on \(Int(port)), address=\(address ?? "nil")")
        } catch {
            address = nil
            errorMessage = error.localizedDescription
            NSLog("[webcast] start failed: \(error.localizedDescription)")
            Diagnostics.shared.record(.error, "webcast.start", "\(error.localizedDescription)")
        }
        #else
        address = nil
        errorMessage = nil
        #endif
    }

    /// The best LAN address to show: the Wi-Fi interface's IPv4, else loopback for a local preview.
    static func lanAddress(port: Int) -> String {
        var candidate: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return "http://127.0.0.1:\(port)/" }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            guard let interface = ptr?.pointee else { continue }
            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            candidate = host.withUnsafeBufferPointer { buf in
                String(decoding: buf.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            }
            if name.hasPrefix("en") { break }
        }
        return "http://\(candidate ?? "127.0.0.1"):\(port)/"
    }
}
