import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A TV or box on this network that plays what it is sent: a UPnP/DLNA media renderer (投屏 to DLNA, #749).
public struct DLNADevice: Identifiable, Hashable, Sendable {
    /// The device's UDN, the same however it was found.
    public let id: String
    public let name: String
    public let model: String
    /// Its description document; the host is the device's address.
    public let location: URL
    /// Where AVTransport actions go: load, play, pause, seek, stop.
    public let avTransport: URL
    /// Where RenderingControl actions go (volume); some renderers have none.
    public let renderingControl: URL?

    public init(id: String, name: String, model: String, location: URL, avTransport: URL, renderingControl: URL?) {
        self.id = id; self.name = name; self.model = model; self.location = location
        self.avTransport = avTransport; self.renderingControl = renderingControl
    }
}

/// The DLNA pieces a sender needs: SSDP search, device descriptions, SOAP actions and DIDL-Lite metadata.
public enum DLNA {
    static let group = "239.255.255.250"
    static let port: UInt16 = 1900
    static let rendererType = "urn:schemas-upnp-org:device:MediaRenderer:1"
    static let avTransportType = "urn:schemas-upnp-org:service:AVTransport:1"
    static let renderingType = "urn:schemas-upnp-org:service:RenderingControl:1"

    public enum Failure: LocalizedError, Sendable {
        /// The device answered with an error (UPnP code and description when it gave them).
        case refused(device: String, action: String, detail: String)
        case unreachable(String)
        public var errorDescription: String? {
            switch self {
            case .refused(let device, _, let detail):
                detail.isEmpty ? L10n.text("%@ refused the video.", device) : L10n.text("%@ refused the video (%@).", device, detail)
            case .unreachable(let device):
                L10n.text("%@ didn't respond. Make sure it is on and on the same network.", device)
            }
        }
    }

    /// An M-SEARCH for media renderers. `host` is the multicast group, or the device itself for a unicast search
    /// (UPnP 1.1), which takes no MX.
    static func search(host: String = group) -> String {
        var lines = ["M-SEARCH * HTTP/1.1", "HOST: \(host):\(port)", "MAN: \"ssdp:discover\""]
        if host == group { lines.append("MX: 2") }
        lines += ["ST: \(rendererType)", "USER-AGENT: iOS/17 UPnP/1.1 Yingxia/1.0", "", ""]
        return lines.joined(separator: "\r\n")
    }

    /// The description address in a search response, or nil for anything else (another device's search, say).
    static func location(inResponse text: String) -> URL? {
        guard text.hasPrefix("HTTP/1.1 200") || text.hasPrefix("HTTP/1.0 200") || text.hasPrefix("NOTIFY") else { return nil }
        for line in text.components(separatedBy: "\n") {
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("LOCATION") == .orderedSame else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: value), url.scheme == "http", url.host() != nil else { return nil }
            return url
        }
        return nil
    }

    /// The renderer a description document describes, or nil when it has no AVTransport (a media server, a router).
    static func device(fromDescription data: Data, location: URL) -> DLNADevice? {
        let reader = DescriptionReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() || reader.services.contains(where: { $0.type.contains("AVTransport") }) else { return nil }
        let base = reader.urlBase.flatMap(URL.init(string:)) ?? location
        func control(_ kind: String) -> URL? {
            guard let service = reader.services.first(where: { $0.type.contains(":service:\(kind):") }), !service.control.isEmpty else { return nil }
            return resolve(service.control, against: base)
        }
        guard let transport = control("AVTransport") else { return nil }
        let name = reader.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = reader.udn.isEmpty ? location.absoluteString : reader.udn
        return DLNADevice(id: id, name: name.isEmpty ? (location.host() ?? "TV") : name, model: reader.model,
                          location: location, avTransport: transport, renderingControl: control("RenderingControl"))
    }

    /// A control address from a description, against its base. Not `URL(string:relativeTo:)`: Xiaomi's TVs name theirs
    /// `_urn:schemas-upnp-org:service:AVTransport_control`, which reads as a URL scheme.
    static func resolve(_ control: String, against base: URL) -> URL? {
        let control = control.trimmingCharacters(in: .whitespacesAndNewlines)
        if control.lowercased().hasPrefix("http://") || control.lowercased().hasPrefix("https://") { return URL(string: control) }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let parts = control.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0]).removingPercentEncoding ?? String(parts[0])
        if path.hasPrefix("/") { components.path = path }
        else {
            let directory = components.path.hasSuffix("/") ? components.path : (components.path as NSString).deletingLastPathComponent
            components.path = (directory.hasSuffix("/") ? directory : directory + "/") + path
        }
        components.query = parts.count > 1 ? String(parts[1]) : nil
        components.fragment = nil
        return components.url
    }

    /// The SOAP body of `action` on `service`, arguments in the order the service lists them.
    static func envelope(action: String, service: String, arguments: [(String, String)]) -> Data {
        let fields = arguments.map { "<\($0.0)>\(escape($0.1))</\($0.0)>" }.joined()
        let text = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
            + "<s:Body><u:\(action) xmlns:u=\"\(service)\">\(fields)</u:\(action)></s:Body></s:Envelope>"
        return Data(text.utf8)
    }

    /// Each element's text in a SOAP answer or fault, by its name without a prefix (the first of each name).
    static func values(in data: Data) -> [String: String] {
        let reader = ValueReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.values
    }

    /// What the device said went wrong in a SOAP fault: "714 Illegal MIME-type", or the code alone.
    static func fault(in data: Data) -> String {
        let values = values(in: data)
        return [values["errorCode"], values["errorDescription"]].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The item the renderer shows and plays: its title and how to fetch it. `protocolInfo` names the type, which
    /// some TVs need to accept the address at all.
    public static func didl(title: String, url: URL, mime: String) -> String {
        "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\""
            + " xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">"
            + "<item id=\"0\" parentID=\"-1\" restricted=\"1\"><dc:title>\(escape(title))</dc:title>"
            + "<upnp:class>object.item.videoItem</upnp:class>"
            + "<res protocolInfo=\"http-get:*:\(mime):*\">\(escape(url.absoluteString))</res></item></DIDL-Lite>"
    }

    /// The type a renderer is told, from the address's extension; MP4 when it names none.
    public static func mime(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m3u8", "m3u": "application/vnd.apple.mpegurl"
        case "mkv": "video/x-matroska"
        case "flv": "video/x-flv"
        case "ts": "video/mp2t"
        case "avi": "video/x-msvideo"
        case "webm": "video/webm"
        case "mov": "video/quicktime"
        default: "video/mp4"
        }
    }

    /// "1:02:03" for a seek target; UPnP's REL_TIME is H+:MM:SS.
    public static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    /// Seconds in a REL_TIME or TrackDuration ("0:01:02", "00:01:02.500"); nil for NOT_IMPLEMENTED and the like.
    public static func seconds(_ clock: String) -> Double? {
        let parts = clock.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3, let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2]) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The addresses of a local network, for a unicast search where multicast isn't allowed. Networks larger
    /// than a /22 are cut to the /24 around this device, so a search stays a few hundred small packets.
    static func neighbours(of address: String, netmask: String) -> [String] {
        func number(_ text: String) -> UInt32? {
            let parts = text.split(separator: ".").compactMap { UInt32($0) }
            guard parts.count == 4, parts.allSatisfy({ $0 < 256 }) else { return nil }
            return parts.reduce(0) { $0 << 8 | $1 }
        }
        guard let own = number(address), var mask = number(netmask), mask != 0 else { return [] }
        if ~mask > 1023 { mask = 0xFFFF_FF00 }
        let network = own & mask, last = network | ~mask
        guard last > network + 1 else { return [] }
        // This device too: a renderer can run on it (another app, or Yingxia on a Mac taking casts).
        return (network + 1..<last).map { "\($0 >> 24).\($0 >> 16 & 255).\($0 >> 8 & 255).\($0 & 255)" }
    }

    /// This device's IPv4 address and netmask on Wi-Fi or Ethernet. With a host given, the interface on that host's
    /// network wins (a Mac on both, say); a VPN's tunnel is never chosen.
    static func localInterface(towards host: String? = nil) -> (address: String, netmask: String)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: [(name: String, address: String, netmask: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), let mask = entry.ifa_netmask,
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            found.append((name, numeric(address), numeric(mask)))
        }
        found.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let host, let target = inet(host) {
            if let match = found.first(where: { entry in
                guard let own = inet(entry.address), let mask = inet(entry.netmask) else { return false }
                return own & mask == target & mask
            }) { return (match.address, match.netmask) }
        }
        return found.first.map { ($0.address, $0.netmask) }
    }

    private static func inet(_ text: String) -> UInt32? {
        var value = in_addr()
        guard inet_pton(AF_INET, text, &value) == 1 else { return nil }
        return UInt32(bigEndian: value.s_addr)
    }

    private static func numeric(_ address: UnsafeMutablePointer<sockaddr>) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return "" }
        return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Reads a device description: the root device's name, model and UDN, and every service with its control address
