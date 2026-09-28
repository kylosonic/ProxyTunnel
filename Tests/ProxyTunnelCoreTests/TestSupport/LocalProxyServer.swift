//
//  LocalProxyServer.swift
//  ProxyTunnelCoreTests
//
//  A real SOCKS5 / HTTP CONNECT proxy, implemented on `NWListener`, that the
//  integration tests talk to over loopback.
//
//  This exists so that the proxy client can be tested end to end — handshake,
//  authentication, request framing, and byte relay — rather than only at the
//  codec level. It runs on the iOS Simulator, so it also runs on GitHub's macOS
//  runners.
//
//  It is deliberately small and single-purpose. It is not a general proxy.
//

import Foundation
import Network

/// Counts and forwards bytes. Used as the origin server behind the proxy.
final class LocalEchoServer {

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "test.echo")

    /// Whether the listener had to fall back to binding on every interface.
    private(set) var isPinnedToLoopback = false

    /// What the "origin" sends back. If `nil`, bytes are echoed.
    var response: Data?

    init(response: Data? = nil) throws {
        self.response = response
    }

    func start() throws -> UInt16 {
        let bound = try TestServerParameters.bind(queue: queue) { [weak self] listener in
            listener.newConnectionHandler = { connection in
                guard let self else { return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                self.receiveLoop(connection)
            }
        }
        listener = bound.listener
        isPinnedToLoopback = bound.pinnedToLoopback
        return bound.port
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let reply = self.response ?? data
                connection.send(content: reply, completion: .contentProcessed { _ in })
                if self.response != nil, isComplete { connection.cancel(); return }
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receiveLoop(connection)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }
}

enum TestServerError: Error {
    case couldNotBind
    case badHandshake(String)
    case timedOut
}

/// Shared listener plumbing for the test servers.
enum TestServerParameters {

    /// TCP parameters, optionally pinned to the **loopback endpoint**.
    ///
    /// Pinning matters in CI: a listener on "all interfaces" has to be registered
    /// with the network control policy, which a host-less unit-test bundle on the
    /// Simulator is not allowed to do (`setsockopt SO_NECP_LISTENUUID failed`), and
    /// inbound connections to it are then dropped. A loopback-only listener avoids
    /// that path — and the tests only ever connect over loopback anyway.
    ///
    /// The pin is a *preference*: `bind` falls back to every interface if it does
    /// not come up, because a listener that binds but cannot accept is worse than
    /// no listener at all only if we cannot tell the difference.
    static func parameters(pinnedToLoopback: Bool) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if pinnedToLoopback {
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        }
        return parameters
    }

    /// Creates, configures and starts a listener, preferring loopback.
    ///
    /// - Returns: the listener, its bound port, and whether it is loopback-pinned.
    static func bind(
        queue: DispatchQueue,
        timeout: TimeInterval = 4,
        configure: (NWListener) -> Void
    ) throws -> (listener: NWListener, port: UInt16, pinnedToLoopback: Bool) {

        for pinned in [true, false] {
            guard let listener = try? NWListener(using: parameters(pinnedToLoopback: pinned), on: .any) else {
                continue
            }
            configure(listener)
            if let port = waitForReady(listener, queue: queue, timeout: timeout), port != 0 {
                return (listener, port, pinned)
            }
            listener.stateUpdateHandler = nil
            listener.cancel()
        }
        throw TestServerError.couldNotBind
    }

    /// Starts the listener and waits for `.ready`.
    static func waitForReady(_ listener: NWListener, queue: DispatchQueue, timeout: TimeInterval) -> UInt16? {
        let semaphore = DispatchSemaphore(value: 0)
        var boundPort: UInt16 = 0
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                boundPort = listener.port?.rawValue ?? 0
                semaphore.signal()
            case .failed, .cancelled:
                semaphore.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + timeout)
        return boundPort == 0 ? nil : boundPort
    }
}

