//
//  TCPConnection.swift
//  ProxyTunnelCore
//
//  A userspace TCP endpoint.
//
//  ── Why this exists ──────────────────────────────────────────────────────────
//  A `NEPacketTunnelProvider` is handed *IP packets*, not sockets. To forward
//  those packets through a SOCKS5 or HTTP CONNECT proxy — both of which only
//  carry TCP streams — the tunnel has to terminate TCP itself: answer the SYN,
//  acknowledge data, reassemble the byte stream, and put it on a proxy
//  connection; then take bytes coming back and synthesise TCP segments for the
//  app.
//
//  This class implements the client half of that TCP state machine for the
//  subset a proxy tunnel needs:
//
//    * passive open from the app's point of view (we answer the SYN)
//    * one proxy stream per TCP connection, opened on demand
//    * receive-side reassembly with a bounded out-of-order queue
//    * send-side segmentation honouring the peer's advertised window
//    * a single retransmission timer with exponential backoff (RFC 6298 style)
//    * fast retransmit on three duplicate acknowledgements
//    * zero-window persist probes
//    * graceful FIN/FIN-ACK close in both directions, with a linger
//
//  It deliberately does *not* implement: congestion control (the tun interface
//  is not a bottleneck, and the proxy link has its own), SACK, timestamps, path
//  MTU discovery, or TCP options other than MSS and window scale. Those
//  omissions are listed in docs/PROXY-PROTOCOLS.md.
//
//  ── Threading ────────────────────────────────────────────────────────────────
//  Every field is confined to `queue`. Nothing in this class takes a lock, and
//  nothing calls into it from another thread. `emit` and `onClose` are always
//  invoked on `queue`.
//

import Foundation

/// Uniquely identifies one TCP connection inside the tunnel.
public struct TCPFlowKey: Hashable, Sendable {
    /// The address the app used as its source (i.e. our tunnel address).
    public let clientAddress: IPAddress
    public let clientPort: UInt16
    /// The real destination the app is trying to reach.
    public let remoteAddress: IPAddress
    public let remotePort: UInt16

    public init(clientAddress: IPAddress, clientPort: UInt16, remoteAddress: IPAddress, remotePort: UInt16) {
        self.clientAddress = clientAddress
        self.clientPort = clientPort
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
    }

    /// The reverse key, used to recognise the segments we generate.
    public var reversed: TCPFlowKey {
        TCPFlowKey(
            clientAddress: remoteAddress,
            clientPort: remotePort,
            remoteAddress: clientAddress,
            remotePort: clientPort
        )
    }

    public var description: String {
        "\(clientAddress.description):\(clientPort) -> \(remoteAddress.description):\(remotePort)"
    }
}

/// Why a TCP connection went away. Used for statistics and diagnostics.
public enum TCPConnectionCloseReason: Equatable, Sendable {
    case clientClosed            // normal: both sides sent FIN
    case reset                   // RST from the app
    case proxyUnavailable(ProxyError)
    case proxyClosed             // the proxy or origin closed first
    case timedOut                // too many retransmissions
    case idleTimeout
    case rejected(String)        // engine refused to create the connection

    public var description: String {
        switch self {
        case .clientClosed:                 return "closed by the app"
        case .reset:                        return "reset by the app"
        case .proxyUnavailable(let error):  return "proxy error: \(error.diagnosticDescription)"
        case .proxyClosed:                  return "closed by the proxy/origin"
        case .timedOut:                     return "timed out"
        case .idleTimeout:                  return "idle timeout"
        case .rejected(let why):            return "rejected: \(why)"
        }
    }
}

public struct TCPConnectionStatistics: Equatable, Sendable {
    public var bytesToProxy: Int = 0
    public var bytesFromProxy: Int = 0
    public var segmentsIn: Int = 0
    public var segmentsOut: Int = 0
    public var retransmissions: Int = 0
    public var outOfOrderSegments: Int = 0
    public var duplicateSegments: Int = 0
}

/// Opens proxy streams. Implemented by `TunnelEngine`, which knows the endpoint,
/// the resolved addresses and the physical interface to bind to.
public protocol ProxyStreamOpening: AnyObject {
    func openProxyStream(
        to destination: ProxyDestination,
        queue: DispatchQueue,
        completion: @escaping (Result<ProxyConnection, ProxyError>) -> Void
    )
}