/// (renderers often keep AVTransport in an embedded device).
private final class DescriptionReader: NSObject, XMLParserDelegate {
    struct Service { var type = "", control = "" }
    var name = "", model = "", udn = ""
    var urlBase: String?
    var services: [Service] = []
    private var service: Service?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if Self.local(element) == "service" { service = Service() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch Self.local(element) {
        case "friendlyName" where name.isEmpty: name = value
        case "modelName" where model.isEmpty: model = value
        case "UDN" where udn.isEmpty: udn = value
        case "URLBase": urlBase = value
        case "serviceType": service?.type = value
        case "controlURL": service?.control = value
        case "service": if let service { services.append(service) }; service = nil
        default: break
        }
        text = ""
    }
    static func local(_ name: String) -> String { name.split(separator: ":").last.map(String.init) ?? name }
}

private final class ValueReader: NSObject, XMLParserDelegate {
    var values: [String: String] = [:]
    private var text = ""
    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) { text = "" }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let name = DescriptionReader.local(element)
        if values[name] == nil, !text.isEmpty { values[name] = text }
        text = ""
    }
}

// MARK: - Finding renderers

/// Looks for renderers with SSDP. Multicast needs no entitlement on macOS; on iOS it needs Apple's multicast
/// networking entitlement, and without it the search goes to each address of the local network in turn (a unicast
/// M-SEARCH, which UPnP 1.1 devices answer), which needs only Local Network access.
public enum DLNADiscovery {
    public struct Result: Sendable {
        public var devices: [DLNADevice]
        /// The multicast search couldn't be sent, so only devices that answer a unicast search were found.
        public var multicastBlocked: Bool
    }