/// A SOCKS5 proxy that really relays to the requested destination.
final class LocalSOCKS5Server {

    struct Credentials {
        let username: String
        let password: String
    }

    /// `nil` means "no authentication required".
    var credentials: Credentials?
    /// When set, the server refuses every CONNECT with this reply code.
    var forcedReplyCode: UInt8?
    /// When true the server offers only GSSAPI, so the client must fail cleanly.
    var offerOnlyGSSAPI = false
    /// When set, every CONNECT is redirected here instead of to the requested
    /// address.
    ///
    /// Tests need this because the tunnel engine deliberately refuses to proxy
    /// loopback destinations (proxying 127.0.0.1 would be a loop), so the packet
    /// under test has to carry a routable-looking address while the test proxy
    /// still connects to a server on loopback.
    var redirectAllConnectionsTo: (host: String, port: UInt16)?

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    /// Per-connection state machines, retained explicitly.
    ///
    /// The session's receive callback captures `self` weakly, so without this the
    /// session is deallocated the moment `newConnectionHandler` returns: the server
    /// accepts the connection and then never speaks.
    private var sessions: [SOCKS5ServerSession] = []
    private let queue = DispatchQueue(label: "test.socks5")

    /// Whether the listener had to fall back to binding on every interface.
    private(set) var isPinnedToLoopback = false

    /// Counters so tests can assert on what the server actually saw.
    private(set) var handshakesCompleted = 0
    private(set) var authenticationFailures = 0
    private(set) var requestedDestinations: [String] = []

    init() throws {}

    func start() throws -> UInt16 {
        let bound = try TestServerParameters.bind(queue: queue) { [weak self] listener in
            listener.newConnectionHandler = { connection in
                guard let self else { return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                let session = SOCKS5ServerSession(server: self, connection: connection)
                self.sessions.append(session)
                session.begin()
            }
        }
        listener = bound.listener
        isPinnedToLoopback = bound.pinnedToLoopback
        return bound.port
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        sessions.removeAll()
    }

    fileprivate func recordHandshake(destination: String) {
        handshakesCompleted += 1
        requestedDestinations.append(destination)
    }

    fileprivate func recordAuthFailure() {
        authenticationFailures += 1
    }
}

/// The per-connection state machine for the test SOCKS5 server.
private final class SOCKS5ServerSession {

    private enum Stage {
        case greeting
        case auth
        case request
        case relaying
        case failed
    }

    private unowned let server: LocalSOCKS5Server
    private let connection: NWConnection
    private var buffer = Data()
    private var stage: Stage = .greeting
    private var completedHandshake = false

    init(server: LocalSOCKS5Server, connection: NWConnection) {
        self.server = server
        self.connection = connection
    }

    func begin() {
        readMore()
    }

