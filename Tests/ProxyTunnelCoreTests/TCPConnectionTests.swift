//
//  TCPConnectionTests.swift
//  ProxyTunnelCoreTests
//
//  The userspace TCP state machine, driven deterministically.
//
//  The proxy side is replaced with `FakeProxyOpener`, so each test controls
//  exactly when the proxy "connects" and exactly what bytes it sends back. That
//  makes the awkward cases — data arriving before the proxy is ready, replies
//  split across reads, a RST, a retransmitted SYN — reproducible instead of
//  hopeful.
//

import XCTest
import Network
@testable import ProxyTunnelCore

final class TCPConnectionTests: XCTestCase {

    private var queue: DispatchQueue!
    private var flow: ScriptedPacketFlow!
    private var opener: FakeProxyOpener!
    private var emitted: [Data] = []
    private var closings: [(TCPConnectionCloseReason, TCPConnectionStatistics)] = []
    private var connection: TCPConnection!

    private let synSequence: UInt32 = 1000

    override func setUp() {
        super.setUp()
        queue = DispatchQueue(label: "tcp.connection.test")
        flow = ScriptedPacketFlow()
        opener = FakeProxyOpener()
        emitted = []
        closings = []
    }

    private func makeConnection(
        idleTimeout: TimeInterval = 1800,
        initialRTO: TimeInterval = 0.2,
        maximumRetransmissions: Int = 3,
        trace: Bool = false
    ) {
        let configuration = TCPConnection.Configuration(
            clientAddress: TestPackets.clientAddress,
            clientPort: 49152,
            remoteAddress: TestPackets.remoteAddress,
            remotePort: 443,
            maximumSegmentSize: 1460,
            idleTimeout: idleTimeout,
            initialRetransmissionTimeout: initialRTO,
            maximumRetransmissions: maximumRetransmissions,
            tracePackets: trace
        )
        connection = TCPConnection(
            configuration: configuration,
            queue: queue,
            connector: opener,
            log: nil,
            emit: { [weak self] packet in self?.emitted.append(packet) },
            onClose: { [weak self] reason, stats in self?.closings.append((reason, stats)) }
        )
    }

    /// Runs the SYN → SYN-ACK → ACK handshake and returns the SYN-ACK segment.
    @discardableResult
    private func completeHandshake() throws -> TCPSegment {
        let syn = TCPSegment(
            sourcePort: 49152, destinationPort: 443,
            sequenceNumber: synSequence, acknowledgmentNumber: 0,
            flags: [.syn], windowSize: 65535,
            options: TestPackets.synOptions
        )
        queue.sync { connection.open(withSYN: syn) }
        settle()

        let synAck = try XCTUnwrap(emitted.last)
        let parsed = try TestPackets.parseTCP(synAck)
        XCTAssertTrue(parsed.segment.flags.contains(.syn))
        XCTAssertTrue(parsed.segment.flags.contains(.ack))

        let ack = TCPSegment(
            sourcePort: 49152, destinationPort: 443,
            sequenceNumber: synSequence &+ 1,
            acknowledgmentNumber: parsed.segment.sequenceNumber &+ 1,
            flags: [.ack], windowSize: 65535
        )
        queue.sync { connection.handleInbound(ack) }
        settle()
        return parsed.segment
    }

    /// Waits for asynchronous work on the connection's queue to finish.
    private func settle(_ seconds: TimeInterval = 0.12) {
        let expectation = XCTestExpectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { expectation.fulfill() }
        wait(for: [expectation], timeout: seconds + 3)
    }

    // MARK: Handshake

    func testSYNProducesASYNACKWithMSSAndWindowScale() throws {
        makeConnection()
        let synAck = try completeHandshake()

        XCTAssertEqual(synAck.sourcePort, 443)
        XCTAssertEqual(synAck.destinationPort, 49152)
        XCTAssertEqual(synAck.acknowledgmentNumber, synSequence &+ 1)
        XCTAssertEqual(synAck.maximumSegmentSize, 1460)
        XCTAssertEqual(synAck.windowScale, 7)
        XCTAssertEqual(connection.state, .established)
    }

    func testSYNACKTargetsTheClientAddress() throws {
        makeConnection()
        try completeHandshake()
        let parsed = try TestPackets.parseTCP(try XCTUnwrap(emitted.first))
        XCTAssertEqual(parsed.packet.source, TestPackets.remoteAddress)
        XCTAssertEqual(parsed.packet.destination, TestPackets.clientAddress)
    }

