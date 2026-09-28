//
//  TunnelEngineTests.swift
//  ProxyTunnelCoreTests
//
//  The whole tunnel, end to end, with no device and no entitlement:
//
//      scripted packet flow  →  TunnelEngine  →  real SOCKS5 client
//                                              →  real SOCKS5 server on loopback
//                                              →  real target server
//                                              →  and all the way back
//
//  If these pass, the packet path, the flow table, the TCP state machine, the
//  proxy handshake and the return path are all wired together correctly. They say
//  nothing about whether iOS will let the extension run — that needs the Network
//  Extension entitlement, and `docs/TESTING.md` is explicit about it.
//

import XCTest
import Network
@testable import ProxyTunnelCore

final class TunnelEngineTests: XCTestCase {

    private var echoServer: LocalEchoServer!
    private var socksServer: LocalSOCKS5Server!
    private var echoPort: UInt16 = 0
    private var socksPort: UInt16 = 0

    private var flow: ScriptedPacketFlow!
    private var engine: TunnelEngine!
    private let engineQueue = DispatchQueue(label: "tunnel.engine.test")

    /// A routable-looking destination. It must not be loopback, because the engine
    /// deliberately refuses to proxy loopback addresses; the test proxy redirects
    /// the connection to the local echo server so nothing leaves the machine.
    private let fakeDestination = IPAddress(presentationName: "93.184.216.34")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        echoServer = try LocalEchoServer()
        echoPort = try echoServer.start()
        socksServer = try LocalSOCKS5Server()
        socksPort = try socksServer.start()
        flow = ScriptedPacketFlow()

        // The engine tests dial a real proxy, so they need the same capability the
        // integration tests do. See LoopbackRequirement.
        let socksReachable = LoopbackRequirement.isReachable(port: socksPort)
        let socksViaProductionTransport = LoopbackRequirement.canOpenProxyTransport(port: socksPort)
        print("""
        [ProxyTunnelTests] engine ports: socks5=\(socksPort) (pinned: \(socksServer.isPinnedToLoopback)) \
        echo=\(echoPort) | plain-probe reachable: \(socksReachable) | \
        production-transport reachable: \(socksViaProductionTransport)
        """)