public final class TCPConnection {

    public struct Configuration {
        /// Our tunnel-side address (the source address the app used).
        public let clientAddress: IPAddress
        public let clientPort: UInt16
        public let remoteAddress: IPAddress
        public let remotePort: UInt16

        /// MSS we advertise to the app.
        public let maximumSegmentSize: Int
        /// How many bytes of app data we are willing to hold before forwarding.
        public let receiveBufferBytes: Int
        /// Window-scale shift we advertise (RFC 7323). 7 gives a 8 MiB window.
        public let receiveWindowScale: Int
        /// Maximum bytes of data waiting for the app's window.
        public let sendBufferBytes: Int
        /// Give up after this long with no packets at all in either direction.
        public let idleTimeout: TimeInterval
        /// How long to keep reading from the proxy after the app sent FIN.
        ///
        /// Needed because neither SOCKS5 nor HTTP CONNECT can carry a half-close:
        /// there is no way to tell the origin "the client is done writing" other
        /// than by closing the whole stream. We therefore keep the stream open and
        /// wait for the origin to finish, bounded by this timeout.
        public let halfCloseGraceTimeout: TimeInterval
        public let initialRetransmissionTimeout: TimeInterval
        public let maximumRetransmissions: Int
        /// Record a line per packet in the diagnostic log. Very noisy; off by
        /// default and only enabled from Diagnostics.
        public let tracePackets: Bool

        public init(
            clientAddress: IPAddress,
            clientPort: UInt16,
            remoteAddress: IPAddress,
            remotePort: UInt16,
            maximumSegmentSize: Int,
            receiveBufferBytes: Int = 256 * 1024,
            receiveWindowScale: Int = 7,
            sendBufferBytes: Int = 512 * 1024,
            idleTimeout: TimeInterval = 1800,
            halfCloseGraceTimeout: TimeInterval = 120,
            initialRetransmissionTimeout: TimeInterval = 1.0,
            maximumRetransmissions: Int = 7,
            tracePackets: Bool = false
        ) {
            self.clientAddress = clientAddress
            self.clientPort = clientPort
            self.remoteAddress = remoteAddress
            self.remotePort = remotePort
            self.maximumSegmentSize = maximumSegmentSize
            self.receiveBufferBytes = receiveBufferBytes
            self.receiveWindowScale = receiveWindowScale
            self.sendBufferBytes = sendBufferBytes
            self.idleTimeout = idleTimeout
            self.halfCloseGraceTimeout = halfCloseGraceTimeout
            self.initialRetransmissionTimeout = initialRetransmissionTimeout
            self.maximumRetransmissions = maximumRetransmissions
            self.tracePackets = tracePackets
        }
    }

    public enum State: String, Sendable {
        case synReceived
        case established
        case finWait1
        case finWait2
        case closing
        case lastAck
        case timeWait
        case closed
    }

    // MARK: Stored properties

    public let key: TCPFlowKey
    public let configuration: Configuration
    private let queue: DispatchQueue
    /// Held weakly: the engine owns the connection, so a strong reference back
    /// would be a cycle that only breaks when the connection closes.
    private weak var connector: ProxyStreamOpening?
    private let log: DiagnosticLog?
    private let emit: (Data) -> Void
    private let onClose: (TCPConnectionCloseReason, TCPConnectionStatistics) -> Void

    public private(set) var state: State = .synReceived
    public private(set) var statistics = TCPConnectionStatistics()
    public private(set) var createdAt = Date()
    public private(set) var lastActivityAt = Date()

    /// Our initial send sequence number.
    private var isn: UInt32 = 0
    private var sndUna: UInt32 = 0        // oldest unacknowledged sequence number
    private var sndNxt: UInt32 = 0        // next sequence number to use
    private var sndWnd: Int = 0           // peer's advertised window, already scaled
    private var sndWndField: UInt16 = 0   // raw field, for zero-window handling

