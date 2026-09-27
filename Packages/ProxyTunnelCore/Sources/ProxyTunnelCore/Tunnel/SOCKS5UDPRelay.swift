//
//  SOCKS5UDPRelay.swift
//  ProxyTunnelCore
//
//  SOCKS5 UDP ASSOCIATE (RFC 1928 §7).
//
//  A SOCKS5 server relays datagrams over a *separate* UDP socket, not over the
//  TCP control connection:
//
//      1. the client opens a TCP connection and sends UDP ASSOCIATE
//      2. the server replies with BND.ADDR / BND.PORT — its UDP relay endpoint
//      3. the client sends datagrams to that endpoint, each prefixed with a
//         SOCKS5 UDP request header
//      4. replies arrive from the same endpoint, each prefixed with the same
//         header describing the *origin* of the reply
//      5. the association lives until the TCP control connection is closed
//
//  Step 5 is the trap: if the control connection drops, the relay silently stops
//  working. `SOCKS5UDPRelay` therefore holds the control connection for its whole
//  lifetime and reports failure if it goes away.
//

import Foundation
import Network

public final class SOCKS5UDPRelay {

    public let relayHost: String
    public let relayPort: UInt16
    /// The bound address the server reported, useful for diagnostics.
    public let reportedBoundHost: String

    private let controlConnection: ProxyConnection
    private let udpConnection: NWConnection
    private let queue: DispatchQueue
    private let log: DiagnosticLog?
    private var receiveOutstanding = false
    private var isClosed = false

    private init(
        controlConnection: ProxyConnection,
        relayHost: String,
        relayPort: UInt16,
        reportedBoundHost: String,
        queue: DispatchQueue,
        log: DiagnosticLog?
    ) {
        self.controlConnection = controlConnection
        self.relayHost = relayHost
        self.relayPort = relayPort
        self.reportedBoundHost = reportedBoundHost
        self.queue = queue
        self.log = log

        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        parameters.preferNoProxies = true
        self.udpConnection = NWConnection(
            host: NWEndpoint.Host(relayHost),
            port: NWEndpoint.Port(rawValue: relayPort) ?? .any,
            using: parameters
        )
    }

    // MARK: - Establishment

