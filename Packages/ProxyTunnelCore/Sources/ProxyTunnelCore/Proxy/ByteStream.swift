//
//  ByteStream.swift
//  ProxyTunnelCore
//
//  The transport abstraction the proxy sessions are written against.
//
//  A strict *pull* model is used (at most one outstanding `read`), because that
//  is exactly what `NWConnection` provides and it makes flow control explicit:
//  the tunnel stops asking for bytes when it is applying back-pressure.
//

import Foundation
import Network
import Security

public enum ByteStreamError: Error, Equatable, CustomStringConvertible {
    case notConnected
    case closed
    case timedOut
    case transport(String)

    public var description: String {
        switch self {
        case .notConnected:          return "stream is not connected"
        case .closed:                return "stream closed by the peer"
        case .timedOut:              return "stream operation timed out"
        case .transport(let detail): return "transport error: \(detail)"
        }
    }
}

/// A duplex byte stream to the proxy.
///
/// All callbacks are delivered on the queue passed to `open(queue:completion:)`,
/// so implementations of `ProxySession` can keep their state confined to that
/// queue and need no locking.
public protocol DuplexByteStream: AnyObject {

    /// The local address family that ended up being used, when known. Used by the
    /// diagnostics screen to report whether an IPv4 or an IPv6 path was chosen.
    var localEndpointDescription: String? { get }
    var remoteEndpointDescription: String? { get }

    /// Begins connecting. `completion` fires exactly once.
    func open(queue: DispatchQueue, completion: @escaping (Result<Void, Error>) -> Void)

    /// Writes `data`. `completion` fires exactly once, on the queue.
    func write(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void)

    /// Requests the next chunk of bytes.
    ///
    /// - `success(Data())` means end of stream.
    /// - At most one read may be outstanding at a time.
    func read(completion: @escaping (Result<Data, Error>) -> Void)

    func close()
}

// MARK: - Network.framework implementation

/// A `DuplexByteStream` backed by `NWConnection` over TCP, optionally TLS.
///
/// ### Why this lives in the core and not in the app
///
/// The extension needs the same client as the app's "test connection" button, and
/// `Network.framework` is available in both processes. Keeping one implementation
/// means the code path the user tests from the UI is byte-for-byte the code path
/// the tunnel uses.
public final class NWByteStream: DuplexByteStream {

    public enum Security {
        /// Plain TCP to the proxy.
        case none
        /// TLS to the proxy, validating the certificate against the system trust
        /// store for `serverName`.
        case tls(serverName: String)
    }

    public struct Configuration {
        public let host: String
        public let port: UInt16
        public let security: Security
        /// When set, all traffic is pinned to this interface. This is what keeps
        /// the tunnel's own connection to the proxy from being routed back into
        /// the tunnel on a multi-homed device.
        public let requiredInterface: NWInterface?
        /// Value passed to `NWProtocolTCP.Options.connectionTimeout`.
        public let connectTimeout: TimeInterval

        public init(
            host: String,
            port: UInt16,
            security: Security = .none,
            requiredInterface: NWInterface? = nil,
            connectTimeout: TimeInterval = 15
        ) {
            self.host = host
            self.port = port
            self.security = security
            self.requiredInterface = requiredInterface
            self.connectTimeout = connectTimeout
        }
    }

    private let configuration: Configuration
    private let connection: NWConnection
    private var queue: DispatchQueue?
    private var openCompletion: ((Result<Void, Error>) -> Void)?
    private var didCompleteOpen = false
    private var isClosed = false
    private var readOutstanding = false

