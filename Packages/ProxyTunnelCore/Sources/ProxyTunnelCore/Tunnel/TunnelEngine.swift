//
//  TunnelEngine.swift
//  ProxyTunnelCore
//
//  The packet tunnel's brain.
//
//  ```
//  NEPacketTunnelFlow.readPackets
//        │  raw IPv4 / IPv6 packets
//        ▼
//   ParsedIPPacket  ──►  TCP  ──►  TCPConnection ──► SOCKS5 / HTTP CONNECT ──► proxy ──► internet
//        │                └──►  UDP  ──► SOCKS5 UDP ASSOCIATE relay
//        └──►  UDP:53  ──►  DNSTunnelResolver (UDP relay or DNS-over-TCP through the proxy)
//  ```
//
//  Every method runs on a single serial `DispatchQueue`. That is the whole
//  concurrency design: the packet loop, the proxy callbacks and the timers all
//  hop onto that queue before touching state, so there are no locks and no data
//  races to reason about.
//

import Foundation
import Network

#if canImport(Darwin)
import Darwin
#endif

public final class TunnelEngine: ProxyStreamOpening {

    // MARK: - Types

    public enum EngineState: String, Sendable {
        case idle
        case starting
        case running
        case stopping
        case stopped
        case failed
    }

    public struct Dependencies {
        public let configuration: TunnelConfiguration
        public let credential: ProxyCredential?
        public let packetFlow: PacketFlowIO
        public let queue: DispatchQueue
        public let log: DiagnosticLog
        /// The physical interface to bind the proxy transport to, when the
        /// extension could determine one. Belt and braces alongside the excluded
        /// routes.
        public let requiredInterface: NWInterface?
        /// Extra addresses to keep out of the tunnel.
        public let additionallyExcludedAddresses: [String]

        public init(
            configuration: TunnelConfiguration,
            credential: ProxyCredential?,
            packetFlow: PacketFlowIO,
            queue: DispatchQueue,
            log: DiagnosticLog,
            requiredInterface: NWInterface? = nil,
            additionallyExcludedAddresses: [String] = []
        ) {
            self.configuration = configuration
            self.credential = credential
            self.packetFlow = packetFlow
            self.queue = queue
            self.log = log
            self.requiredInterface = requiredInterface
            self.additionallyExcludedAddresses = additionallyExcludedAddresses
        }
    }

    /// Limits. Chosen to be generous for a phone while still bounding memory.
    public struct Limits {
        public var maximumTCPConnections: Int = 256
        public var maximumConcurrentDNSQueries: Int = 24
        public var maximumUDPFlows: Int = 512
        public var udpFlowIdleSeconds: TimeInterval = 120
        public var sweepIntervalSeconds: TimeInterval = 30

        public init() {}
    }

    // MARK: - State

    public private(set) var state: EngineState = .idle {
        didSet {
            guard state != oldValue else { return }
            log.info("engine", "state: \(oldValue.rawValue) -> \(state.rawValue)")
            onStateChange?(state)
        }
    }

    /// Called on `queue` whenever the engine state changes.
    public var onStateChange: ((EngineState) -> Void)?

    public private(set) var statistics = TunnelStatistics()
    public private(set) var connectedSince: Date?
    public var networkSettingsApplied = false
    public var networkSettingsDescription: [String] = []
    public var lastFailure: TunnelFailure?

    // MARK: - Collaborators

    private let configuration: TunnelConfiguration
    private let credential: ProxyCredential?
    private let packetFlow: PacketFlowIO
    private let queue: DispatchQueue
    private let log: DiagnosticLog
    private let requiredInterface: NWInterface?
    private let limits: Limits

    private lazy var writeCoalescer = PacketWriteCoalescer(flow: packetFlow, queue: queue)

    // MARK: - Flow tables

    private var tcpFlows: [TCPFlowKey: TCPConnection] = [:]
    private var udpFlowLastSeen: [UDPFlowKey: Date] = [:]
    private var udpReverseIndex: [UDPReverseKey: UDPFlowKey] = [:]
    private var udpRelay: SOCKS5UDPRelay?
    private var udpRelayIsStarting = false
    private var udpRelayFailed = false
    private var activeDNSQueries = 0