    private func readMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                if !self.advance() { return }
            }
            if isComplete || error != nil {
                self.connection.cancel()
                return
            }
            if self.stage == .relaying { return }
            self.readMore()
        }
    }

    /// - Returns: `false` when the session should stop reading protocol bytes.
    private func advance() -> Bool {
        switch stage {
        case .greeting:
            guard buffer.count >= 2 else { return true }
            let methodCount = Int(buffer[buffer.startIndex + 1])
            guard buffer.count >= 2 + methodCount else { return true }
            let methods = (0..<methodCount).map { buffer[buffer.startIndex + 2 + $0] }
            buffer.removeFirst(2 + methodCount)

            if server.offerOnlyGSSAPI {
                connection.send(content: Data([0x05, 0x01]), completion: .contentProcessed { _ in })
                stage = .failed
                return false
            }
            if server.credentials != nil {
                guard methods.contains(0x02) else {
                    connection.send(content: Data([0x05, 0xFF]), completion: .contentProcessed { _ in })
                    stage = .failed
                    return false
                }
                connection.send(content: Data([0x05, 0x02]), completion: .contentProcessed { _ in })
                stage = .auth
            } else {
                connection.send(content: Data([0x05, 0x00]), completion: .contentProcessed { _ in })
                stage = .request
            }
            return advance()

        case .auth:
            guard buffer.count >= 2 else { return true }
            let userLength = Int(buffer[buffer.startIndex + 1])
            guard buffer.count >= 2 + userLength + 1 else { return true }
            let passwordLength = Int(buffer[buffer.startIndex + 2 + userLength])
            guard buffer.count >= 2 + userLength + 1 + passwordLength else { return true }

            let user = String(decoding: buffer[buffer.startIndex + 2 ..< buffer.startIndex + 2 + userLength], as: UTF8.self)
            let password = String(decoding: buffer[buffer.startIndex + 3 + userLength ..< buffer.startIndex + 3 + userLength + passwordLength], as: UTF8.self)
            buffer.removeFirst(3 + userLength + passwordLength)

            if let expected = server.credentials, expected.username == user, expected.password == password {
                connection.send(content: Data([0x01, 0x00]), completion: .contentProcessed { _ in })
                stage = .request
                return advance()
            } else {
                server.recordAuthFailure()
                connection.send(content: Data([0x01, 0x01]), completion: .contentProcessed { _ in })
                stage = .failed
                return false
            }

        case .request:
            guard buffer.count >= 4 else { return true }
            let command = buffer[buffer.startIndex + 1]
            let addressType = buffer[buffer.startIndex + 3]
            var offset = 4
            var host = ""
            switch addressType {
            case 0x01:
                guard buffer.count >= offset + 4 + 2 else { return true }
                host = (0..<4).map { String(buffer[buffer.startIndex + offset + $0]) }.joined(separator: ".")
                offset += 4
            case 0x04:
                guard buffer.count >= offset + 16 + 2 else { return true }
                let bytes = Array(buffer[buffer.startIndex + offset ..< buffer.startIndex + offset + 16])
                host = stride(from: 0, to: 16, by: 2)
                    .map { String(format: "%02x%02x", bytes[$0], bytes[$0 + 1]) }
                    .joined(separator: ":")
                offset += 16
            case 0x03:
                guard buffer.count >= offset + 1 else { return true }
                let length = Int(buffer[buffer.startIndex + offset])
                guard buffer.count >= offset + 1 + length + 2 else { return true }
                host = String(decoding: buffer[buffer.startIndex + offset + 1 ..< buffer.startIndex + offset + 1 + length], as: UTF8.self)
                offset += 1 + length
            default:
                connection.send(content: Data([0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0]), completion: .contentProcessed { _ in })
                stage = .failed
                return false
            }
            let port = UInt16(buffer[buffer.startIndex + offset]) << 8 | UInt16(buffer[buffer.startIndex + offset + 1])
            buffer.removeFirst(offset + 2)

            guard command == 0x01 else {
                connection.send(content: Data([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]), completion: .contentProcessed { _ in })
                stage = .failed
                return false
            }

            if let forced = server.forcedReplyCode {
                connection.send(content: Data([0x05, forced, 0x00, 0x01, 0, 0, 0, 0, 0, 0]), completion: .contentProcessed { _ in })
                stage = .failed
                return false
            }

            server.recordHandshake(destination: "\(host):\(port)")

            // Reply with success, then dial the requested target and relay.
            let reply = Data([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0x1F, 0x90])
            connection.send(content: reply, completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                if let redirect = self.server.redirectAllConnectionsTo {
                    self.connectUpstream(host: redirect.host, port: redirect.port)
                } else {
                    self.connectUpstream(host: host, port: port)
                }
            })
            stage = .relaying
            return false

        case .relaying, .failed:
            return false
        }
    }

    private func connectUpstream(host: String, port: UInt16) {
        let upstream = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? .any,
            using: .tcp
        )
        let queue = DispatchQueue(label: "test.socks5.upstream")
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // Anything already buffered belongs to the tunnel.
                if !self.buffer.isEmpty {
                    upstream.send(content: self.buffer, completion: .contentProcessed { _ in })
                    self.buffer.removeAll()
                }
                self.relay(from: self.connection, to: upstream)
                self.relay(from: upstream, to: self.connection)
            case .failed, .cancelled:
                self.connection.cancel()
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    private func relay(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil {
                destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    source.cancel()
                })
                return
            }
            self?.relay(from: source, to: destination)
        }
    }
}

