import Foundation
import Network

/// `http://<workspace>.localhost` without a port. Browsers resolve every `*.localhost` name to this
/// Mac; this proxy listens on port 80, reads the Host header, and pipes the connection (HTTP and
/// WebSocket, so hot reload keeps working) to the workspace's dev server port.
///
/// macOS lets a normal user bind port 80 only on the wildcard address, so the listener is on all
/// interfaces; every connection whose peer is not loopback is closed before a byte is read, so the
/// proxy is never reachable from the network.
final class LocalProxy: @unchecked Sendable {
    static let shared = LocalProxy()
    private let routes = LockedValue<[String: Int]>([:])      // link name -> port
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "taki.proxy")
    let state = LockedValue<String>("off")

    func update(routes new: [String: Int]) { routes.set(new) }

    var isOn: Bool { state.get() == "on" }

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredInterfaceType = .loopback     // first wall: only the loopback interface
            let l = try NWListener(using: params, on: 80)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self] s in
                switch s {
                case .ready: self?.state.set("on")
                case .failed(let e): self?.state.set("Port 80 is busy (\(e.localizedDescription))"); self?.stop()
                default: break
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            state.set("Could not open port 80: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        if state.get() == "on" { state.set("off") }
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback || a.debugDescription.hasPrefix("::ffff:127.")
        case .name(let n, _): return n == "localhost"
        @unknown default: return false
        }
    }

    /// Link name from a Host header value: "landing.localhost" or "landing.localhost:80" -> "landing".
    static func linkName(fromHost host: String) -> String? {
        let h = host.lowercased().split(separator: ":").first.map(String.init) ?? ""
        guard h.hasSuffix(".localhost") else { return nil }
        let name = String(h.dropLast(".localhost".count))
        return name.isEmpty ? nil : name.split(separator: ".").last.map(String.init)
    }

    private let open = LockedValue(0)
    static let maxConnections = 200
    static let headTimeout: TimeInterval = 10

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        guard Self.isLoopback(c.endpoint), open.get() < Self.maxConnections else { c.forceCancel(); return }
        open.set(open.get() + 1)
        let closed = LockedValue(false)
        let release: @Sendable () -> Void = { [weak self] in
            guard let self, !closed.get() else { return }
            closed.set(true)
            self.open.set(self.open.get() - 1)
        }
        c.stateUpdateHandler = { s in
            if case .cancelled = s { release() }
            if case .failed = s { release(); c.cancel() }
        }
        // A client that never finishes its request head is dropped (slow-header exhaustion).
        let headDone = LockedValue(false)
        queue.asyncAfter(deadline: .now() + Self.headTimeout) { if !headDone.get() { c.cancel() } }
        readHead(c, buffer: Data(), headDone: headDone)
    }

    private func readHead(_ c: NWConnection, buffer: Data, headDone: LockedValue<Bool>) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, err in
            guard let self, err == nil, let data, !data.isEmpty else { c.cancel(); return }
            var buf = buffer
            buf.append(data)
            guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if buf.count > 64_000 || done { c.cancel() } else { self.readHead(c, buffer: buf, headDone: headDone) }
                return
            }
            let lines = String(decoding: buf[..<end.lowerBound], as: UTF8.self).split(separator: "\r\n")
            func header(_ name: String) -> String? {
                lines.first { $0.lowercased().hasPrefix(name + ":") }
                    .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
            }
            // A web page on another site must not script requests into local dev servers through
            // this proxy. Top-level navigation (typing or clicking a link) is still allowed.
            if header("sec-fetch-site")?.lowercased() == "cross-site", header("sec-fetch-mode")?.lowercased() != "navigate" {
                headDone.set(true)
                self.reply(c, "403 Forbidden", "Cross-site requests to Taki links are blocked.")
                return
            }
            let host = header("host") ?? ""
            guard let name = Self.linkName(fromHost: host), let port = self.routes.get()[name],
                  let p = NWEndpoint.Port(rawValue: UInt16(exactly: port) ?? 0), port > 0 else {
                headDone.set(true)
                self.reply(c, "404 Not Found", "Nothing is running at \(name(host)). Start the workspace in Taki first.")
                return
            }
            headDone.set(true)      // head complete: the head timeout no longer applies
            self.pipe(c, to: p, first: buf)
        }
    }

    private func name(_ host: String) -> String { Self.linkName(fromHost: host).map { "\($0).localhost" } ?? "this address" }

    private func reply(_ c: NWConnection, _ status: String, _ body: String) {
        let msg = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nX-Content-Type-Options: nosniff\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        c.send(content: Data(msg.utf8), completion: .contentProcessed { _ in c.cancel() })
    }

    private func pipe(_ client: NWConnection, to port: NWEndpoint.Port, first: Data) {
        let upstream = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let halves = LockedValue(0)       // both directions finished: then close both
        let finishHalf: @Sendable () -> Void = {
            halves.set(halves.get() + 1)
            if halves.get() >= 2 { client.cancel(); upstream.cancel() }
        }
        upstream.stateUpdateHandler = { [weak self] s in
            switch s {
            case .ready:
                upstream.send(content: first, completion: .contentProcessed { _ in })
                self?.forward(from: client, to: upstream, done: finishHalf)
                self?.forward(from: upstream, to: client, done: finishHalf)
            case .waiting, .failed:
                // Nothing listens on that port (the server stopped): answer instead of hanging.
                upstream.cancel()
                self?.reply(client, "502 Bad Gateway", "The dev server on port \(port) is not answering.")
            default: break
            }
        }
        upstream.start(queue: queue)
    }

    /// Copies one direction until EOF, then half-closes the other side (the reply in flight on the
    /// other direction keeps flowing until it ends too).
    private func forward(from a: NWConnection, to b: NWConnection, done: @escaping @Sendable () -> Void) {
        a.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, err in
            if let data, !data.isEmpty { b.send(content: data, completion: .contentProcessed { _ in }) }
            if isComplete || err != nil {
                b.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
                done()
                return
            }
            self?.forward(from: a, to: b, done: done)
        }
    }
}
