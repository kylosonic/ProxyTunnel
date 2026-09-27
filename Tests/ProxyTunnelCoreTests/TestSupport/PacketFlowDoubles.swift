//
//  PacketFlowDoubles.swift
//  ProxyTunnelCoreTests
//
//  In-memory doubles that let the tunnel engine and the TCP state machine be
//  tested deterministically, with no network, no device and no entitlement.
//

import Foundation
import Network
import XCTest
@testable import ProxyTunnelCore

#if canImport(Darwin)
import Darwin
#endif

// MARK: - Virtual interface

/// A `PacketFlowIO` whose reads the test drives by hand and whose writes the test
/// can inspect.
final class ScriptedPacketFlow: PacketFlowIO {

    private let lock = NSLock()
    private var pendingRead: (([Data], [NSNumber]) -> Void)?
    private(set) var writtenPackets: [Data] = []
    private(set) var writtenFamilies: [Int32] = []

    /// Notified synchronously on `writePackets`.
    var onWrite: ((Data) -> Void)?

    func readPackets(completion: @escaping ([Data], [NSNumber]) -> Void) {
        lock.lock()
        pendingRead = completion
        lock.unlock()
    }

    func writePackets(_ packets: [Data], protocols: [NSNumber], completion: @escaping (Bool) -> Void) {
        lock.lock()
        for (index, packet) in packets.enumerated() {
            writtenPackets.append(packet)
            writtenFamilies.append(index < protocols.count ? protocols[index].int32Value : AF_INET)
        }
        lock.unlock()
        for packet in packets { onWrite?(packet) }
        completion(true)
    }

    /// Feeds packets into the engine. No-op unless the engine is waiting.
    @discardableResult
    func deliver(_ packets: [Data]) -> Bool {
        lock.lock()
        let completion = pendingRead
        pendingRead = nil
        lock.unlock()
        guard let completion else { return false }
        completion(packets, packets.map { NSNumber(value: Int32(($0.first ?? 0) >> 4 == 6 ? AF_INET6 : AF_INET)) })
        return true
    }

    var hasPendingRead: Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingRead != nil
    }

    /// Waits until the engine has asked for more packets.
    func waitForPendingRead(timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if hasPendingRead { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        return false
    }

    /// Waits until at least `count` packets have been written back.
    func waitForWrites(_ count: Int, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let current = writtenPackets.count
            lock.unlock()
            if current >= count { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        return false
    }

    func snapshot() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return writtenPackets
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        writtenPackets.removeAll()
        writtenFamilies.removeAll()
    }
}

// MARK: - In-memory proxy stream

/// A `DuplexByteStream` that never touches the network.
///
/// The test pushes bytes in with `feed(_:)` and reads what the client wrote from
/// `written`. That is enough to drive the whole `ProxySession` state machine
/// deterministically, including the "reply arrives in two chunks" cases that are
/// the usual source of protocol bugs.
final class FakeByteStream: DuplexByteStream {

    private let queue: DispatchQueue
    private var incoming: [Data] = []
    private var pendingRead: ((Result<Data, Error>) -> Void)?
    private var closed = false

    private(set) var written = Data()
    /// Called whenever the client writes something.
    var onWrite: ((Data) -> Void)?
    /// When set, `open` fails with this error instead of succeeding.
    var openError: Error?

    var localEndpointDescription: String? { "fake-local" }
    var remoteEndpointDescription: String? { "fake-remote" }

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func open(queue: DispatchQueue, completion: @escaping (Result<Void, Error>) -> Void) {
        if let openError {
            queue.async { completion(.failure(openError)) }
        } else {
            queue.async { completion(.success(())) }
        }
    }

