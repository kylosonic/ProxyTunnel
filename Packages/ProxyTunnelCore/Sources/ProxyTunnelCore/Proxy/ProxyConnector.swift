//
//  ProxyConnector.swift
//  ProxyTunnelCore
//
//  Opens a proxy connection: dial the transport, then run the protocol handshake.
//

import Foundation
import Network

/// One concrete address to dial for the proxy.
///
/// A host name resolves to several candidates; the connector tries them in order.
public struct TransportTarget: Equatable, Sendable {
    /// Host name or IP literal to open the TCP connection to.
    ///
    /// Inside the tunnel this is always an IP literal, because resolving a name
    /// there would require DNS through the tunnel we are still building.
    public let host: String
    public let port: UInt16
    /// TLS verification name. `nil` means "no TLS".
    public let tlsServerName: String?

    public init(host: String, port: UInt16, tlsServerName: String? = nil) {
        self.host = host
        self.port = port
        self.tlsServerName = tlsServerName
    }
}

/// A live, handshaken proxy connection ready to carry bytes.
public final class ProxyConnection {

    public let stream: DuplexByteStream
    public let endpoint: ProxyEndpoint
    public let destination: ProxyDestination
    public let outcome: ProxySession.Outcome
    /// The address that actually worked.
    public let dialedTarget: TransportTarget
    /// How long the TCP (and TLS, if any) dial took.
    public let tcpConnectDuration: TimeInterval
    /// How long the proxy protocol handshake took.
    public let handshakeDuration: TimeInterval

    private var isClosed = false

    init(
        stream: DuplexByteStream,
        endpoint: ProxyEndpoint,
        destination: ProxyDestination,
        outcome: ProxySession.Outcome,
        dialedTarget: TransportTarget,
        tcpConnectDuration: TimeInterval,
        handshakeDuration: TimeInterval
    ) {
        self.stream = stream
        self.endpoint = endpoint
        self.destination = destination
        self.outcome = outcome
        self.dialedTarget = dialedTarget
        self.tcpConnectDuration = tcpConnectDuration
        self.handshakeDuration = handshakeDuration
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        stream.close()
    }
}

public enum ProxyConnector {

    /// Connects to `endpoint` and issues `destination`.
    ///
    /// Tries every entry of `targets` in order. Authentication failures are
    /// *terminal*: if the proxy says the password is wrong there is no point
    /// dialling the next IP, and doing so could lock the account out.
    ///
    /// - Parameter completion: called exactly once, on `queue`.
    public static func connect(
        endpoint: ProxyEndpoint,
        destination: ProxyDestination,
        targets: [TransportTarget],
        queue: DispatchQueue,
        connectTimeout: TimeInterval = 15,
        handshakeTimeout: TimeInterval = 20,
        requiredInterface: NWInterface? = nil,
        log: DiagnosticLog? = nil,
        completion: @escaping (Result<ProxyConnection, ProxyError>) -> Void
    ) {
        guard !targets.isEmpty else {
            completion(.failure(.cannotResolveHost(endpoint.host)))
            return
        }

        var remaining = targets
        var lastError: ProxyError = .connectionFailed("no address was tried")
        var attempts: [String] = []

        func attemptNext() {
            guard !remaining.isEmpty else {
                log?.warning("proxy", "all \(attempts.count) candidate address(es) failed: \(attempts.joined(separator: ", "))")
                completion(.failure(lastError))
                return
            }
            let target = remaining.removeFirst()
            attempts.append(target.host)

            let security: NWByteStream.Security = target.tlsServerName.map { .tls(serverName: $0) } ?? .none
            let stream = NWByteStream(configuration: .init(
                host: target.host,
                port: target.port,
                security: security,
                requiredInterface: requiredInterface,
                connectTimeout: connectTimeout
            ))

            let dialStart = Date()
            stream.open(queue: queue) { result in
                switch result {
                case .failure(let error):
                    lastError = mapStreamError(error, endpoint: endpoint)
                    log?.debug("proxy", "dial \(target.host):\(target.port) failed: \(lastError.diagnosticDescription)")
                    stream.close()
                    attemptNext()

                case .success:
                    let tcpDuration = Date().timeIntervalSince(dialStart)
                    log?.debug("proxy", "connected to \(target.host):\(target.port) in \(String(format: "%.0f", tcpDuration * 1000)) ms")

                    let handshakeStart = Date()
                    ProxySession.run(
                        stream: stream,
                        queue: queue,
                        endpoint: endpoint,
                        destination: destination,
                        timeout: handshakeTimeout,
                        log: log
                    ) { handshakeResult in
                        switch handshakeResult {
                        case .success(let outcome):
                            let handshakeDuration = Date().timeIntervalSince(handshakeStart)
                            completion(.success(ProxyConnection(
                                stream: stream,
                                endpoint: endpoint,
                                destination: destination,
                                outcome: outcome,
                                dialedTarget: target,
                                tcpConnectDuration: tcpDuration,
                                handshakeDuration: handshakeDuration
                            )))
                        case .failure(let error):
                            stream.close()
                            lastError = error
                            if isTerminal(error) {
                                log?.warning("proxy", "handshake failed terminally (\(error.diagnosticDescription)); not trying other addresses")
                                completion(.failure(error))
                            } else {
                                log?.debug("proxy", "handshake against \(target.host) failed: \(error.diagnosticDescription)")
                                attemptNext()
                            }
                        }
                    }
                }
            }
        }

        attemptNext()
    }

    /// Failures that will not be fixed by trying a different address.
    static func isTerminal(_ error: ProxyError) -> Bool {
        switch error {
        case .authenticationRejected,
             .authenticationRequired,
             .unsupportedAuthMethod,
             .protocolViolation,
             .addressFamilyUnsupported:
            return true
        case .badServerResponse:
            // A server that answers garbage for this protocol will answer the
            // same garbage on its other addresses.
            return true
        case .cannotResolveHost, .connectionFailed, .connectionTimeout, .tlsFailed, .proxyRefusedConnection, .cancelled:
            return false
        }
    }

    static func mapStreamError(_ error: Error, endpoint: ProxyEndpoint) -> ProxyError {
        guard let streamError = error as? ByteStreamError else {
            return .connectionFailed("\(error)")
        }
        switch streamError {
        case .timedOut:      return .connectionTimeout
        case .closed:        return .connectionFailed("the proxy closed the connection")
        case .notConnected:  return .connectionFailed("the connection was never established")
        case .transport(let detail):
            if detail.hasPrefix("TLS") { return .tlsFailed(detail) }
            if detail.contains("refused") {
                return .connectionFailed("connection refused — nothing is listening on \(endpoint.redactedEndpoint)")
            }
            return .connectionFailed(detail)
        }
    }

    /// Convenience: build the transport candidates for a proxy endpoint from a
    /// list of already-resolved addresses.
    public static func targets(
        for endpoint: ProxyEndpoint,
        resolvedAddresses: [String]
    ) -> [TransportTarget] {
        let port = endpoint.portValue
        let tlsName: String? = endpoint.protocolType.usesTLS ? endpoint.host : nil
        return resolvedAddresses.map { TransportTarget(host: $0, port: port, tlsServerName: tlsName) }
    }
}