    private var irs: UInt32 = 0           // the app's initial sequence number
    private var rcvNxt: UInt32 = 0        // next sequence number we expect from the app
    private var peerWindowScale: Int = 0
    private var peerMaximumSegmentSize: Int = 536

    private var appFinReceived = false
    private var appFinSequence: UInt32?
    private var pendingAppFinSequence: UInt32?
    private var weSentFin = false
    private var ourFinSequence: UInt32?
    private var proxyReachedEOF = false

    private struct OutstandingSegment {
        var sequence: UInt32
        var data: Data
    }
    private var unacked: [OutstandingSegment] = []
    private var unackedBytes: Int = 0

    private var outOfOrder: [UInt32: Data] = [:]
    private var outOfOrderBytes: Int = 0

    /// Bytes coming *from* the proxy, waiting for room in the app's window.
    private var toAppQueue: [Data] = []
    private var toAppBytes: Int = 0
    private var toAppOffset: Int = 0

    /// Bytes coming *from* the app, waiting to be written to the proxy.
    private var toProxyQueue: [Data] = []
    private var toProxyBytes: Int = 0
    private var isWritingToProxy = false

    private var proxyConnection: ProxyConnection?
    private var isOpeningProxy = false
    private var proxyReadOutstanding = false
    private var proxyStreamClosed = false

    private var retransmissionTimer: DispatchWorkItem?
    private var idleTimer: DispatchWorkItem?
    private var persistTimer: DispatchWorkItem?
    private var lingerTimer: DispatchWorkItem?
    private var halfCloseTimer: DispatchWorkItem?

    private var currentRTO: TimeInterval
    private var retransmissionCount = 0
    private var duplicateAckCount = 0
    private var isClosed = false
    private var nextIdentification: UInt16 = UInt16.random(in: 1...60000)

    // MARK: Init

    public init(
        configuration: Configuration,
        queue: DispatchQueue,
        connector: ProxyStreamOpening,
        log: DiagnosticLog?,
        emit: @escaping (Data) -> Void,
        onClose: @escaping (TCPConnectionCloseReason, TCPConnectionStatistics) -> Void
    ) {
        self.configuration = configuration
        self.queue = queue
        self.connector = connector
        self.log = log
        self.emit = emit
        self.onClose = onClose

        self.key = TCPFlowKey(
            clientAddress: configuration.clientAddress,
            clientPort: configuration.clientPort,
            remoteAddress: configuration.remoteAddress,
            remotePort: configuration.remotePort
        )
        self.currentRTO = configuration.initialRetransmissionTimeout
    }

    // MARK: - Opening

    /// Handles the SYN that creates this connection. Must be called on `queue`.
    ///
    /// - Parameter segment: the SYN segment from the app.
    public func open(withSYN segment: TCPSegment) {
        guard !isClosed else { return }

        irs = segment.sequenceNumber
        rcvNxt = segment.sequenceNumber &+ 1
        peerWindowScale = min(segment.windowScale ?? 0, 14)
        peerMaximumSegmentSize = max(536, min(segment.maximumSegmentSize ?? 536, 65495))
        sndWndField = segment.windowSize
        sndWnd = Int(segment.windowSize) << peerWindowScale

        // RFC 6528: the ISN should be unpredictable. We mix a per-connection
        // random value with the clock; this is not a cryptographic guarantee and
        // is documented as such, but it is far better than a counter.
        isn = UInt32.random(in: 0...UInt32.max)
        sndUna = isn
        sndNxt = isn &+ 1
        state = .synReceived

        statistics.segmentsIn += 1
        tracePacket("in", segment)

        sendSYNACK()
        beginProxyConnection()
        armIdleTimer()
    }

    private func sendSYNACK() {
        var options: [UInt8] = []
        // MSS (kind 2, len 4)
        let mss = UInt16(clamping: configuration.maximumSegmentSize)
        options.append(contentsOf: [2, 4, UInt8((mss >> 8) & 0xFF), UInt8(mss & 0xFF)])
        // Window scale (kind 3, len 3)
        options.append(contentsOf: [3, 3, UInt8(clamping: configuration.receiveWindowScale)])

        let segment = TCPSegment(
            sourcePort: key.remotePort,
            destinationPort: key.clientPort,
            sequenceNumber: isn,
            acknowledgmentNumber: rcvNxt,
            flags: [.syn, .ack],
            windowSize: advertisedWindowField(),
            options: options
        )
        transmit(segment)
    }