    func write(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            guard !self.closed else {
                completion(.failure(ByteStreamError.closed))
                return
            }
            self.written.append(data)
            self.onWrite?(data)
            completion(.success(()))
        }
    }

    func read(completion: @escaping (Result<Data, Error>) -> Void) {
        queue.async {
            if let next = self.incoming.first {
                self.incoming.removeFirst()
                completion(.success(next))
                return
            }
            if self.closed {
                completion(.success(Data()))
                return
            }
            self.pendingRead = completion
        }
    }

    func close() {
        queue.async {
            self.closed = true
            if let pending = self.pendingRead {
                self.pendingRead = nil
                pending(.success(Data()))
            }
        }
    }

    // MARK: Test control

    /// Queues bytes for the client to read, then satisfies a pending read.
    func feed(_ data: Data) {
        queue.async {
            if let pending = self.pendingRead {
                self.pendingRead = nil
                pending(.success(data))
            } else {
                self.incoming.append(data)
            }
        }
    }

    /// Signals end of stream.
    func feedEOF() {
        queue.async {
            if let pending = self.pendingRead {
                self.pendingRead = nil
                pending(.success(Data()))
            }
        }
    }

    var writtenBytes: Data {
        queue.sync { written }
    }
}

// MARK: - Fake proxy opener

/// A `ProxyStreamOpening` that hands out pre-built fake connections.
final class FakeProxyOpener: ProxyStreamOpening {

    enum Behaviour {
        /// Return a connection immediately, with the outcome already negotiated.
        case succeed(ProxySession.Outcome)
        /// Fail with this error.
        case fail(ProxyError)
        /// Never call the completion — simulates a stalled handshake.
        case hang
    }

    var behaviour: Behaviour
    private(set) var streams: [FakeByteStream] = []
    private(set) var destinations: [ProxyDestination] = []

    init(behaviour: Behaviour = .succeed(ProxySession.Outcome(
        protocolType: .socks5,
        responseSummary: "SOCKS5 CONNECT succeeded",
        boundHost: nil,
        boundPort: nil,
        leftover: Data()
    ))) {
        self.behaviour = behaviour
    }

    func openProxyStream(
        to destination: ProxyDestination,
        queue: DispatchQueue,
        completion: @escaping (Result<ProxyConnection, ProxyError>) -> Void
    ) {
        destinations.append(destination)
        switch behaviour {
        case .hang:
            return
        case .fail(let error):
            queue.async { completion(.failure(error)) }
        case .succeed(let outcome):
            let stream = FakeByteStream(queue: queue)
            streams.append(stream)
            let connection = ProxyConnection(
                stream: stream,
                endpoint: ProxyEndpoint(host: "127.0.0.1", port: 1080, protocolType: .socks5, credential: nil),
                destination: destination,
                outcome: outcome,
                dialedTarget: TransportTarget(host: "127.0.0.1", port: 1080),
                tcpConnectDuration: 0.01,
                handshakeDuration: 0.01
            )
            queue.async { completion(.success(connection)) }
        }
    }

    var lastStream: FakeByteStream? { streams.last }
}

// MARK: - Packet helpers

enum TestPackets {

    static let clientAddress = IPAddress(presentationName: "10.7.0.1")!
    static let remoteAddress = IPAddress(presentationName: "93.184.216.34")!

    /// Builds a TCP packet as if it came out of the tunnel interface.
    static func tcpPacket(
        source: IPAddress = clientAddress,
        destination: IPAddress = remoteAddress,
        sourcePort: UInt16 = 49152,
        destinationPort: UInt16 = 443,
        sequence: UInt32,
        acknowledgment: UInt32 = 0,
        flags: TCPFlags,
        window: UInt16 = 65535,
        options: [UInt8] = [],
        payload: Data = Data()
    ) -> Data {
        let segment = TCPSegment(
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            sequenceNumber: sequence,
            acknowledgmentNumber: acknowledgment,
            flags: flags,
            windowSize: window,
            options: options,
            payload: payload
        )
        let raw = segment.serialized(source: source, destination: destination)
        return ParsedIPPacket.build(
            source: source,
            destination: destination,
            protocolNumber: IPProtocolNumber.tcp,
            payload: [UInt8](raw),
            identification: 1
        )
    }

    /// Parses a packet the engine wrote back.
    static func parseTCP(_ packet: Data) throws -> (packet: ParsedIPPacket, segment: TCPSegment) {
        let parsed = try ParsedIPPacket.parse(packet)
        let segment = try TCPSegment.parse(parsed.payload)
        return (parsed, segment)
    }

    /// SYN options a real iOS stack sends: MSS 1460 and window scale 6.
    static let synOptions: [UInt8] = [2, 4, 0x05, 0xB4, 3, 3, 6]
}