        try LoopbackRequirement.require(port: socksPort)
        try LoopbackRequirement.requireProxyTransport(port: socksPort)
    }

    override func tearDownWithError() throws {
        engine?.stop(reason: "test teardown")
        engine = nil
        socksServer?.stop()
        echoServer?.stop()
        try super.tearDownWithError()
    }

    // MARK: Construction

    private func makeConfiguration(
        relayUDP: Bool = false,
        dnsServers: [String] = ["198.51.100.53"],
        credential: ProxyCredential? = nil,
        allowIPv6: Bool = true
    ) -> TunnelConfiguration {
        TunnelConfiguration(
            profileID: UUID().uuidString,
            profileName: "Test Proxy",
            host: "127.0.0.1",
            port: Int(socksPort),
            protocolType: .socks5,
            username: credential?.username,
            inlinePassword: credential?.password,
            resolvedProxyAddresses: ["127.0.0.1"],
            dnsServers: dnsServers,
            relayUDP: relayUDP,
            allowIPv6: allowIPv6,
            credentialDelivery: credential == nil ? .none : .inlineProviderConfiguration
        )
    }

    private func startEngine(configuration: TunnelConfiguration, credential: ProxyCredential? = nil) {
        engine = TunnelEngine(dependencies: .init(
            configuration: configuration,
            credential: credential,
            packetFlow: flow,
            queue: engineQueue,
            log: DiagnosticLog(subsystem: "test", capacity: 64)
        ))
        engine.start()
    }

    // MARK: Driving the engine

    @discardableResult
    private func deliver(_ packets: [Data], timeout: TimeInterval = 3) -> Bool {
        guard flow.waitForPendingRead(timeout: timeout) else { return false }
        return flow.deliver(packets)
    }

    /// Feeds packets in and waits for the engine queue to finish with them.
    ///
    /// `deliver` hands the batch to the engine's `readPackets` completion, which
    /// hops onto the engine queue before touching any state. Without this wait, a
    /// test that reads a counter straight afterwards is racing the engine — which
    /// is exactly what made the statistics assertions flaky.
    private func deliverAndSettle(_ packets: [Data], settleFor: TimeInterval = 0.2, timeout: TimeInterval = 3) {
        XCTAssertTrue(deliver(packets, timeout: timeout), "the engine is not reading packets")
        settle(settleFor)
    }

    private func settle(_ seconds: TimeInterval) {
        let expectation = XCTestExpectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { expectation.fulfill() }
        wait(for: [expectation], timeout: seconds + 3)
    }

    private func waitForWrittenPacket(
        timeout: TimeInterval = 6,
        _ predicate: (ParsedIPPacket, TCPSegment) -> Bool
    ) -> (ParsedIPPacket, TCPSegment)? {
        let deadline = Date().addingTimeInterval(timeout)
        var index = 0
        while Date() < deadline {
            let snapshot = flow.snapshot()
            while index < snapshot.count {
                let packet = snapshot[index]
                index += 1
                if let parsed = try? TestPackets.parseTCP(packet), predicate(parsed.0, parsed.1) {
                    return parsed
                }
            }
            _ = flow.waitForPendingRead(timeout: 0.02)
        }
        return nil
    }

    private func waitForWrittenUDPPacket(timeout: TimeInterval = 6) -> (ParsedIPPacket, UDPDatagram)? {
        let deadline = Date().addingTimeInterval(timeout)
        var index = 0
        while Date() < deadline {
            let snapshot = flow.snapshot()
            while index < snapshot.count {
                let packet = snapshot[index]
                index += 1
                if let parsed = try? ParsedIPPacket.parse(packet), parsed.isUDP,
                   let datagram = try? UDPDatagram.parse(parsed.payload) {
                    return (parsed, datagram)
                }
            }
            _ = flow.waitForPendingRead(timeout: 0.02)
        }
        return nil
    }

    private func clientSYN(destination: IPAddress? = nil, destinationPort: UInt16 = 443) -> Data {
        TestPackets.tcpPacket(
            destination: destination ?? fakeDestination,
            destinationPort: destinationPort,
            sequence: 1000,
            flags: [.syn],
            options: TestPackets.synOptions
        )
    }

    // MARK: Tests

    func testEngineStartsAndAsksForPackets() {
        startEngine(configuration: makeConfiguration())
        XCTAssertTrue(flow.waitForPendingRead(), "the engine must start reading packets")
        XCTAssertEqual(engine.state, .running)
    }

    func testSYNProducesASYNACKAndOpensAProxyConnection() throws {
        socksServer.redirectAllConnectionsTo = (host: "127.0.0.1", port: echoPort)
        startEngine(configuration: makeConfiguration())

        XCTAssertTrue(deliver([clientSYN()]))
        let synAck = try XCTUnwrap(waitForWrittenPacket { _, segment in segment.flags.contains(.syn) && segment.flags.contains(.ack) })

        XCTAssertEqual(synAck.0.source, fakeDestination)
        XCTAssertEqual(synAck.0.destination, TestPackets.clientAddress)
        XCTAssertEqual(synAck.1.acknowledgmentNumber, 1001)
        XCTAssertEqual(synAck.1.maximumSegmentSize, 1460)
        XCTAssertEqual(engine.statistics.tcpConnectionsOpened, 1)
    }

    func testFullRoundTripThroughTheProxy() throws {
        socksServer.redirectAllConnectionsTo = (host: "127.0.0.1", port: echoPort)
        startEngine(configuration: makeConfiguration())

        XCTAssertTrue(deliver([clientSYN()]))
        let synAck = try XCTUnwrap(waitForWrittenPacket { _, segment in segment.flags.contains(.syn) && segment.flags.contains(.ack) })

        // Complete the handshake and send a payload.
        let payload = Data("ping through the tunnel".utf8)
        let acknowledgement = TestPackets.tcpPacket(
            destination: fakeDestination,
            sequence: 1001,
            acknowledgment: synAck.1.sequenceNumber &+ 1,
            flags: [.ack, .psh],
            payload: payload
        )
        XCTAssertTrue(deliver([acknowledgement]))

        // The echo server sends the payload back; the engine must turn it into a
        // TCP segment for the client.
        let echoed = try XCTUnwrap(
            waitForWrittenPacket { parsed, segment in
                segment.payload == payload && !segment.flags.contains(.syn)
            },
            "the echoed payload never came back through the tunnel"
        )
        XCTAssertEqual(echoed.1.destinationPort, 49152)
        XCTAssertEqual(echoed.1.sourcePort, 443)
        XCTAssertEqual(socksServer.handshakesCompleted, 1)
        XCTAssertEqual(engine.statistics.tcpBytesToProxy, payload.count)
    }

    func testLoopbackDestinationIsRefusedWithAReset() throws {
        startEngine(configuration: makeConfiguration())
        XCTAssertTrue(deliver([
            clientSYN(destination: IPAddress(presentationName: "127.0.0.1")!, destinationPort: 80)
        ]))

        let reset = try XCTUnwrap(waitForWrittenPacket { _, segment in segment.flags.contains(.rst) })
        XCTAssertEqual(reset.1.flags.contains(.rst), true)
        XCTAssertEqual(engine.statistics.droppedBlockedDestination, 1)
        XCTAssertEqual(engine.statistics.tcpConnectionsOpened, 0)
    }

    func testProxysOwnAddressIsRefusedToAvoidALoop() throws {
        // The destination is the proxy itself. Even though the routes should keep
        // this out of the tunnel, a stale route must not create an infinite loop.
        startEngine(configuration: makeConfiguration())
        XCTAssertTrue(deliver([
            clientSYN(destination: IPAddress(presentationName: "127.0.0.1")!, destinationPort: socksPort)
        ]))
        XCTAssertNotNil(waitForWrittenPacket { _, segment in segment.flags.contains(.rst) })
    }

    func testUnsolicitedDataForAnUnknownFlowGetsAReset() throws {
        startEngine(configuration: makeConfiguration())
        XCTAssertTrue(deliver([
            TestPackets.tcpPacket(
                destination: fakeDestination,
                sequence: 5000,
                flags: [.ack],
                payload: Data("stray".utf8)
            )
        ]))
        XCTAssertNotNil(waitForWrittenPacket { _, segment in segment.flags.contains(.rst) })
    }

    func testFragmentedPacketIsDroppedAndCounted() throws {
        startEngine(configuration: makeConfiguration())

        var packet = clientSYN()
        packet[6] = 0x20   // set MF in the IPv4 flags field
        deliverAndSettle([packet], settleFor: 0.4)

        // Nothing may be written back …
        XCTAssertTrue(flow.snapshot().isEmpty)
        XCTAssertEqual(engine.statistics.droppedFragments, 1)
        XCTAssertEqual(engine.statistics.tcpConnectionsOpened, 0)
    }

    func testMalformedPacketIsDroppedAndCounted() {
        startEngine(configuration: makeConfiguration())
        deliverAndSettle([Data(repeating: 0x00, count: 24)])
        XCTAssertEqual(engine.statistics.droppedMalformedPackets, 1)
    }

    func testICMPIsCountedAsUnsupportedRatherThanSilentlyIgnored() throws {
        startEngine(configuration: makeConfiguration())
        let icmp = ParsedIPPacket.build(
            source: TestPackets.clientAddress,
            destination: fakeDestination,
            protocolNumber: IPProtocolNumber.icmp,
            payload: [8, 0, 0, 0],
            identification: 1
        )
        deliverAndSettle([icmp])
        XCTAssertEqual(engine.statistics.droppedUnsupportedTransport, 1)
    }

    func testUDPIsDroppedWhenRelayingIsDisabled() throws {
        startEngine(configuration: makeConfiguration(relayUDP: false))
        let datagram = UDPDatagram(sourcePort: 5000, destinationPort: 4433, payload: Data([1, 2, 3]))
        let raw = datagram.serialized(source: TestPackets.clientAddress, destination: fakeDestination)
        let packet = ParsedIPPacket.build(
            source: TestPackets.clientAddress,
            destination: fakeDestination,
            protocolNumber: IPProtocolNumber.udp,
            payload: [UInt8](raw),
            identification: 1
        )
        deliverAndSettle([packet])
        XCTAssertEqual(engine.statistics.udpDatagramsDropped, 1)
        XCTAssertEqual(engine.statistics.udpDatagramsRelayed, 0)
    }

    /// DNS inside the tunnel, with no UDP relay available.
    ///
    /// The query is carried as DNS-over-TCP inside a proxied stream, which is what
    /// makes DNS work through an HTTP CONNECT proxy as well as through SOCKS5
    /// without a UDP association.
    func testDNSQueryIsResolvedOverTCPThroughTheProxy() throws {
        socksServer.redirectAllConnectionsTo = (host: "127.0.0.1", port: echoPort)
        startEngine(configuration: makeConfiguration(relayUDP: false, dnsServers: ["198.51.100.53"]))

        // A minimal, syntactically plausible DNS query: transaction id 0xBEEF.
        let query = Data([0xBE, 0xEF, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let datagram = UDPDatagram(sourcePort: 5353, destinationPort: 53, payload: query)
        let dnsServer = IPAddress(presentationName: "198.51.100.53")!
        let raw = datagram.serialized(source: TestPackets.clientAddress, destination: dnsServer)
        let packet = ParsedIPPacket.build(
            source: TestPackets.clientAddress,
            destination: dnsServer,
            protocolNumber: IPProtocolNumber.udp,
            payload: [UInt8](raw),
            identification: 1
        )

        XCTAssertTrue(deliver([packet]))
        let response = try XCTUnwrap(
            waitForWrittenUDPPacket(timeout: 8),
            "the DNS response never came back through the proxy"
        )

        XCTAssertEqual(response.0.source, dnsServer)
        XCTAssertEqual(response.1.sourcePort, 53)
        XCTAssertEqual(response.1.destinationPort, 5353)
        // The echo server replays the length-prefixed frame verbatim, so the
        // payload must round-trip exactly.
        XCTAssertEqual(response.1.payload, query)
        XCTAssertEqual(engine.statistics.dnsQueriesHandled, 1)
        XCTAssertEqual(engine.statistics.dnsQueriesFailed, 0)
    }

    func testStatisticsReflectWhatActuallyHappened() throws {
        socksServer.redirectAllConnectionsTo = (host: "127.0.0.1", port: echoPort)
        startEngine(configuration: makeConfiguration())
        XCTAssertTrue(deliver([clientSYN()]))
        _ = try XCTUnwrap(waitForWrittenPacket { _, segment in segment.flags.contains(.syn) })

        let payload = engine.makeStatusPayload()
        XCTAssertEqual(payload.engineState, "running")
        XCTAssertEqual(payload.statistics.tcpConnectionsOpened, 1)
        XCTAssertEqual(payload.statistics.tcpActiveConnections, 1)
        XCTAssertGreaterThan(payload.statistics.packetsFromTunnel, 0)
        XCTAssertGreaterThan(payload.statistics.packetsToTunnel, 0)
        XCTAssertFalse(payload.networkSettingsApplied, "the engine reports what the provider told it, and the test provider has not applied settings")
    }

    func testStatusPayloadNeverLeaksTheCredential() {
        startEngine(
            configuration: makeConfiguration(credential: ProxyCredential(username: "example-user", password: "example-password")),
            credential: ProxyCredential(username: "example-user", password: "example-password")
        )
        let payload = engine.makeStatusPayload()
        let encoded = try? JSONEncoder().encode(payload)
        let json = encoded.map { String(decoding: $0, as: UTF8.self) } ?? ""
        XCTAssertFalse(json.contains("example-password"))
        XCTAssertFalse(json.contains("example-user"))
        XCTAssertTrue(payload.configurationSummary?.contains("credential=inlineProviderConfiguration") ?? false)
    }

    func testStopClosesEverything() {
        startEngine(configuration: makeConfiguration())
        XCTAssertTrue(deliver([clientSYN()]))
        _ = flow.waitForPendingRead(timeout: 1)
        engine.stop(reason: "test")
        XCTAssertEqual(engine.state, .stopped)
        XCTAssertEqual(engine.statistics.tcpActiveConnections, 0)
    }

    func testEngineRefusesToOpenMoreConnectionsThanTheLimit() throws {
        socksServer.redirectAllConnectionsTo = (host: "127.0.0.1", port: echoPort)
        var limits = TunnelEngine.Limits()
        limits.maximumTCPConnections = 2
        engine = TunnelEngine(
            dependencies: .init(
                configuration: makeConfiguration(),
                credential: nil,
                packetFlow: flow,
                queue: engineQueue,
                log: DiagnosticLog(subsystem: "test", capacity: 64)
            ),
            limits: limits
        )
        engine.start()

        // Three SYNs on three different client ports.
        var packets: [Data] = []
        for offset in 0..<3 {
            packets.append(TestPackets.tcpPacket(
                destination: fakeDestination,
                sourcePort: UInt16(40000 + offset),
                destinationPort: 443,
                sequence: 1000,
                flags: [.syn],
                options: TestPackets.synOptions
            ))
        }
        XCTAssertTrue(deliver(packets))
        _ = flow.waitForPendingRead(timeout: 1)
        settle(0.6)

        XCTAssertEqual(engine.statistics.tcpConnectionsOpened, 2)
        XCTAssertEqual(engine.statistics.tcpConnectionsRejected, 1)
    }

    // MARK: Network settings

    func testNetworkSettingsFactoryInstallsTheDefaultRouteAndExcludesTheProxy() {
        let configuration = makeConfiguration()
        let built = TunnelNetworkSettingsFactory.make(configuration: configuration)

        XCTAssertEqual(built.ipv4IncludedRoutes, ["0.0.0.0/0"])
        XCTAssertEqual(built.ipv4ExcludedRoutes, ["127.0.0.1/32"])
        XCTAssertEqual(built.ipv6IncludedRoutes, ["::/0"])
        XCTAssertEqual(built.dnsServers, ["198.51.100.53"])
        XCTAssertEqual(built.mtu, TunnelNetworkDefaults.mtu)
        XCTAssertEqual(built.ipv4Address, TunnelNetworkDefaults.ipv4Address)
        XCTAssertEqual(built.ipv6Address, TunnelNetworkDefaults.ipv6Address)
        XCTAssertEqual(built.tunnelRemoteAddress, "127.0.0.1")
        XCTAssertTrue(built.warnings.isEmpty, built.warnings.joined(separator: "; "))

        // And the NetworkExtension objects were actually configured, not just
        // described. `includedRoutes`/`excludedRoutes` are optional in the Swift
        // API even though the header does not mark them nullable, so they are
        // unwrapped with a default rather than force-unwrapped.
        guard let ipv4 = built.settings.ipv4Settings else {
            return XCTFail("no IPv4 settings were produced")
        }
        XCTAssertEqual(ipv4.includedRoutes?.count ?? 0, 1)
        XCTAssertEqual(ipv4.excludedRoutes?.count ?? 0, 1)

        guard let ipv6 = built.settings.ipv6Settings else {
            return XCTFail("no IPv6 settings were produced")
        }
        XCTAssertEqual(ipv6.includedRoutes?.count ?? 0, 1)

        XCTAssertEqual(built.settings.dnsSettings?.servers, ["198.51.100.53"])
        XCTAssertEqual(built.settings.dnsSettings?.matchDomains, [""])
        XCTAssertEqual(built.settings.mtu, NSNumber(value: TunnelNetworkDefaults.mtu))
    }

    func testIPv6CanBeTurnedOffAndSaysSo() {
        let built = TunnelNetworkSettingsFactory.make(configuration: makeConfiguration(allowIPv6: false))
        XCTAssertNil(built.settings.ipv6Settings)
        XCTAssertNil(built.ipv6Address)
        XCTAssertTrue(built.warnings.contains { $0.contains("IPv6 is disabled") })
    }

    func testSubnetMaskConversion() {
        XCTAssertEqual(TunnelNetworkSettingsFactory.subnetMask(prefixLength: 0), "0.0.0.0")
        XCTAssertEqual(TunnelNetworkSettingsFactory.subnetMask(prefixLength: 8), "255.0.0.0")
        XCTAssertEqual(TunnelNetworkSettingsFactory.subnetMask(prefixLength: 24), "255.255.255.0")
        XCTAssertEqual(TunnelNetworkSettingsFactory.subnetMask(prefixLength: 32), "255.255.255.255")
    }

    func testDescribeMentionsEveryRoutingDecision() {
        let built = TunnelNetworkSettingsFactory.make(configuration: makeConfiguration())
        let lines = TunnelNetworkSettingsFactory.describe(built).joined(separator: "\n")
        XCTAssertTrue(lines.contains("IPv4 included routes"))
        XCTAssertTrue(lines.contains("IPv4 excluded routes"))
        XCTAssertTrue(lines.contains("DNS servers"))
    }
}