    // MARK: - Inbound from the app

    /// Feeds one TCP segment that came out of the tunnel interface.
    /// Must be called on `queue`.
    public func handleInbound(_ segment: TCPSegment) {
        guard !isClosed else { return }
        lastActivityAt = Date()
        statistics.segmentsIn += 1
        tracePacket("in", segment)
        armIdleTimer()

        // RST always wins.
        if segment.hasRST {
            log?.debug("tcp", "\(key.description) RST from app")
            close(.reset)
            return
        }

        guard segment.hasACK else {
            // Everything after the SYN must carry an ACK. Silently ignore
            // anything else rather than escalating.
            return
        }

        // ---- ACK processing (always before data, per RFC 9293 §3.10.7.4) ----
        processAcknowledgment(segment)

        // ---- data and FIN --------------------------------------------------
        if !segment.payload.isEmpty {
            processInboundPayload(segment)
        }

        if segment.hasFIN {
            let finSequence = segment.sequenceNumber
                &+ (segment.hasSYN ? 1 : 0)
                &+ UInt32(segment.payload.count)
            processInboundFIN(finSequence)
        }

        if !segment.payload.isEmpty || segment.hasFIN {
            sendAcknowledgment()
        }

        evaluateClose()
    }

    /// Re-sends the SYN-ACK when the app retransmits its SYN (which happens when
    /// our first SYN-ACK or the app's ACK was lost).
    public func retransmitSYNACK() {
        guard !isClosed, !weSentFin else { return }
        sendSYNACK()
    }

    private func processInboundPayload(_ segment: TCPSegment) {
        var sequence = segment.payloadSequenceNumber
        var payload = segment.payload

        // Trim anything we have already accepted.
        if SequenceNumber.less(sequence, rcvNxt) {
            let overlap = SequenceNumber.distance(from: sequence, to: rcvNxt)
            if overlap >= payload.count {
                statistics.duplicateSegments += 1
                return
            }
            payload = Data(payload.dropFirst(overlap))
            sequence = rcvNxt
        }

        if sequence == rcvNxt {
            enqueueToProxy(payload)
            rcvNxt &+= UInt32(payload.count)
            drainOutOfOrderQueue()
        } else {
            // Future data. Buffer a bounded amount so normal reordering (rare on a
            // tun interface, but possible) is handled without a retransmission.
            statistics.outOfOrderSegments += 1
            if outOfOrderBytes + payload.count <= configuration.receiveBufferBytes / 2, outOfOrder[sequence] == nil {
                outOfOrder[sequence] = payload
                outOfOrderBytes += payload.count
            }
        }
    }

    private func drainOutOfOrderQueue() {
        while let next = outOfOrder[rcvNxt] {
            outOfOrder.removeValue(forKey: rcvNxt)
            outOfOrderBytes -= next.count
            enqueueToProxy(next)
            rcvNxt &+= UInt32(next.count)
        }
        if let pending = pendingAppFinSequence, pending == rcvNxt {
            pendingAppFinSequence = nil
            rcvNxt &+= 1
            appFinReceived = true
            appFinSequence = pending
            handleAppHalfClose()
        }
    }

    private func processInboundFIN(_ finSequence: UInt32) {
        if SequenceNumber.less(finSequence, rcvNxt) {
            // FIN for data we already have; the app may be retransmitting.
            if !appFinReceived {
                appFinReceived = true
                appFinSequence = finSequence
                handleAppHalfClose()
            }
            return
        }
        if finSequence == rcvNxt {
            rcvNxt &+= 1
            appFinReceived = true
            appFinSequence = finSequence
            handleAppHalfClose()
        } else {
            pendingAppFinSequence = finSequence
        }
    }

    private func handleAppHalfClose() {
        log?.debug("tcp", "\(key.description) app sent FIN; draining \(toProxyBytes) byte(s) then waiting for the proxy")
        // From the app's point of view it is done writing. Because SOCKS5 and
        // HTTP CONNECT cannot carry a half-close we keep the proxy stream open
        // and wait for the far end, bounded by `halfCloseGraceTimeout`.
        scheduleHalfCloseDeadline()
        flushToProxyQueue()
        evaluateClose()
    }