    public init(configuration: Configuration) {
        self.configuration = configuration

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = Int(max(1, configuration.connectTimeout.rounded()))
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 30
        tcpOptions.keepaliveInterval = 10
        tcpOptions.keepaliveCount = 4

        let parameters: NWParameters
        switch configuration.security {
        case .none:
            parameters = NWParameters(tls: nil, tcp: tcpOptions)
        case .tls(let serverName):
            let tlsOptions = NWProtocolTLS.Options()
            // Set the SNI/verification name explicitly. We very often connect to a
            // *resolved IP literal* rather than the hostname (so that no DNS lookup
            // happens inside the tunnel), and in that case Network.framework would
            // otherwise use the IP as the verification name and the certificate
            // would not match.
            serverName.withCString { cString in
                sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, cString)
            }
            sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)
            parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        }
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        if let requiredInterface = configuration.requiredInterface {
            parameters.requiredInterface = requiredInterface
        }
        // A proxy is always reached directly over the public internet. Never let
        // our own connection to it be picked up by another proxy configuration.
        parameters.preferNoProxies = true

        self.connection = NWConnection(
            host: NWEndpoint.Host(configuration.host),
            port: NWEndpoint.Port(rawValue: configuration.port) ?? .any,
            using: parameters
        )
    }

    public var localEndpointDescription: String? {
        guard let endpoint = connection.currentPath?.localEndpoint else { return nil }
        return "\(endpoint)"
    }

    public var remoteEndpointDescription: String? {
        guard let endpoint = connection.currentPath?.remoteEndpoint else { return nil }
        return "\(endpoint)"
    }

    // MARK: Open

    public func open(queue: DispatchQueue, completion: @escaping (Result<Void, Error>) -> Void) {
        self.queue = queue
        self.openCompletion = completion
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.finishOpen(.success(()))
            case .waiting(let error):
                // `.waiting` means the system cannot currently send on any path
                // (no route, DNS still pending, network down). Report it instead
                // of hanging: the UI needs to show something actionable.
                self.finishOpen(.failure(ByteStreamError.transport(Self.describe(error))))
            case .failed(let error):
                self.finishOpen(.failure(ByteStreamError.transport(Self.describe(error))))
            case .cancelled:
                self.finishOpen(.failure(ByteStreamError.closed))
            case .setup, .preparing:
                break
            @unknown default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func finishOpen(_ result: Result<Void, Error>) {
        guard !didCompleteOpen else { return }
        didCompleteOpen = true
        let completion = openCompletion
        openCompletion = nil
        completion?(result)
    }

    // MARK: Read / write

    public func write(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isClosed else {
            completion(.failure(ByteStreamError.closed))
            return
        }
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                completion(.failure(ByteStreamError.transport(Self.describe(error))))
            } else {
                completion(.success(()))
            }
        })
    }

    public func read(completion: @escaping (Result<Data, Error>) -> Void) {
        guard !isClosed else {
            completion(.success(Data()))
            return
        }
        // Enforce the one-outstanding-read contract; a violation would silently
        // drop bytes.
        guard !readOutstanding else {
            assertionFailure("NWByteStream.read called while a read was already outstanding")
            return
        }
        readOutstanding = true

        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.readOutstanding = false

            if let error {
                completion(.failure(ByteStreamError.transport(Self.describe(error))))
                return
            }
            if let data, !data.isEmpty {
                // Deliver the bytes first; the *next* read will report EOF, which
                // is what the sequential handshake code expects.
                completion(.success(data))
                return
            }
            if isComplete {
                completion(.success(Data()))
                return
            }
            // No data, not complete: loop rather than returning an empty success,
            // which the callers would misread as EOF.
            self.read(completion: completion)
        }
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    // MARK: Helpers

    static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            return "POSIX \(code.rawValue) (\(Self.posixName(code)))"
        case .dns(let code):
            // DNSServiceErrorType is a plain Int32, not a RawRepresentable enum.
            return "DNS error \(code)"
        case .tls(let code):
            // OSStatus is likewise a plain Int32.
            return "TLS handshake failed (OSStatus \(code): \(Self.tlsName(code)))"
        @unknown default:
            return "\(error)"
        }
    }

    private static func posixName(_ code: POSIXErrorCode) -> String {
        switch code {
        case .ECONNREFUSED: return "connection refused"
        case .ETIMEDOUT:    return "timed out"
        case .ENETUNREACH:  return "network unreachable"
        case .EHOSTUNREACH: return "host unreachable"
        case .ECONNRESET:   return "connection reset"
        case .EADDRNOTAVAIL:return "address not available"
        case .EPIPE:        return "broken pipe"
        default:            return "error"
        }
    }

    private static func tlsName(_ code: OSStatus) -> String {
        switch code {
        case errSSLXCertChainInvalid: return "certificate chain invalid"
        case errSSLUnknownRootCert:   return "unknown root certificate"
        case errSSLCertExpired:       return "certificate expired"
        case errSSLHostNameMismatch:  return "host name mismatch"
        case errSSLClosedAbort:       return "connection aborted during handshake"
        case errSSLProtocol:          return "protocol error (proxy may not be speaking TLS)"
        default:                      return "handshake error"
        }
    }
}