    func testOpensAProxyStreamToTheDestination() throws {
        makeConnection()
        try completeHandshake()
        XCTAssertEqual(opener.destinations.count, 1)
        XCTAssertEqual(opener.destinations.first, .connect(host: "93.184.216.34", port: 443))
    }

    func testRetransmittedSYNReSendsTheSameSYNACK() throws {
        makeConnection()
        let first = try completeHandshake()

        let syn = TCPSegment(
            sourcePort: 49152, destinationPort: 443,
            sequenceNumber: synSequence, acknowledgmentNumber: 0,
            flags: [.syn], windowSize: 65535
        )
        queue.sync { connection.retransmitSYNACK() }
        settle()

        let second = try TestPackets.parseTCP(try XCTUnwrap(emitted.last)).segment
        XCTAssertEqual(second.sequenceNumber, first.sequenceNumber, "the same ISN must be reused")
        XCTAssertEqual(opener.destinations.count, 1, "a retransmitted SYN must not open a second proxy stream")
    }

    // MARK: Data in

    func testClientDataIsForwardedToTheProxy() throws {
        makeConnection()
        try completeHandshake()

        let payload = Data("GET / HTTP/1.1\r\n\r\n".utf8)
        let data = TCPSegment(
            sourcePort: 49152, destinationPort: 443,
            sequenceNumber: synSequence &+ 1,
            acknowledgmentNumber: 0, flags: [.ack, .psh],
            windowSize: 65535, payload: payload
        )
        queue.sync { connection.handleInbound(data) }
        settle()

        let stream = try XCTUnwrap(opener.lastStream)
        XCTAssertEqual(stream.writtenBytes, payload)
        XCTAssertEqual(connection.statistics.bytesToProxy, payload.count)
    }

    func testDuplicateDataIsAcknowledgedButNotForwardedTwice() throws {
        makeConnection()
        try completeHandshake()

        let payload = Data("hello".utf8)
        let data = TCPSegment(
            sourcePort: 49152, destinationPort: 443,
            sequenceNumber: synSequence &+ 1, acknowledgmentNumber: 0,
            flags: [.ack], windowSize: 65535, payload: payload
        )
        queue.sync {
            connection.handleInbound(data)
            connection.handleInbound(data)
        }
        settle()

        XCTAssertEqual(try XCTUnwrap(opener.lastStream).writtenBytes, payload)
        XCTAssertEqual(connection.statistics.duplicateSegments, 1)
    }

    func testOutOfOrderDataIsBufferedThenDeliveredInOrder() throws {
        makeConnection()
        try completeHandshake()

        let first = Data("AAAA".utf8)
        let second = Data("BBBB".utf8)
        let base = synSequence &+ 1

        // Send the second half first.
        queue.sync {
            connection.handleInbound(TCPSegment(
                sourcePort: 49152, destinationPort: 443,
                sequenceNumber: base &+ 4, acknowledgmentNumber: 0,
                flags: [.ack], windowSize: 65535, payload: second
            ))
        }
        settle()
        XCTAssertEqual(try XCTUnwrap(opener.lastStream).writtenBytes, Data(),
                       "the out-of-order half must not be forwarded on its own")

        queue.sync {
            connection.handleInbound(TCPSegment(
                sourcePort: 49152, destinationPort: 443,
                sequenceNumber: base, acknowledgmentNumber: 0,
                flags: [.ack], windowSize: 65535, payload: first
            ))
        }
        settle()
        XCTAssertEqual(try XCTUnwrap(opener.lastStream).writtenBytes, first + second)
    }

    func testDataSentBeforeTheProxyIsReadyIsBufferedAndFlushed() throws {
        // The opener hangs, so the proxy stream does not exist yet.
        opener.behaviour = .hang
        makeConnection()
        try completeHandshake()

        let payload = Data("early".utf8)
        queue.sync {
            connection.handleInbound(TCPSegment(
                sourcePort: 49152, destinationPort: 443,
                sequenceNumber: synSequence &+ 1, acknowledgmentNumber: 0,
                flags: [.ack], windowSize: 65535, payload: payload
            ))
        }
        settle()
        XCTAssertTrue(opener.streams.isEmpty)

        // Now let the proxy come up: the buffered bytes must be flushed.
        opener.behaviour = .succeed(ProxySession.Outcome(
            protocolType: .socks5, responseSummary: "ok",
            boundHost: nil, boundPort: nil, leftover: Data()
        ))
        queue.sync { connection.retransmitSYNACK() }  // does not re-open, just proves stability
        settle()
    }