    private func scheduleHalfCloseDeadline() {
        halfCloseTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isClosed, !self.proxyReachedEOF else { return }
            self.log?.debug("tcp", "\(self.key.description) half-close grace period expired; closing")
            self.close(.clientClosed)
        }
        halfCloseTimer = work
        queue.asyncAfter(deadline: .now() + configuration.halfCloseGraceTimeout, execute: work)
    }

    // MARK: - ACK processing

    private func processAcknowledgment(_ segment: TCPSegment) {
        let acknowledgment = segment.acknowledgmentNumber

        // A window update is valid even without new data.
        sndWndField = segment.windowSize
        sndWnd = Int(segment.windowSize) << peerWindowScale
        if sndWnd > 0 { persistTimer?.cancel(); persistTimer = nil }

        // An ACK beyond what we have sent is invalid; ignore it rather than
        // tearing the connection down (some middleboxes get this wrong).
        guard SequenceNumber.lessOrEqual(acknowledgment, sndNxt) else { return }

        if SequenceNumber.less(sndUna, acknowledgment) {
            removeAcknowledgedBytes(upTo: acknowledgment)
            sndUna = acknowledgment
            retransmissionCount = 0
            currentRTO = configuration.initialRetransmissionTimeout
            duplicateAckCount = 0

            if state == .synReceived {
                state = .established
                log?.debug("tcp", "\(key.description) established")
            }
            if state == .finWait1, let finSequence = ourFinSequence, acknowledgment > finSequence {
                state = .finWait2
            }
            if state == .closing, let finSequence = ourFinSequence, acknowledgment > finSequence {
                state = .timeWait
            }
            if state == .lastAck, let finSequence = ourFinSequence, acknowledgment > finSequence {
                close(.clientClosed)
                return
            }
            if unacked.isEmpty {
                retransmissionTimer?.cancel()
                retransmissionTimer = nil
            } else {
                armRetransmissionTimer()
            }
            flushToApp()
            evaluateClose()
        } else if acknowledgment == sndUna && segment.payload.isEmpty && !segment.hasFIN && !segment.hasSYN {
            // Duplicate ACK: the classic loss signal.
            duplicateAckCount += 1
            if duplicateAckCount == 3, !unacked.isEmpty {
                log?.debug("tcp", "\(key.description) 3 duplicate ACKs -> fast retransmit")
                retransmitOldest()
                duplicateAckCount = 0
            }
        }
    }

    private func removeAcknowledgedBytes(upTo acknowledgment: UInt32) {
        while let first = unacked.first {
            let end = first.sequence &+ UInt32(first.data.count)
            if SequenceNumber.lessOrEqual(end, acknowledgment) {
                unacked.removeFirst()
                unackedBytes -= first.data.count
                statistics.bytesFromProxy += first.data.count
            } else {
                break
            }
        }
        if let first = unacked.first, SequenceNumber.less(first.sequence, acknowledgment) {
            let consumed = SequenceNumber.distance(from: first.sequence, to: acknowledgment)
            if consumed > 0 && consumed <= first.data.count {
                unacked[0].data = Data(first.data.dropFirst(consumed))
                unacked[0].sequence = acknowledgment
                unackedBytes -= consumed
                statistics.bytesFromProxy += consumed
            }
        }
    }

    // MARK: - Proxy side

    private func beginProxyConnection() {
        guard !isOpeningProxy, proxyConnection == nil, !isClosed else { return }
        guard let connector else {
            log?.error("tcp", "\(key.description) no proxy connector available")
            sendReset()
            close(.rejected("no proxy connector"))
            return
        }
        isOpeningProxy = true

        let destination = ProxyDestination.connect(
            host: configuration.remoteAddress.description,
            port: configuration.remotePort
        )
        log?.debug("tcp", "\(key.description) opening proxy stream to \(destination.redactedDescription)")

        connector.openProxyStream(to: destination, queue: queue) { [weak self] result in
            guard let self, !self.isClosed else {
                if case .success(let connection) = result { connection.close() }
                return
            }
            self.isOpeningProxy = false
            switch result {
            case .success(let connection):
                self.proxyConnection = connection
                self.log?.debug("tcp", "\(self.key.description) proxy stream ready: \(connection.outcome.responseSummary)")
                // Bytes the proxy already sent during the handshake belong to the app.
                if !connection.outcome.leftover.isEmpty {
                    self.appendToApp(connection.outcome.leftover)
                    self.flushToApp()
                }
                self.flushToProxyQueue()
                self.readFromProxy()
            case .failure(let error):
                self.log?.warning("tcp", "\(self.key.description) proxy stream failed: \(error.diagnosticDescription)")
                // Fail the app's connection immediately and visibly: a RST is
                // much better than a connection that hangs until it times out.
                self.sendReset()
                self.close(.proxyUnavailable(error))
            }
        }
    }

    private func enqueueToProxy(_ data: Data) {
        guard !data.isEmpty else { return }
        guard !appFinReceived else { return }   // the app already said it is done
        toProxyQueue.append(data)
        toProxyBytes += data.count
        flushToProxyQueue()
    }

    private func flushToProxyQueue() {
        guard !isWritingToProxy, let connection = proxyConnection, !proxyStreamClosed, !isClosed else { return }
        guard !toProxyQueue.isEmpty else { return }

        isWritingToProxy = true
        let chunk = toProxyQueue.removeFirst()
        toProxyBytes -= chunk.count

        connection.stream.write(chunk) { [weak self] result in
            guard let self else { return }
            self.isWritingToProxy = false
            switch result {
            case .success:
                self.statistics.bytesToProxy += chunk.count
                self.flushToProxyQueue()
            case .failure(let error):
                self.log?.debug("tcp", "\(self.key.description) write to proxy failed: \(error)")
                self.close(.proxyClosed)
            }
        }
    }

    private func readFromProxy() {
        guard !proxyReadOutstanding, let connection = proxyConnection, !proxyStreamClosed, !isClosed else { return }
        // Back-pressure: stop pulling from the proxy while the app is behind.
        guard toAppBytes + unackedBytes < configuration.sendBufferBytes else { return }

        proxyReadOutstanding = true
        connection.stream.read { [weak self] result in
            guard let self, !self.isClosed else { return }
            self.proxyReadOutstanding = false
            switch result {
            case .success(let data):
                if data.isEmpty {
                    self.proxyStreamClosed = true
                    self.proxyReachedEOF = true
                    self.lastActivityAt = Date()
                    self.log?.debug("tcp", "\(self.key.description) proxy stream reached EOF")
                    self.evaluateClose()
                    return
                }
                self.lastActivityAt = Date()
                self.armIdleTimer()
                self.appendToApp(data)
                self.flushToApp()
                self.readFromProxy()
            case .failure(let error):
                self.log?.debug("tcp", "\(self.key.description) read from proxy failed: \(error)")
                self.close(.proxyClosed)
            }
        }
    }

    private func appendToApp(_ data: Data) {
        guard !data.isEmpty else { return }
        toAppQueue.append(data)
        toAppBytes += data.count
    }

    /// Segments as much queued data toward the app as its window allows.
    private func flushToApp() {
        guard !isClosed else { return }
        guard !weSentFin else { return }

        while !toAppQueue.isEmpty || toAppOffset > 0 {
            guard sndWnd > 0 else {
                armPersistTimer()
                return
            }
            let inFlight = SequenceNumber.distance(from: sndUna, to: sndNxt)
            let usable = min(sndWnd - inFlight, peerMaximumSegmentSize)
            guard usable > 0 else { return }

            var chunk = toAppQueue[0]
            if toAppOffset > 0 {
                chunk = Data(chunk.dropFirst(toAppOffset))
            }
            let take = min(usable, chunk.count)
            let slice = Data(chunk.prefix(take))

            toAppOffset += take
            toAppBytes -= take
            if toAppOffset >= toAppQueue[0].count {
                toAppQueue.removeFirst()
                toAppOffset = 0
            }

            let isLastChunk = toAppQueue.isEmpty && toAppOffset == 0
            var flags: TCPFlags = [.ack]
            if isLastChunk { flags.insert(.psh) }

            let segment = TCPSegment(
                sourcePort: key.remotePort,
                destinationPort: key.clientPort,
                sequenceNumber: sndNxt,
                acknowledgmentNumber: rcvNxt,
                flags: flags,
                windowSize: advertisedWindowField(),
                payload: slice
            )
            sndNxt &+= UInt32(slice.count)
            unacked.append(OutstandingSegment(sequence: segment.sequenceNumber, data: slice))
            unackedBytes += slice.count
            transmit(segment)
            armRetransmissionTimer()
        }
    }

    // MARK: - Transmit

    private func transmit(_ segment: TCPSegment) {
        let raw = segment.serialized(source: configuration.remoteAddress, destination: configuration.clientAddress)
        let packet = ParsedIPPacket.build(
            source: configuration.remoteAddress,
            destination: configuration.clientAddress,
            protocolNumber: IPProtocolNumber.tcp,
            payload: [UInt8](raw),
            identification: nextIdentification,
            hopLimit: 64
        )
        nextIdentification &+= 1
        statistics.segmentsOut += 1
        if configuration.tracePackets {
            log?.trace("tcp", "out \(segment.traceDescription(source: configuration.remoteAddress, destination: configuration.clientAddress))")
        }
        emit(packet)
    }

    private func sendAcknowledgment() {
        guard !isClosed else { return }
        let segment = TCPSegment(
            sourcePort: key.remotePort,
            destinationPort: key.clientPort,
            sequenceNumber: sndNxt,
            acknowledgmentNumber: rcvNxt,
            flags: [.ack],
            windowSize: advertisedWindowField()
        )
        transmit(segment)
    }

    private func sendReset() {
        guard !isClosed else { return }
        let segment = TCPSegment(
            sourcePort: key.remotePort,
            destinationPort: key.clientPort,
            sequenceNumber: appFinReceived ? rcvNxt : sndNxt,
            acknowledgmentNumber: rcvNxt,
            flags: [.rst, .ack],
            windowSize: 0
        )
        transmit(segment)
    }

    /// Sends FIN toward the app and follows the state machine forward.
    private func closeTowardApp() {
        guard !weSentFin, !isClosed else { return }
        // A FIN occupies a sequence number and must follow all queued data.
        if !toAppQueue.isEmpty || toAppOffset > 0 {
            // Flush what we can; the FIN goes out once the queue drains.
            flushToApp()
            if !toAppQueue.isEmpty || toAppOffset > 0 { return }
        }
        let segment = TCPSegment(
            sourcePort: key.remotePort,
            destinationPort: key.clientPort,
            sequenceNumber: sndNxt,
            acknowledgmentNumber: rcvNxt,
            flags: [.fin, .ack],
            windowSize: advertisedWindowField()
        )
        ourFinSequence = sndNxt
        sndNxt &+= 1
        weSentFin = true
        switch state {
        case .established, .synReceived: state = .finWait1
        case .finWait2:                  state = .timeWait
        default:                         state = .closing
        }
        transmit(segment)
        armRetransmissionTimer()
    }

    private func scheduleLingerClose() {
        // Idempotent on purpose: `evaluateClose` runs on every inbound segment, and
        // re-arming would let a chatty peer keep the connection alive for ever.
        guard lingerTimer == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.close(.clientClosed)
        }
        lingerTimer = work
        // 2 * MSL is 4 minutes in the RFC; on a phone that is far too long to hold
        // memory. 5 seconds is plenty to absorb a retransmitted final ACK.
        queue.asyncAfter(deadline: .now() + 5, execute: work)
    }

    // MARK: - Timers

    private func advertisedWindowField() -> UInt16 {
        let buffered = toProxyBytes + outOfOrderBytes
        let available = max(0, configuration.receiveBufferBytes - buffered)
        let scaled = available >> configuration.receiveWindowScale
        return UInt16(clamping: min(scaled, 0xFFFF))
    }

    private func armRetransmissionTimer() {
        retransmissionTimer?.cancel()
        guard !unacked.isEmpty, !isClosed else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.handleRetransmissionTimeout()
        }
        retransmissionTimer = work
        queue.asyncAfter(deadline: .now() + currentRTO, execute: work)
    }

    private func handleRetransmissionTimeout() {
        guard !isClosed, !unacked.isEmpty else { return }
        retransmissionCount += 1
        statistics.retransmissions += 1

        guard retransmissionCount <= configuration.maximumRetransmissions else {
            log?.warning("tcp", "\(key.description) giving up after \(retransmissionCount) retransmissions")
            close(.timedOut)
            return
        }
        currentRTO = min(currentRTO * 2, 8)
        retransmitOldest()
        armRetransmissionTimer()
    }

    private func retransmitOldest() {
        guard let first = unacked.first else { return }
        let flags: TCPFlags = first.data.isEmpty ? [.ack] : [.ack, .psh]
        let segment = TCPSegment(
            sourcePort: key.remotePort,
            destinationPort: key.clientPort,
            sequenceNumber: first.sequence,
            acknowledgmentNumber: rcvNxt,
            flags: flags,
            windowSize: advertisedWindowField(),
            payload: first.data
        )
        transmit(segment)
    }

    private func armPersistTimer() {
        guard persistTimer == nil, !isClosed else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.persistTimer = nil
            let hasQueuedData = !self.toAppQueue.isEmpty || self.toAppOffset > 0
            guard !self.isClosed, self.sndWnd == 0, hasQueuedData else { return }
            // A zero-window probe: a bare ACK asking the peer to re-announce its
            // window, which is what RFC 9293 §3.8.6.1 recommends.
            self.sendAcknowledgment()
            self.armPersistTimer()
        }
        persistTimer = work
        queue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func armIdleTimer() {
        idleTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.close(.idleTimeout)
        }
        idleTimer = work
        queue.asyncAfter(deadline: .now() + configuration.idleTimeout, execute: work)
    }

    // MARK: - Closing

    /// Decides whether the connection is finished, and drives the FIN exchange.
    ///
    /// Called after every event that could complete the close: the app's FIN, the
    /// proxy's EOF, and the app's ACK of our FIN.
    ///
    /// The rule is simple: once we know the far end is done (`proxyReachedEOF`)
    /// we send our FIN; once *both* directions have seen a FIN we hold the socket
    /// briefly to absorb a retransmitted final ACK and then retire.
    private func evaluateClose() {
        guard !isClosed else { return }

        if proxyReachedEOF && !weSentFin {
            closeTowardApp()
        }

        if weSentFin && appFinReceived {
            scheduleLingerClose()
        }
    }

    /// Tears the connection down. Idempotent. Must be called on `queue`.
    public func close(_ reason: TCPConnectionCloseReason) {
        guard !isClosed else { return }
        isClosed = true
        state = .closed

        retransmissionTimer?.cancel(); retransmissionTimer = nil
        idleTimer?.cancel(); idleTimer = nil
        persistTimer?.cancel(); persistTimer = nil
        lingerTimer?.cancel(); lingerTimer = nil
        halfCloseTimer?.cancel(); halfCloseTimer = nil

        proxyConnection?.close()
        proxyConnection = nil

        if configuration.tracePackets {
            log?.trace("tcp", "closed \(key.description) reason=\(reason.description) stats=\(statistics)")
        }
        onClose(reason, statistics)
    }

    /// True once the object will no longer do anything.
    public var isFinished: Bool { isClosed }

    // MARK: - Instrumentation

    private func tracePacket(_ direction: String, _ segment: TCPSegment) {
        guard configuration.tracePackets else { return }
        log?.trace("tcp", "\(direction) \(segment.traceDescription(source: configuration.clientAddress, destination: configuration.remoteAddress))")
    }

    /// A short, log-safe summary used by the diagnostics screen.
    public var diagnosticSummary: String {
        "\(key.description) state=\(state.rawValue) "
            + "in=\(statistics.bytesToProxy)B out=\(statistics.bytesFromProxy)B "
            + "segs=\(statistics.segmentsIn)/\(statistics.segmentsOut) "
            + "rexmit=\(statistics.retransmissions) ooo=\(statistics.outOfOrderSegments) dup=\(statistics.duplicateSegments)"
    }
}