    private var isReading = false
    private var sweepTimer: DispatchWorkItem?
    private var hasWarnedAboutIPv6OnlyProxy = false

    // MARK: - Init

    public init(dependencies: Dependencies, limits: Limits = Limits()) {
        self.configuration = dependencies.configuration
        self.credential = dependencies.credential
        self.packetFlow = dependencies.packetFlow
        self.queue = dependencies.queue
        self.log = dependencies.log
        self.requiredInterface = dependencies.requiredInterface
        self.limits = limits
    }

    /// The proxy endpoint, including the credential the extension was given.
    public var endpoint: ProxyEndpoint {
        configuration.proxyEndpoint(credential: credential)
    }

    /// Addresses the app resolved for us. Dialling only these means the extension
    /// never performs a DNS lookup, which is what makes it safe to start the
    /// tunnel before any name resolution has happened inside it.
    public var transportTargets: [TransportTarget] {
        var targets = ProxyConnector.targets(
            for: endpoint,
            resolvedAddresses: configuration.resolvedProxyAddresses
        )
        if targets.isEmpty {
            // Degenerate case: the app failed to resolve. Fall back to the name so
            // the tunnel at least reports a meaningful error instead of dying.
            let tlsName: String? = configuration.protocolType.usesTLS ? configuration.host : nil
            targets = [TransportTarget(
                host: configuration.host,
                port: endpoint.portValue,
                tlsServerName: tlsName
            )]
        }
        return targets
    }

    // MARK: - Lifecycle

    public func start() {
        guard state == .idle || state == .stopped || state == .failed else { return }
        state = .starting
        statistics = TunnelStatistics()
        statistics.startedAt = Date()
        connectedSince = Date()
        udpRelayFailed = false

        log.info("engine", "starting tunnel: \(configuration.redactedSummary)")
        if credential == nil && configuration.username?.isEmpty == false {
            log.warning("engine", "a username is configured but no password reached the extension; authentication will fail")
        }

        if configuration.relayUDP && configuration.protocolType.supportsUDP {
            startUDPRelay()
        } else if configuration.relayUDP {
            log.info("engine", "UDP relay not available for \(configuration.protocolType.displayName); non-DNS UDP will be dropped")
            statistics.udpRelayAvailable = false
        }

        statistics.udpRelayAvailable = udpRelay != nil
        state = .running
        isReading = true
        readNextBatch()
        scheduleSweep()
    }

    public func stop(reason: String = "requested") {
        guard state != .stopped && state != .stopping else { return }
        state = .stopping
        log.info("engine", "stopping tunnel (\(reason))")
        isReading = false
        statistics.stoppedAt = Date()

        sweepTimer?.cancel(); sweepTimer = nil

        for (_, connection) in tcpFlows {
            connection.close(.clientClosed)
        }
        tcpFlows.removeAll()
        udpRelay?.close()
        udpRelay = nil
        udpFlowLastSeen.removeAll()
        udpReverseIndex.removeAll()

        state = .stopped
    }

    // MARK: - Status

    public func makeStatusPayload() -> TunnelStatusPayload {
        TunnelStatusPayload(
            engineState: state.rawValue,
            connectedSince: connectedSince,
            statistics: statistics,
            lastFailure: lastFailure,
            networkSettingsApplied: networkSettingsApplied,
            networkSettingsDescription: networkSettingsDescription,
            configurationSummary: configuration.redactedSummary,
            udpRelayDescription: udpRelay?.diagnosticDescription,
            physicalInterface: requiredInterface.map { "\($0.name) (\($0.type))" },
            recentLog: log.snapshot().suffix(120).map {
                "\($0.timestamp.formatted(date: .omitted, time: .standard)) [\($0.category)] \($0.message)"
            }
        )
    }

    /// Per-connection detail for the Diagnostics screen.
    public func connectionDiagnostics() -> [String] {
        tcpFlows.values
            .sorted { $0.createdAt < $1.createdAt }
            .map { $0.diagnosticSummary }
    }