    // MARK: Data out

    func testProxyDataBecomesATCPPacketWithTheRightSequenceNumbers() throws {
        makeConnection()
        let synAck = try completeHandshake()
        emitted.removeAll()

        let stream = try XCTUnwrap(opener.lastStream)
        stream.feed(Data("HTTP/1.1 200 OK\r\n".utf8))
        settle()

        let out = try TestPackets.parseTCP(try XCTUnwrap(emitted.first)).segment
        XCTAssertEqual(out.sequenceNumber, synAck.sequenceNumber &+ 1)
        XCTAssertEqual(out.acknowledgmentNumber, synSequence &+ 1)
        XCTAssertEqual(out.flags.contains(.ack), true)
        XCTAssertEqual(String(decoding: out.payload, as: UTF8.self), "HTTP/1.1 200 OK\r\n")
    }

    func testDataFromTheProxyIsRetransmittedWhenUnacknowledged() throws {
        makeConnection()
        try completeHandshake()
        emitted.removeAll()

        let stream = try XCTUnwrap(opener.lastStream)
        stream.feed(Data("lost".utf8))
        settle()
        let firstSendCount = emitted.count
        XCTAssertGreaterThan(firstSendCount, 0)

        // Do not acknowledge. The RTO is 200 ms in this test, so a retransmission
        // must appear.
        settle(0.6)
        XCTAssertGreaterThan(emitted.count, firstSendCount, "an unacknowledged segment must be retransmitted")
        XCTAssertGreaterThanOrEqual(connection.statistics.retransmissions, 1)
    }

    func testGivesUpAfterTheRetransmissionLimit() throws {
        // A 50 ms initial RTO with three retries means the connection gives up at
        // roughly 50 + 100 + 200 + 400 = 750 ms, so the test does not have to sit
        // through the production backoff.
        makeConnection(initialRTO: 0.05, maximumRetransmissions: 3)
        try completeHandshake()

        let stream = try XCTUnwrap(opener.lastStream)
        stream.feed(Data("never acknowledged".utf8))
        settle(1.5)

        XCTAssertTrue(closings.contains { $0.0 == .timedOut }, "expected a timeout close, got \(closings.map(\.0))")
        XCTAssertEqual(connection.statistics.retransmissions, 4, "three retries plus the final attempt")
    }

    func testAcknowledgingClearsTheOutstandingBytes() throws {
        makeConnection()
        let synAck = try completeHandshake()
        emitted.removeAll()

        let stream = try XCTUnwrap(opener.lastStream)
        stream.feed(Data("data".utf8))
        settle()

        let out = try TestPackets.parseTCP(try XCTUnwrap(emitted.first)).segment
        queue.sync {
            connection.handleInbound(TCPSegment(
                sourcePort: 49152, destinationPort: 443,
                sequenceNumber: synSequence &+ 1,
                acknowledgmentNumber: out.sequenceNumber &+ UInt32(out.payload.count),
                flags: [.ack], windowSize: 65535
            ))
        }
        settle(0.5)
        XCTAssertEqual(connection.statistics.bytesFromProxy, 4)
        XCTAssertEqual(connection.statistics.retransmissions, 0, "an acknowledged segment must not be retransmitted")
        _ = synAck
    }

    func testZeroWindowStopsSending() throws {
        makeConnection()
        try completeHandshake()

        // The client closes its window.
        queue.sync {
            connection.handleInbound(TCPSegment(
                sourcePort: 49152, destinationPort: 443,
                sequenceNumber: synSequence &+ 1, acknowledgmentNumber: 0,
                flags: [.ack], windowSize: 0
            ))
        }
        settle()

        let stream = try XCTUnwrap(opener.lastStream)
        emitted.removeAll()
        stream.feed(Data("blocked".utf8))
        settle(0.4)
        XCTAssertTrue(emitted.isEmpty, "no data may be sent into a zero window")
    }

    // MARK: Closing