    /// Searches for `seconds`, then reads each answering device's description. Runs off the main thread.
    public static func search(seconds: Double = 3, forceUnicast: Bool = false) async -> Result {
        let (locations, blocked) = await withCheckedContinuation { (continuation: CheckedContinuation<([URL], Bool), Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: collectLocations(seconds: seconds, forceUnicast: forceUnicast))
            }
        }
        let devices = await withTaskGroup(of: DLNADevice?.self) { group in
            for location in locations { group.addTask { await describe(location) } }
            var found: [String: DLNADevice] = [:]
            for await device in group { if let device, found[device.id] == nil { found[device.id] = device } }
            return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        Diagnostics.shared.record(.info, "dlna", "search answers=\(locations.count) renderers=\(devices.count) multicast=\(blocked ? "blocked" : "ok")")
        return Result(devices: devices, multicastBlocked: blocked)
    }

    /// The renderer at a description address (a device whose address the viewer knows, say).
    public static func describe(_ location: URL) async -> DLNADevice? {
        var request = URLRequest(url: location, timeoutInterval: 4)
        request.setValue("Yingxia/1.0 UPnP/1.1", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return DLNA.device(fromDescription: data, location: location)
    }

    private static func collectLocations(seconds: Double, forceUnicast: Bool) -> ([URL], Bool) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return ([], false) }
        defer { close(fd) }
        var any = sockaddr_in()
        any.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        any.sin_family = sa_family_t(AF_INET)
        any.sin_addr = in_addr(s_addr: INADDR_ANY)
        _ = withUnsafePointer(to: &any) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        let interface = DLNA.localInterface()
        if let interface {
            // On the LAN itself: with a VPN up, the default route would take the search into the tunnel.
            var outgoing = in_addr(s_addr: inet_addr(interface.address))
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &outgoing, socklen_t(MemoryLayout<in_addr>.size))
        }
        var ttl: UInt8 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        func send(_ text: String, to host: String) -> Bool {
            var destination = sockaddr_in()
            destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            destination.sin_family = sa_family_t(AF_INET)
            destination.sin_port = DLNA.port.bigEndian
            destination.sin_addr = in_addr(s_addr: inet_addr(host))
            let bytes = Array(text.utf8)
            return withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            } == bytes.count
        }

        var blocked = forceUnicast
        if !forceUnicast {
            // Twice, as UDP may drop one.
            blocked = !send(DLNA.search(), to: DLNA.group)
            if blocked { Diagnostics.shared.record(.info, "dlna", "multicast search not sent errno=\(errno)") }
            else { _ = send(DLNA.search(), to: DLNA.group) }
        }
        var unicast: [String] = []
        if blocked, let interface { unicast = DLNA.neighbours(of: interface.address, netmask: interface.netmask) }

        var locations: [URL] = [], seen = Set<String>()
        let deadline = Date().addingTimeInterval(seconds)
        var buffer = [UInt8](repeating: 0, count: 8192)
        while Date() < deadline {
            // The unicast search goes out in small batches between reads, so answers aren't lost to a full buffer.
            if !unicast.isEmpty {
                for host in unicast.prefix(32) { _ = send(DLNA.search(host: host), to: host) }
                unicast.removeFirst(min(32, unicast.count))
            }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, unicast.isEmpty ? 200 : 20) > 0 else { continue }
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0, let location = DLNA.location(inResponse: String(decoding: buffer[0..<count], as: UTF8.self)),
                  seen.insert(location.absoluteString).inserted else { continue }
            locations.append(location)
        }
        return (locations, blocked)
    }
}

