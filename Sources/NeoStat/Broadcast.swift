import Foundation
import Network
import Combine
import Darwin

/// LAN broadcast server: serves the phone/tablet dashboard and a stats feed.
///
/// Deliberately a hand-rolled HTTP/1.1 server on Network.framework rather than
/// a dependency — the whole surface is four routes, and NeoStat has no package
/// dependencies to keep `swift build` a single step on a machine with only
/// Command Line Tools.
///
/// Live updates go out as Server-Sent Events: one long-lived response per
/// device, written to on each sampler tick. Polling would mean waking the
/// sampler on someone else's schedule; SSE lets the Mac stay the clock.
final class Broadcast: ObservableObject {
    static let shared = Broadcast()

    /// Published for the HUD's cast panel.
    @Published private(set) var isOn = false
    @Published private(set) var clients = 0
    @Published private(set) var status = "OFF"
    @Published private(set) var boundPort: UInt16 = 0

    /// Shared secret in the URL. Anything that can reach the port still needs
    /// this, so a stray device on the same café Wi-Fi gets 401 rather than a
    /// live readout of the machine.
    let token: String

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "neostat.cast", qos: .utility)
    private var streams: [Int: NWConnection] = [:]
    private var nextID = 0
    private var latest = Data()
    private var latestWatch = Data()
    private var lastPollAt: CFAbsoluteTime = 0
    private let firstPort: UInt16 = 7777

    private init() {
        let d = UserDefaults.standard
        if let saved = d.string(forKey: "castToken"), saved.count >= 6 {
            token = saved
        } else {
            let t = Self.makeToken()
            d.set(t, forKey: "castToken")
            token = t
        }
    }

    // MARK: Lifecycle

    /// True while something is actually reading, so the sampler knows to keep
    /// running even when the HUD window itself is hidden or occluded.
    var hasDemand: Bool {
        guard isOn else { return false }
        if clients > 0 { return true }
        return CFAbsoluteTimeGetCurrent() - lastPollAt < 15
    }

    func toggle() { isOn ? stop() : start() }

    func start(port: UInt16? = nil) {
        guard listener == nil else { return }
        let wanted = port ?? firstPort
        for candidate in wanted...(wanted + 10) {
            if bind(candidate) { return }
        }
        setStatus("NO PORT")
    }

    private func bind(_ port: UInt16) -> Bool {
        guard let p = NWEndpoint.Port(rawValue: port) else { return false }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // The dashboard is LAN-only by design; nothing here should ride a VPN
        // or cellular interface out of the house.
        params.prohibitedInterfaceTypes = [.cellular]

        guard let l = try? NWListener(using: params, on: p) else { return false }
        // Bonjour so `neostat.local` style discovery works without typing an IP.
        l.service = NWListener.Service(name: "NeoStat", type: "_http._tcp")
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async {
                    self.isOn = true
                    self.boundPort = port
                    self.status = "LIVE"
                    UserDefaults.standard.set(true, forKey: "castOn")
                    FileHandle.standardError.write(Data(">> cast: \(self.url)\n".utf8))
                }
            case .failed(let e):
                // NWError's CustomNSError conformance needs macOS 13.3; this
                // package targets 13.0, so match the one case that matters.
                if case .posix(let code) = e {
                    self.setStatus("ERR \(code.rawValue)")
                } else {
                    self.setStatus("ERROR")
                }
                self.stop()
            case .cancelled:
                self.setStatus("OFF")
            default:
                break
            }
        }
        l.start(queue: queue)
        listener = l
        return true
    }

    func stop() {
        queue.async {
            for (_, c) in self.streams { c.cancel() }
            self.streams.removeAll()
        }
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async {
            self.isOn = false
            self.clients = 0
            self.boundPort = 0
            self.status = "OFF"
            UserDefaults.standard.set(false, forKey: "castOn")
        }
    }

    /// Restores the previous session's state at launch.
    func restore() {
        if Perf.castOn || UserDefaults.standard.bool(forKey: "castOn") { start() }
    }

    private func setStatus(_ s: String) {
        DispatchQueue.main.async { self.status = s }
    }

    // MARK: Publishing

    /// Called from the sampler on the main thread once per tick.
    func publish(_ snap: Snapshot) {
        guard isOn else { return }
        let json = StatsJSON.encode(snap)
        let watch = WatchFeed.text(snap)
        queue.async {
            self.latest = json
            self.latestWatch = watch
            guard !self.streams.isEmpty else { return }
            var frame = Data("data: ".utf8)
            frame.append(json)
            frame.append(Data("\n\n".utf8))
            for (id, conn) in self.streams {
                conn.send(content: frame, completion: .contentProcessed { [weak self] err in
                    if err != nil { self?.drop(id) }
                })
            }
        }
    }

    private func drop(_ id: Int) {
        queue.async {
            guard let c = self.streams.removeValue(forKey: id) else { return }
            c.cancel()
            let n = self.streams.count
            DispatchQueue.main.async { self.clients = n }
        }
    }

    // MARK: HTTP

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(conn, buffer: Data())
    }

    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let d = data { buf.append(d) }

            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self)
                self.route(conn, head: head)
            } else if error == nil, !isComplete, buf.count < 32 * 1024 {
                self.readRequest(conn, buffer: buf)
            } else {
                conn.cancel()
            }
        }
    }

    private func route(_ conn: NWConnection, head: String) {
        guard let line = head.split(separator: "\r\n", maxSplits: 1).first else {
            conn.cancel(); return
        }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { conn.cancel(); return }

        let target = String(parts[1])
        let split = target.split(separator: "?", maxSplits: 1)
        let path = String(split.first ?? "/")
        let query = split.count > 1 ? String(split[1]) : ""
        let key = Self.param("k", in: query)

        switch path {
        // Unauthenticated: install-time assets that carry no machine data.
        case "/manifest.webmanifest":
            send(conn, 200, "application/manifest+json", WebApp.manifest(token: token))
        case "/icon.png", "/apple-touch-icon.png", "/apple-touch-icon-precomposed.png":
            send(conn, 200, "image/png", AppIcon.png(size: 180))
        case "/icon-512.png":
            send(conn, 200, "image/png", AppIcon.png(size: 512))
        case "/favicon.ico":
            send(conn, 200, "image/png", AppIcon.png(size: 64))

        default:
            guard key == token else {
                send(conn, 401, "text/plain; charset=utf-8",
                     Data("NEOSTAT — bad or missing key\n".utf8))
                return
            }
            lastPollAt = CFAbsoluteTimeGetCurrent()

            switch path {
            case "/", "/index.html":
                send(conn, 200, "text/html; charset=utf-8", Data(WebApp.html.utf8))
            case "/api/stats":
                send(conn, 200, "application/json", latest.isEmpty ? Data("{}".utf8) : latest)
            case "/api/stream":
                openStream(conn)
            case "/w", "/watch":
                send(conn, 200, "text/plain; charset=utf-8",
                     latestWatch.isEmpty ? Data("NEOSTAT — no sample yet\n".utf8) : latestWatch)
            default:
                send(conn, 404, "text/plain; charset=utf-8", Data("no route\n".utf8))
            }
        }
    }

    private func openStream(_ conn: NWConnection) {
        let id = nextID
        nextID += 1

        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: text/event-stream\r\n"
        header += "Cache-Control: no-cache, no-store\r\n"
        header += "Connection: keep-alive\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        // Reconnect fast: a phone waking from sleep should repaint immediately.
        header += "\r\nretry: 1500\n\n"

        var opening = Data(header.utf8)
        if !latest.isEmpty {
            opening.append(Data("data: ".utf8))
            opening.append(latest)
            opening.append(Data("\n\n".utf8))
        }

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.drop(id)
            default: break
            }
        }
        conn.send(content: opening, completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            if err != nil { conn.cancel(); return }
            self.queue.async {
                self.streams[id] = conn
                let n = self.streams.count
                DispatchQueue.main.async { self.clients = n }
            }
        })
        // Notice the device going away (tab closed, phone locked, Wi-Fi drop).
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, done, err in
            if done || err != nil { self?.drop(id) }
        }
    }

    private func send(_ conn: NWConnection, _ code: Int, _ type: String, _ body: Data) {
        let reason = code == 200 ? "OK" : (code == 401 ? "Unauthorized" : "Not Found")
        var header = "HTTP/1.1 \(code) \(reason)\r\n"
        header += "Content-Type: \(type)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func param(_ name: String, in query: String) -> String {
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.first.map(String.init) == name {
                return kv.count > 1 ? String(kv[1]) : ""
            }
        }
        return ""
    }

    private static func makeToken() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }

    // MARK: Addressing

    /// The URL to hand a phone. Prefers the Wi-Fi/Ethernet IPv4 address, since
    /// `.local` names resolve on Apple devices but not reliably on Android.
    var url: String {
        let host = Self.lanAddress() ?? "127.0.0.1"
        return "http://\(host):\(boundPort == 0 ? firstPort : boundPort)/?k=\(token)"
    }

    var watchURL: String {
        let host = Self.lanAddress() ?? "127.0.0.1"
        return "http://\(host):\(boundPort == 0 ? firstPort : boundPort)/w?k=\(token)"
    }

    static func lanAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let start = head else { return nil }
        defer { freeifaddrs(head) }

        var fallback: String?
        for ptr in sequence(first: start, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &buf, socklen_t(buf.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: buf)
            let name = String(cString: ptr.pointee.ifa_name)
            // en0 is Wi-Fi on every Mac laptop; anything else is a fallback.
            if name == "en0" { return ip }
            if fallback == nil, name.hasPrefix("en") { fallback = ip }
        }
        return fallback
    }
}