    // MARK: - Packet loop

    private func readNextBatch() {
        guard isReading else { return }
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            self.queue.async {
                guard self.isReading else { return }
                for (index, packet) in packets.enumerated() {
                    let family = index < protocols.count ? protocols[index].int32Value : AF_INET
                    self.handlePacket(packet, family: family)
                }
                self.readNextBatch()
            }
        }
    }

    private func handlePacket(_ data: Data, family: Int32) {
        statistics.packetsFromTunnel += 1
        statistics.bytesFromTunnel += data.count

        let packet: ParsedIPPacket
        do {
            packet = try ParsedIPPacket.parse(data)
        } catch IPPacketError.fragmented {
            statistics.droppedFragments += 1
            return
        } catch {
            statistics.droppedMalformedPackets += 1
            return
        }

        switch packet.protocolNumber {
        case IPProtocolNumber.tcp:
            handleTCP(packet)
        case IPProtocolNumber.udp:
            handleUDP(packet)
        default:
            statistics.droppedUnsupportedTransport += 1
        }
    }

    // MARK: - TCP

    private func handleTCP(_ packet: ParsedIPPacket) {
        let segment: TCPSegment
        do {
            segment = try TCPSegment.parse(packet.payload)
        } catch {
            statistics.droppedMalformedPackets += 1
            return
        }

        let key = TCPFlowKey(
            clientAddress: packet.source,
            clientPort: segment.sourcePort,
            remoteAddress: packet.destination,
            remotePort: segment.destinationPort
        )

        if let existing = tcpFlows[key] {
            if segment.hasSYN && !segment.hasACK {
                // The app is retransmitting its SYN: our SYN-ACK (or its ACK) was
                // lost. Answer again instead of creating a second connection.
                existing.retransmitSYNACK()
                return
            }
            existing.handleInbound(segment)
            return
        }

        // Only a bare SYN may create a connection.
        guard segment.hasSYN && !segment.hasACK else {
            sendReset(for: packet, segment: segment, family: packet.version)
            return
        }

        if let blocked = blockedReason(for: packet.destination) {
            statistics.droppedBlockedDestination += 1
            log.debug("engine", "refusing \(key.description): \(blocked)")
            sendReset(for: packet, segment: segment, family: packet.version)
            return
        }

        guard tcpFlows.count < limits.maximumTCPConnections else {
            statistics.tcpConnectionsRejected += 1
            log.warning("engine", "refusing \(key.description): \(tcpFlows.count) connections already open")
            sendReset(for: packet, segment: segment, family: packet.version)
            return
        }

        let connection = TCPConnection(
            configuration: TCPConnection.Configuration(
                clientAddress: packet.source,
                clientPort: segment.sourcePort,
                remoteAddress: packet.destination,
                remotePort: segment.destinationPort,
                maximumSegmentSize: maximumSegmentSize(for: packet.version),
                idleTimeout: TimeInterval(configuration.idleTimeoutSeconds),
                tracePackets: configuration.tracePackets
            ),
            queue: queue,
            connector: self,
            log: log,
            emit: { [weak self] outbound in
                guard let self else { return }
                self.emitPacket(outbound)
            },
            onClose: { [weak self] reason, stats in
                guard let self else { return }
                self.tcpFlows.removeValue(forKey: key)
                self.statistics.tcpConnectionsClosed += 1
                self.statistics.tcpActiveConnections = self.tcpFlows.count
                self.statistics.tcpBytesToProxy += stats.bytesToProxy
                self.statistics.tcpBytesFromProxy += stats.bytesFromProxy
                self.statistics.tcpRetransmissions += stats.retransmissions
                if case .proxyUnavailable(let error) = reason {
                    self.statistics.recordProxyFailure(error)
                }
            }
        )

        tcpFlows[key] = connection
        statistics.tcpConnectionsOpened += 1
        statistics.tcpActiveConnections = tcpFlows.count
        connection.open(withSYN: segment)
    }

    private func maximumSegmentSize(for version: IPVersion) -> Int {
        // MTU minus the fixed IP and TCP headers. No IP options are generated and
        // no IPv6 extension headers are used on the way out.
        switch version {
        case .v4: return configuration.mtu - 20 - 20
        case .v6: return configuration.mtu - 40 - 20
        }
    }

    /// Destinations this tunnel refuses to proxy, with the reason.
    ///
    /// Looping back into ourselves is the failure mode that matters: a packet
    /// addressed to the proxy's own IP would be handed back to the proxy through
    /// the tunnel, and so on for ever.
    private func blockedReason(for destination: IPAddress) -> String? {
        if destination.isLoopback { return "loopback destination" }
        if destination.isMulticast { return "multicast destination" }
        if destination.isLinkLocal { return "link-local destination" }
        if destination.isUnspecified { return "unspecified destination" }
        if destination.description == configuration.ipv4Address { return "the tunnel's own address" }
        if destination.description == configuration.ipv6Address { return "the tunnel's own address" }
        if configuration.resolvedProxyAddresses.contains(destination.description) {
            // Should be unreachable because the proxy's addresses are excluded
            // from the routes, but a stale route or an address the app did not see
            // would otherwise create a loop.
            return "the proxy's own address (would loop)"
        }
        return nil
    }

    private func sendReset(for packet: ParsedIPPacket, segment: TCPSegment, family: IPVersion) {
        // RST,ACK with SEQ = the acknowledgment we would have sent, which is
        // inside the peer's window and therefore accepted.
        let reset = TCPSegment(
            sourcePort: segment.destinationPort,
            destinationPort: segment.sourcePort,
            sequenceNumber: segment.hasACK ? segment.acknowledgmentNumber : 0,
            acknowledgmentNumber: segment.sequenceNumber &+ UInt32(segment.payload.count) &+ (segment.hasSYN ? 1 : 0),
            flags: segment.hasACK ? [.rst] : [.rst, .ack],
            windowSize: 0
        )
        let raw = reset.serialized(source: packet.destination, destination: packet.source)
        let outbound = ParsedIPPacket.build(
            source: packet.destination,
            destination: packet.source,
            protocolNumber: IPProtocolNumber.tcp,
            payload: [UInt8](raw),
            identification: UInt16.random(in: 1...60000),
            hopLimit: 64
        )
        emitPacket(outbound)
    }

    // MARK: - UDP

    private struct UDPFlowKey: Hashable {
        let clientAddress: IPAddress
        let clientPort: UInt16
        let remoteAddress: IPAddress
        let remotePort: UInt16
    }

    private struct UDPReverseKey: Hashable {
        let remoteAddress: IPAddress
        let remotePort: UInt16
    }

    private func handleUDP(_ packet: ParsedIPPacket) {
        let datagram: UDPDatagram
        do {
            datagram = try UDPDatagram.parse(packet.payload)
        } catch {
            statistics.droppedMalformedPackets += 1
            return
        }

        let flowKey = UDPFlowKey(
            clientAddress: packet.source,
            clientPort: datagram.sourcePort,
            remoteAddress: packet.destination,
            remotePort: datagram.destinationPort
        )
        let reverseKey = UDPReverseKey(
            remoteAddress: packet.destination,
            remotePort: datagram.destinationPort
        )

        // DNS is handled specially and always, because it must work for HTTP
        // proxies too and must never leak to the physical network.
        if datagram.destinationPort == 53 || datagram.destinationPort == 5353 {
            handleDNSQuery(packet: packet, datagram: datagram)
            return
        }

        guard configuration.relayUDP, configuration.protocolType.supportsUDP else {
            statistics.udpDatagramsDropped += 1
            return
        }
        guard let relay = udpRelay else {
            // The relay may still be starting up, or it may have failed.
            if !udpRelayIsStarting && !udpRelayFailed {
                startUDPRelay()
            }
            statistics.udpDatagramsDropped += 1
            return
        }

        if udpFlowLastSeen[flowKey] == nil {
            guard udpFlowLastSeen.count < limits.maximumUDPFlows else {
                statistics.udpDatagramsDropped += 1
                return
            }
        }
        udpFlowLastSeen[flowKey] = Date()
        udpReverseIndex[reverseKey] = flowKey

        relay.send(payload: datagram.payload, to: packet.destination.description, port: datagram.destinationPort) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.statistics.udpDatagramsRelayed += 1
            case .failure(let error):
                self.statistics.udpDatagramsDropped += 1
                self.log.debug("udp", "relay send failed: \(error)")
            }
        }
    }

    private func startUDPRelay() {
        guard udpRelay == nil, !udpRelayIsStarting, !udpRelayFailed else { return }
        guard configuration.protocolType.supportsUDP else { return }
        udpRelayIsStarting = true

        SOCKS5UDPRelay.establish(
            endpoint: endpoint,
            targets: transportTargets,
            queue: queue,
            timeout: 15,
            requiredInterface: requiredInterface,
            log: log
        ) { [weak self] result in
            guard let self else { return }
            self.udpRelayIsStarting = false
            switch result {
            case .success(let relay):
                guard self.state == .running else {
                    relay.close()
                    return
                }
                self.udpRelay = relay
                self.statistics.udpRelayAvailable = true
                self.readFromUDPRelay(relay)
            case .failure(let error):
                self.udpRelayFailed = true
                self.statistics.udpRelayAvailable = false
                self.statistics.recordProxyFailure(error)
                self.log.warning("udp", "could not establish a SOCKS5 UDP relay: \(error.diagnosticDescription). Non-DNS UDP will be dropped.")
            }
        }
    }

    private func readFromUDPRelay(_ relay: SOCKS5UDPRelay) {
        guard udpRelay === relay, state == .running else { return }
        relay.receive { [weak self] result in
            guard let self, self.udpRelay === relay else { return }
            switch result {
            case .success(let datagram):
                self.statistics.udpDatagramsReceived += 1
                self.deliverUDPToClient(datagram)
                self.readFromUDPRelay(relay)
            case .failure(let error):
                self.log.debug("udp", "relay receive ended: \(error)")
                relay.close()
                self.udpRelay = nil
                self.statistics.udpRelayAvailable = false
            }
        }
    }

    private func deliverUDPToClient(_ datagram: SOCKS5.UDPDatagram) {
        guard let remoteAddress = IPAddress(presentationName: datagram.destinationHost) else { return }
        let reverseKey = UDPReverseKey(remoteAddress: remoteAddress, remotePort: datagram.destinationPort)
        guard let flow = udpReverseIndex[reverseKey] else {
            // No flow asked for this. Dropping is correct: forwarding it to an
            // arbitrary client port would be a spoofing vector.
            return
        }
        udpFlowLastSeen[flow] = Date()

        let response = UDPDatagram(
            sourcePort: flow.remotePort,
            destinationPort: flow.clientPort,
            payload: datagram.payload
        )
        let raw = response.serialized(source: flow.remoteAddress, destination: flow.clientAddress)
        let packet = ParsedIPPacket.build(
            source: flow.remoteAddress,
            destination: flow.clientAddress,
            protocolNumber: IPProtocolNumber.udp,
            payload: [UInt8](raw),
            identification: UInt16.random(in: 1...60000),
            hopLimit: 64
        )
        emitPacket(packet)
    }

    // MARK: - DNS

    private func handleDNSQuery(packet: ParsedIPPacket, datagram: UDPDatagram) {
        guard activeDNSQueries < limits.maximumConcurrentDNSQueries else {
            statistics.dnsQueriesFailed += 1
            return
        }
        activeDNSQueries += 1
        statistics.dnsQueriesHandled += 1

        let server = packet.destination.description
        let port = datagram.destinationPort
        let query = datagram.payload

        let completion: (Result<Data, ProxyError>) -> Void = { [weak self] result in
            guard let self else { return }
            self.activeDNSQueries = max(0, self.activeDNSQueries - 1)
            switch result {
            case .success(let response):
                self.deliverDNSToClient(response: response, packet: packet, datagram: datagram)
            case .failure(let error):
                self.statistics.dnsQueriesFailed += 1
                self.statistics.recordProxyFailure(error)
                self.log.debug("dns", "query for \(server) failed: \(error.diagnosticDescription)")
            }
        }

        if let relay = udpRelay {
            DNSTunnelResolver.resolveViaUDPRelay(
                query: query,
                server: server,
                port: port,
                relay: relay,
                timeout: 10,
                queue: queue,
                log: log,
                completion: completion
            )
        } else {
            // No UDP path: carry the query as DNS-over-TCP inside a proxied stream.
            DNSTunnelResolver.resolveOverTCP(
                query: query,
                server: server,
                port: port,
                opener: self,
                timeout: 15,
                queue: queue,
                log: log,
                completion: completion
            )
        }
    }

    private func deliverDNSToClient(response: Data, packet: ParsedIPPacket, datagram: UDPDatagram) {
        let reply = UDPDatagram(
            sourcePort: datagram.destinationPort,
            destinationPort: datagram.sourcePort,
            payload: response
        )
        let raw = reply.serialized(source: packet.destination, destination: packet.source)
        let outbound = ParsedIPPacket.build(
            source: packet.destination,
            destination: packet.source,
            protocolNumber: IPProtocolNumber.udp,
            payload: [UInt8](raw),
            identification: UInt16.random(in: 1...60000),
            hopLimit: 64
        )
        emitPacket(outbound)
    }

    // MARK: - Packet emission

    private func emitPacket(_ packet: Data) {
        guard let first = packet.first else { return }
        let family: Int32 = (first >> 4) == 6 ? AF_INET6 : AF_INET
        statistics.packetsToTunnel += 1
        statistics.bytesToTunnel += packet.count
        writeCoalescer.write(packet, family: family)
    }

    // MARK: - ProxyStreamOpening

    /// Opens one proxied TCP stream. Called by every `TCPConnection` and by the
    /// DNS-over-TCP path.
    public func openProxyStream(
        to destination: ProxyDestination,
        queue: DispatchQueue,
        completion: @escaping (Result<ProxyConnection, ProxyError>) -> Void
    ) {
        ProxyConnector.connect(
            endpoint: endpoint,
            destination: destination,
            targets: transportTargets,
            queue: queue,
            connectTimeout: 15,
            handshakeTimeout: 20,
            requiredInterface: requiredInterface,
            log: log
        ) { [weak self] result in
            if case .failure(let error) = result {
                self?.statistics.recordProxyFailure(error)
                if case .addressFamilyUnsupported = error {
                    self?.noteIPv6OnlyProxy()
                }
            }
            completion(result)
        }
    }

    private func noteIPv6OnlyProxy() {
        guard !hasWarnedAboutIPv6OnlyProxy else { return }
        hasWarnedAboutIPv6OnlyProxy = true
        log.warning(
            "engine",
            "the proxy refused an address in one family. If the proxy is IPv4-only, IPv6 destinations will fail; disable IPv6 in Settings to avoid trying them."
        )
    }

    // MARK: - Maintenance

    private func scheduleSweep() {
        sweepTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .running else { return }
            self.sweep()
            self.scheduleSweep()
        }
        sweepTimer = work
        queue.asyncAfter(deadline: .now() + limits.sweepIntervalSeconds, execute: work)
    }

    private func sweep() {
        let cutoff = Date().addingTimeInterval(-limits.udpFlowIdleSeconds)
        let stale = udpFlowLastSeen.filter { $0.value < cutoff }.map { $0.key }
        for key in stale {
            udpFlowLastSeen.removeValue(forKey: key)
            udpReverseIndex = udpReverseIndex.filter { $0.value != key }
        }
        if !stale.isEmpty {
            log.debug("engine", "expired \(stale.count) idle UDP flow(s)")
        }
        statistics.tcpActiveConnections = tcpFlows.count
    }

    // MARK: - Runtime configuration

    public func setTracePackets(_ enabled: Bool) {
        // Individual connections capture the flag at construction time, so this
        // affects connections opened from now on. Stated plainly in the UI.
        log.info("engine", "packet tracing \(enabled ? "enabled" : "disabled") for new connections")
    }
}