/// A plain HTTP CONNECT proxy that really relays.
final class LocalHTTPConnectServer {

    var credentials: LocalSOCKS5Server.Credentials?
    var responseStatusLine: String = "HTTP/1.1 200 Connection Established"
    /// See `LocalSOCKS5Server.redirectAllConnectionsTo`.
    var redirectAllConnectionsTo: (host: String, port: UInt16)?

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "test.httpconnect")

    /// Whether the listener had to fall back to binding on every interface.
    private(set) var isPinnedToLoopback = false

    private(set) var handshakesCompleted = 0
    private(set) var requestedAuthorities: [String] = []
    private(set) var lastProxyAuthorizationHeader: String?

    init() throws {}

    func start() throws -> UInt16 {
        let bound = try TestServerParameters.bind(queue: queue) { [weak self] listener in
            listener.newConnectionHandler = { connection in
                guard let self else { return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                self.readHead(connection, buffer: Data())
            }
        }
        listener = bound.listener
        isPinnedToLoopback = bound.pinnedToLoopback
        return bound.port
    }

    private func readHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            guard let range = accumulated.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || error != nil { connection.cancel() } else { self.readHead(connection, buffer: accumulated) }
                return
            }

            let head = String(decoding: Data(accumulated.prefix(upTo: range.lowerBound)), as: UTF8.self)
            let leftover = Data(accumulated.suffix(from: range.upperBound))
            self.handle(head: head, leftover: leftover, connection: connection)
        }
    }

    private func handle(head: String, leftover: Data, connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            connection.cancel()
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "CONNECT" else {
            connection.send(content: Data("HTTP/1.1 405 Method Not Allowed\r\n\r\n".utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }
        let authority = String(parts[1])
        requestedAuthorities.append(authority)

        var authorization: String?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].lowercased()
            if name == "proxy-authorization" {
                authorization = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        lastProxyAuthorizationHeader = authorization

        if let expected = credentials {
            let token = Data("\(expected.username):\(expected.password)".utf8).base64EncodedString()
            guard authorization == "Basic \(token)" else {
                connection.send(
                    content: Data("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"test\"\r\n\r\n".utf8),
                    completion: .contentProcessed { _ in connection.cancel() }
                )
                return
            }
        }

        handshakesCompleted += 1
        let response = Data("\(responseStatusLine)\r\nProxy-Agent: LocalTestProxy\r\n\r\n".utf8)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            let components = authority.split(separator: ":")
            guard components.count >= 2, let port = UInt16(components.last!) else {
                connection.cancel()
                return
            }
            var host = components.dropLast().joined(separator: ":")
            if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
            if let redirect = self.redirectAllConnectionsTo {
                self.connectUpstream(host: redirect.host, port: redirect.port, connection: connection, leftover: leftover)
            } else {
                self.connectUpstream(host: host, port: port, connection: connection, leftover: leftover)
            }
        })
    }

    private func connectUpstream(host: String, port: UInt16, connection: NWConnection, leftover: Data) {
        let upstream = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? .any,
            using: .tcp
        )
        let queue = DispatchQueue(label: "test.httpconnect.upstream")
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if !leftover.isEmpty {
                    upstream.send(content: leftover, completion: .contentProcessed { _ in })
                }
                self.relay(from: connection, to: upstream)
                self.relay(from: upstream, to: connection)
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    private func relay(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil {
                destination.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    source.cancel()
                })
                return
            }
            self?.relay(from: source, to: destination)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }
}
