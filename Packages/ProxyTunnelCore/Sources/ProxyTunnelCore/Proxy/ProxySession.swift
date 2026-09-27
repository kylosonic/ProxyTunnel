//
//  ProxySession.swift
//  ProxyTunnelCore
//
//  The protocol handshakes, written against `DuplexByteStream` so that the same
//  code runs in the app's "test connection" button and inside the tunnel.
//
//  Each handshake is a small state machine driven by the pull-based stream:
//
//      write(...) ──▶ read() ──▶ parse ──▶ (incomplete? read() again : next step)
//
//  All mutable state is confined to the `DispatchQueue` the stream was opened on.
//

import Foundation

/// What the client wants the proxy to do.
public enum ProxyDestination: Equatable, Sendable {
    /// Open a TCP connection to `host:port` (SOCKS5 CONNECT / HTTP CONNECT).
    case connect(host: String, port: UInt16)
    /// SOCKS5 UDP ASSOCIATE. `host`/`port` are the address the client expects to
    /// send datagrams *from*; RFC 1928 allows 0.0.0.0:0 when unknown.
    case udpAssociate(host: String, port: UInt16)

    public var host: String {
        switch self {
        case .connect(let host, _):      return host
        case .udpAssociate(let host, _): return host
        }
    }

    public var port: UInt16 {
        switch self {
        case .connect(_, let port):      return port
        case .udpAssociate(_, let port): return port
        }
    }

    /// Redacted description, safe for logs.
    public var redactedDescription: String {
        switch self {
        case .connect(let host, let port):      return "CONNECT \(host):\(port)"
        case .udpAssociate(let host, let port): return "UDP ASSOCIATE \(host):\(port)"
        }
    }
}

public enum ProxySession {

    /// The result of a successful handshake.
    public struct Outcome: Sendable {
        public let protocolType: ProxyProtocol
        /// Human-readable summary of what the proxy answered, e.g.
        /// "SOCKS5 reply=succeeded" or "HTTP/1.1 200 Connection established".
        public let responseSummary: String
        /// SOCKS5 BND.ADDR (the relay address for UDP ASSOCIATE).
        public let boundHost: String?
        /// SOCKS5 BND.PORT.
        public let boundPort: UInt16?
        /// Bytes that were already read past the end of the handshake.
        ///
        /// This is almost always empty, but it *must* be forwarded rather than
        /// dropped: a fast origin server can send its first bytes before we have
        /// finished parsing the reply, and losing them would corrupt the stream.
        public let leftover: Data
    }

    /// Runs the handshake for `endpoint`'s protocol.
    ///
    /// - Parameter timeout: applies to the whole handshake, not per byte.
    public static func run(
        stream: DuplexByteStream,
        queue: DispatchQueue,
        endpoint: ProxyEndpoint,
        destination: ProxyDestination,
        timeout: TimeInterval = 20,
        log: DiagnosticLog? = nil,
        completion: @escaping (Result<Outcome, ProxyError>) -> Void
    ) {
        let runner = Runner(
            stream: stream,
            queue: queue,
            endpoint: endpoint,
            destination: destination,
            timeout: timeout,
            log: log,
            completion: completion
        )
        runner.start()
    }
}

// MARK: - Runner

private final class Runner {

    private enum Step {
        case awaitingMethodSelection
        case awaitingAuthReply
        case awaitingSocksReply
        case awaitingHTTPResponseHead
    }

    private let stream: DuplexByteStream
    private let queue: DispatchQueue
    private let endpoint: ProxyEndpoint
    private let destination: ProxyDestination
    private let timeout: TimeInterval
    private let log: DiagnosticLog?
    private let completion: (Result<ProxySession.Outcome, ProxyError>) -> Void

    private var step: Step = .awaitingMethodSelection
    private var buffer = Data()
    private var timeoutWork: DispatchWorkItem?
    private var isFinished = false

    /// Refuse to buffer more than this while hunting for a reply. A proxy that
    /// sends this much before answering is broken or hostile.
    private static let maximumHandshakeBuffer = 64 * 1024

    init(
        stream: DuplexByteStream,
        queue: DispatchQueue,
        endpoint: ProxyEndpoint,
        destination: ProxyDestination,
        timeout: TimeInterval,
        log: DiagnosticLog?,
        completion: @escaping (Result<ProxySession.Outcome, ProxyError>) -> Void
    ) {
        self.stream = stream
        self.queue = queue
        self.endpoint = endpoint
        self.destination = destination
        self.timeout = timeout
        self.log = log
        self.completion = completion
    }