    /// Performs UDP ASSOCIATE over a fresh TCP connection to the proxy.
    ///
    /// - Note: SOCKS5 only. HTTP proxies have no datagram relay, so callers must
    ///   check `ProxyProtocol.supportsUDP` first.
    public static func establish(
        endpoint: ProxyEndpoint,
        targets: [TransportTarget],
        queue: DispatchQueue,
        timeout: TimeInterval = 15,
        requiredInterface: NWInterface? = nil,
        log: DiagnosticLog? = nil,
        completion: @escaping (Result<SOCKS5UDPRelay, ProxyError>) -> Void
    ) {
        guard endpoint.protocolType == .socks5 else {
            completion(.failure(.addressFamilyUnsupported))
            return
        }

        ProxyConnector.connect(
            endpoint: endpoint,
            destination: .udpAssociate(host: "0.0.0.0", port: 0),
            targets: targets,
            queue: queue,
            connectTimeout: timeout,
            handshakeTimeout: timeout,
            requiredInterface: requiredInterface,
            log: log
        ) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))

            case .success(let connection):
                let reportedHost = connection.outcome.boundHost ?? ""
                let reportedPort = connection.outcome.boundPort ?? 0

                // Many servers answer 0.0.0.0:0, which means "use the address you
                // are already talking to me on". RFC 1928 does not require the
                // server to know its own routable address.
                let relayHost: String
                if reportedHost.isEmpty || reportedHost == "0.0.0.0" || reportedHost == "::" {
                    relayHost = connection.dialedTarget.host
                } else {
                    relayHost = reportedHost
                }
                let relayPort: UInt16 = reportedPort != 0
                    ? reportedPort
                    : connection.dialedTarget.port

                guard relayPort != 0 else {
                    connection.close()
                    completion(.failure(.badServerResponse("UDP ASSOCIATE returned no relay port")))
                    return
                }

                let relay = SOCKS5UDPRelay(
                    controlConnection: connection,
                    relayHost: relayHost,
                    relayPort: relayPort,
                    reportedBoundHost: reportedHost,
                    queue: queue,
                    log: log
                )
                relay.start(completion: completion)
            }
        }
    }

    private func start(completion: @escaping (Result<SOCKS5UDPRelay, ProxyError>) -> Void) {
        var hasCompleted = false
        udpConnection.stateUpdateHandler = { [weak self] state in
            guard let self, !hasCompleted else { return }
            switch state {
            case .ready:
                hasCompleted = true
                self.log?.info("udp", "SOCKS5 UDP relay ready at \(self.relayHost):\(self.relayPort)")
                completion(.success(self))
            case .waiting(let error):
                hasCompleted = true
                self.controlConnection.close()
                completion(.failure(.connectionFailed("UDP relay unreachable: \(NWByteStream.describe(error))")))
            case .failed(let error):
                hasCompleted = true
                self.controlConnection.close()
                completion(.failure(.connectionFailed("UDP relay failed: \(NWByteStream.describe(error))")))
            case .cancelled:
                if !hasCompleted {
                    hasCompleted = true
                    completion(.failure(.cancelled))
                }
            case .setup, .preparing:
                break
            @unknown default:
                break
            }
        }
        udpConnection.start(queue: queue)
    }

    // MARK: - Data path

    /// Sends one datagram to `host:port` through the relay.
    public func send(payload: Data, to host: String, port: UInt16, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isClosed else {
            completion(.failure(ByteStreamError.closed))
            return
        }
        let framed: Data
        do {
            framed = try SOCKS5.encodeUDPDatagram(host: host, port: port, payload: payload)
        } catch {
            completion(.failure(error))
            return
        }
        udpConnection.send(content: framed, completion: .contentProcessed { error in
            if let error {
                completion(.failure(ByteStreamError.transport(NWByteStream.describe(error))))
            } else {
                completion(.success(()))
            }
        })
    }

    /// Pulls one datagram. At most one receive may be outstanding.
    ///
    /// Datagrams with `FRAG != 0` are dropped: RFC 1928 makes fragmentation
    /// optional and almost no server implements it, and silently reassembling
    /// would be worse than reporting nothing.
    public func receive(completion: @escaping (Result<SOCKS5.UDPDatagram, Error>) -> Void) {
        guard !isClosed else {
            completion(.failure(ByteStreamError.closed))
            return
        }
        guard !receiveOutstanding else {
            assertionFailure("SOCKS5UDPRelay.receive called with a receive already outstanding")
            return
        }
        receiveOutstanding = true

        udpConnection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            self.receiveOutstanding = false
            if let error {
                completion(.failure(ByteStreamError.transport(NWByteStream.describe(error))))
                return
            }
            guard let data, !data.isEmpty else {
                // An empty datagram carries no information we can use.
                self.receive(completion: completion)
                return
            }
            do {
                let datagram = try SOCKS5.parseUDPDatagram(data)
                if datagram.fragment != 0 {
                    self.log?.debug("udp", "dropping fragmented SOCKS5 UDP datagram (FRAG=\(datagram.fragment))")
                    self.receive(completion: completion)
                    return
                }
                completion(.success(datagram))
            } catch {
                completion(.failure(error))
            }
        }
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        udpConnection.stateUpdateHandler = nil
        udpConnection.cancel()
        // Closing the control connection is what actually tears the association
        // down on the server side.
        controlConnection.close()
    }

    public var isFinished: Bool { isClosed }

    public var diagnosticDescription: String {
        "SOCKS5 UDP relay \(relayHost):\(relayPort) (server reported \"\(reportedBoundHost)\")"
    }
}