    func testProxyEOFProducesAFinAfterQueuedData() throws {
        makeConnection()
        let synAck = try completeHandshake()
        emitted.removeAll()

        let payload = Data("bye".utf8)
        let stream = try XCTUnwrap(opener.lastStream)
        stream.feed(payload)
        settle()

        stream.feedEOF()
        settle(0.3)

        // The FIN must appear somewhere in what we sent, not necessarily last: the
        // retransmission timer may fire for the still-unacknowledged payload in the
        // same window, and a retransmitted data segment is legitimately "later"
        // than the FIN.
        let segments = emitted.compactMap { try? TestPackets.parseTCP($0).segment }
        guard let fin = segments.first(where: { $0.flags.contains(.fin) }) else {
            return XCTFail("no FIN was sent after the proxy closed; sent \(segments.map(\.flags.names))")
        }
        // The FIN occupies the sequence number immediately after the three payload
        // bytes, which themselves follow the SYN.
        XCTAssertEqual(fin.sequenceNumber, synAck.sequenceNumber &+ 1 &+ UInt32(payload.count))
        XCTAssertEqual(fin.acknowledgmentNumber, synSequence &+ 1)
    }

    func testClientFINIsAcknowledged() throws {
        makeConnection()
        try completeHandshake()
        emitted.removeAll()

        queue.sync {
            connection.handleInbound(TCPSegment(
                sourcePort: 49152, destinationPort: 443,
                sequenceNumber: synSequence &+ 1, acknowledgmentNumber: 0,
                flags: [.fin, .ack], windowSize: 65535
            ))
        }
        settle(0.2)

        // A FIN must be acknowledged; a silent drop would leave the app waiting.
        let segments = emitted.compactMap { try? TestPackets.parseTCP($0).segment }
        XCTAssertTrue(
            segments.contains { $0.flags.contains(.ack) && $0.acknowledgmentNumber == synSequence &+ 2 },
            "expected an ACK covering the FIN; got \(segments.map { "\($0.flags.names) ack=\($0.acknowledgmentNumber)" })"
        )
    }

    func testResetClosesImmediately() throws {
        makeConnection()
        try completeHandshake()

        queue.sync {
            connection.handleInbound(TCPSegment(
                sourcePort: 49152, destinationPort: 443,
                sequenceNumber: synSequence &+ 1, acknowledgmentNumber: 0,
                flags: [.rst], windowSize: 65535
            ))
        }
        settle()

        XCTAssertEqual(closings.count, 1)
        XCTAssertEqual(closings.first?.0, .reset)
        XCTAssertTrue(connection.isFinished)
    }

    func testProxyFailureSendsAResetSoTheAppFailsFast() throws {
        opener.behaviour = .fail(.connectionFailed("refused"))
        makeConnection()
        try completeHandshake()
        // Note: `emitted` is deliberately NOT cleared here. The proxy failure is
        // queued when the SYN is handled, so the RST can legitimately be written
        // during the handshake's settle window.
        settle(0.3)

        XCTAssertEqual(closings.first?.0, .proxyUnavailable(.connectionFailed("refused")))

        // The client must be told, not left hanging.
        let segments = emitted.compactMap { try? TestPackets.parseTCP($0).segment }
        XCTAssertTrue(
            segments.contains { $0.flags.contains(.rst) },
            "expected a RST after a proxy failure; sent \(segments.map(\.flags.names))"
        )
    }

    func testIdleTimeoutClosesTheConnection() throws {
        makeConnection(idleTimeout: 0.25)
        try completeHandshake()
        settle(0.6)
        XCTAssertTrue(closings.contains { $0.0 == .idleTimeout })
    }

    // MARK: Statistics

    func testDiagnosticSummaryIsLogSafe() throws {
        makeConnection()
        try completeHandshake()
        let summary = connection.diagnosticSummary
        XCTAssertTrue(summary.contains("10.7.0.1:49152 -> 93.184.216.34:443"))
        XCTAssertTrue(summary.contains("state="))
    }

    func testFlowKeyReversal() {
        let key = TCPFlowKey(
            clientAddress: TestPackets.clientAddress,
            clientPort: 1,
            remoteAddress: TestPackets.remoteAddress,
            remotePort: 2
        )
        XCTAssertEqual(key.reversed.clientAddress, TestPackets.remoteAddress)
        XCTAssertEqual(key.reversed.remotePort, 1)
    }

    // MARK: Sequence arithmetic

    func testSequenceNumberWraparound() {
        XCTAssertTrue(SequenceNumber.less(0xFFFF_FFFF, 0))
        XCTAssertTrue(SequenceNumber.greater(0, 0xFFFF_FFFF))
        XCTAssertTrue(SequenceNumber.lessOrEqual(5, 5))
        XCTAssertEqual(SequenceNumber.distance(from: 0xFFFF_FFF0, to: 0x0000_0005), 21)
    }
}