    func start() {
        log?.debug("proxy", "handshake start: \(endpoint) -> \(destination.redactedDescription)")

        let work = DispatchWorkItem { [weak self] in
            self?.finish(.failure(.connectionTimeout))
        }
        timeoutWork = work
        queue.asyncAfter(deadline: .now() + timeout, execute: work)

        switch endpoint.protocolType {
        case .socks5:
            step = .awaitingMethodSelection
            buffer.removeAll(keepingCapacity: true)
            let methods = SOCKS5.defaultMethods(hasCredential: endpoint.credential != nil)
            send(SOCKS5.greeting(methods: methods))
        case .httpConnect, .httpsConnect:
            step = .awaitingHTTPResponseHead
            buffer.removeAll(keepingCapacity: true)
            do {
                let head = try HTTPConnect.request(
                    host: destination.host,
                    port: destination.port,
                    credential: endpoint.credential
                )
                if case .udpAssociate = destination {
                    // Refuse locally rather than confusing the user with a
                    // protocol error from the server.
                    finish(.failure(.addressFamilyUnsupported))
                    return
                }
                send(head)
            } catch {
                finish(.failure(.protocolViolation("could not build CONNECT request: \(error)")))
            }
        }
    }

    // MARK: I/O

    private func send(_ data: Data) {
        guard !isFinished else { return }
        stream.write(data) { [weak self] result in
            guard let self, !self.isFinished else { return }
            switch result {
            case .success:
                self.readMore()
            case .failure(let error):
                self.finish(.failure(self.mapTransportError(error)))
            }
        }
    }

    private func readMore() {
        guard !isFinished else { return }
        stream.read { [weak self] result in
            guard let self, !self.isFinished else { return }
            switch result {
            case .failure(let error):
                self.finish(.failure(self.mapTransportError(error)))
            case .success(let data):
                if data.isEmpty {
                    self.finish(.failure(.connectionFailed(
                        "the proxy closed the connection during the \(self.endpoint.protocolType.displayName) handshake"
                    )))
                    return
                }
                self.buffer.append(data)
                if self.buffer.count > Self.maximumHandshakeBuffer {
                    self.finish(.failure(.protocolViolation(
                        "the proxy sent more than \(Self.maximumHandshakeBuffer) bytes without completing the handshake"
                    )))
                    return
                }
                self.advance()
            }
        }
    }

    // MARK: State machine

    private func advance() {
        guard !isFinished else { return }
        switch step {
        case .awaitingMethodSelection:  handleMethodSelection()
        case .awaitingAuthReply:        handleAuthReply()
        case .awaitingSocksReply:       handleSocksReply()
        case .awaitingHTTPResponseHead: handleHTTPResponseHead()
        }
    }

    // MARK: SOCKS5

    private func handleMethodSelection() {
        let method: SOCKS5.AuthMethod
        do {
            method = try SOCKS5.parseMethodSelection(buffer)
        } catch SOCKS5Error.incomplete {
            readMore()
            return
        } catch {
            finish(.failure(.badServerResponse("\(error)")))
            return
        }

        buffer.removeAll(keepingCapacity: true)
        log?.debug("proxy", "SOCKS5 server selected auth method: \(method.name)")

        switch method {
        case .none:
            sendSocksCommand()
        case .userPassword:
            guard let credential = endpoint.credential else {
                finish(.failure(.authenticationRequired))
                return
            }
            do {
                let request = try SOCKS5.userPasswordRequest(
                    username: credential.username,
                    password: credential.password
                )
                step = .awaitingAuthReply
                send(request)
            } catch {
                finish(.failure(.protocolViolation("could not build the RFC 1929 auth request: \(error)")))
            }
        case .gssapi:
            finish(.failure(.unsupportedAuthMethod(SOCKS5.AuthMethod.gssapi.rawValue)))
        case .noAcceptable:
            // The server refused every method we offered. If we offered only
            // "no authentication" that means the proxy wants credentials, which
            // is a much more useful thing to tell the user.
            finish(.failure(endpoint.credential == nil
                ? .authenticationRequired
                : .unsupportedAuthMethod(SOCKS5.AuthMethod.noAcceptable.rawValue)))
        }
    }