// MARK: - Controlling a renderer

/// Sends AVTransport and RenderingControl actions to one renderer.
public struct DLNARenderer: Sendable {
    public let device: DLNADevice
    public init(_ device: DLNADevice) { self.device = device }

    /// Gives the TV the address and starts it.
    public func load(_ url: URL, title: String, mime: String) async throws {
        // Some TVs keep the last video until told to stop; a TV that isn't playing anything says so, which is fine.
        _ = try? await transport("Stop", [])
        try await transport("SetAVTransportURI", [("CurrentURI", url.absoluteString),
                                                  ("CurrentURIMetaData", DLNA.didl(title: title, url: url, mime: mime))])
        try await play()
    }
    public func play() async throws { try await transport("Play", [("Speed", "1")]) }
    public func pause() async throws { try await transport("Pause", []) }
    public func stop() async throws { try await transport("Stop", []) }
    public func seek(to seconds: Double) async throws {
        try await transport("Seek", [("Unit", "REL_TIME"), ("Target", DLNA.clock(seconds))])
    }
    /// Where the TV is in the video and how long it is; zero for what it doesn't know.
    public func position() async throws -> (position: Double, duration: Double) {
        let values = try await transport("GetPositionInfo", [])
        return (values["RelTime"].flatMap(DLNA.seconds) ?? 0, values["TrackDuration"].flatMap(DLNA.seconds) ?? 0)
    }
    /// PLAYING, PAUSED_PLAYBACK, STOPPED, TRANSITIONING or NO_MEDIA_PRESENT.
    public func state() async throws -> String {
        try await transport("GetTransportInfo", [])["CurrentTransportState"] ?? ""
    }
    public func volume() async throws -> Int? {
        guard device.renderingControl != nil else { return nil }
        return Int(try await rendering("GetVolume", [("Channel", "Master")])["CurrentVolume"] ?? "")
    }
    public func setVolume(_ volume: Int) async throws {
        guard device.renderingControl != nil else { return }
        try await rendering("SetVolume", [("Channel", "Master"), ("DesiredVolume", String(min(100, max(0, volume))))])
    }

    @discardableResult
    private func transport(_ action: String, _ arguments: [(String, String)]) async throws -> [String: String] {
        try await call(action, service: DLNA.avTransportType, control: device.avTransport, arguments: [("InstanceID", "0")] + arguments)
    }
    @discardableResult
    private func rendering(_ action: String, _ arguments: [(String, String)]) async throws -> [String: String] {
        guard let control = device.renderingControl else { return [:] }
        return try await call(action, service: DLNA.renderingType, control: control, arguments: [("InstanceID", "0")] + arguments)
    }

    private func call(_ action: String, service: String, control: URL, arguments: [(String, String)]) async throws -> [String: String] {
        var request = URLRequest(url: control, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = DLNA.envelope(action: action, service: service, arguments: arguments)
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw DLNA.Failure.unreachable(device.name)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let detail = DLNA.fault(in: data)
            Diagnostics.shared.record(.warning, "dlna", "\(action) refused status=\((response as? HTTPURLResponse)?.statusCode ?? 0) \(detail) model=\(device.model)")
            throw DLNA.Failure.refused(device: device.name, action: action, detail: detail)
        }
        return DLNA.values(in: data)
    }
}