    private func handleAuthReply() {
        do {
            try SOCKS5.parseUserPasswordResponse(buffer)
        } catch SOCKS5Error.incomplete {
            readMore()
            return
        } catch {
            // parseUserPasswordResponse reports a non-zero STATUS as malformed;
            // treat any failure here as a credential rejection rather than a
            // protocol error, because that is what it means 99% of the time.
            finish(.failure(.authenticationRejected))
            return
        }
        buffer.removeAll(keepingCapacity: true)
        log?.debug("proxy", "SOCKS5 username/password authentication accepted")
        sendSocksCommand()
    }

    private func sendSocksCommand() {
        let command: SOCKS5.Command
        switch destination {
        case .connect:      command = .connect
        case .udpAssociate: command = .udpAssociate
        }
        do {
            let request = try SOCKS5.request(command: command, host: destination.host, port: destination.port)
            step = .awaitingSocksReply
            send(request)
        } catch {
            finish(.failure(.protocolViolation("could not build the SOCKS5 \(command.name) request: \(error)")))
        }
    }

    private func handleSocksReply() {
        let message: SOCKS5.ReplyMessage
        do {
            message = try SOCKS5.parseReply(buffer)
        } catch SOCKS5Error.incomplete {
            readMore()
            return
        } catch {
            finish(.failure(.badServerResponse("\(error)")))
            return
        }

        guard message.reply == .succeeded else {
            finish(.failure(.proxyRefusedConnection(message.reply.name)))
            return
        }

        let leftover = Data(buffer.dropFirst(message.consumed))
        let summary = destination.redactedDescription.hasPrefix("UDP")
            ? "SOCKS5 UDP ASSOCIATE succeeded, relay \(message.boundHost):\(message.boundPort)"
            : "SOCKS5 CONNECT succeeded"

        finish(.success(ProxySession.Outcome(
            protocolType: .socks5,
            responseSummary: summary,
            boundHost: message.boundHost,
            boundPort: message.boundPort,
            leftover: leftover
        )))
    }

    // MARK: HTTP CONNECT

    private func handleHTTPResponseHead() {
        let response: HTTPConnect.Response
        do {
            response = try HTTPConnect.parseResponseHead(buffer)
        } catch HTTPConnectError.incomplete {
            readMore()
            return
        } catch {
            finish(.failure(.badServerResponse("\(error)")))
            return
        }

        guard response.isSuccess else {
            if response.isAuthenticationChallenge {
                finish(.failure(endpoint.credential == nil ? .authenticationRequired : .authenticationRejected))
            } else {
                finish(.failure(.proxyRefusedConnection(response.summary)))
            }
            return
        }

        let terminator = HTTPConnect.findHeadTerminator(in: buffer) ?? buffer.endIndex
        let leftover = Data(buffer[terminator...])

        finish(.success(ProxySession.Outcome(
            protocolType: endpoint.protocolType,
            responseSummary: "HTTP CONNECT: \(response.summary)",
            boundHost: nil,
            boundPort: nil,
            leftover: leftover
        )))
    }

    // MARK: Completion

    private func mapTransportError(_ error: Error) -> ProxyError {
        guard let streamError = error as? ByteStreamError else {
            return .connectionFailed("\(error)")
        }
        switch streamError {
        case .timedOut:
            return .connectionTimeout
        case .closed:
            return .connectionFailed("the proxy closed the connection")
        case .notConnected:
            return .connectionFailed("the connection to the proxy was never established")
        case .transport(let detail):
            // NWByteStream prefixes TLS failures with "TLS".
            if detail.hasPrefix("TLS") {
                return .tlsFailed(detail)
            }
            if detail.contains("refused") {
                return .connectionFailed("connection refused — nothing is listening on \(endpoint.redactedEndpoint)")
            }
            return .connectionFailed(detail)
        }
    }

    private func finish(_ result: Result<ProxySession.Outcome, ProxyError>) {
        guard !isFinished else { return }
        isFinished = true
        timeoutWork?.cancel()
        timeoutWork = nil
        switch result {
        case .success(let outcome):
            log?.info("proxy", "handshake OK: \(outcome.responseSummary)")
        case .failure(let error):
            log?.warning("proxy", "handshake failed: \(error.diagnosticDescription)")
        }
        completion(result)
    }
}
