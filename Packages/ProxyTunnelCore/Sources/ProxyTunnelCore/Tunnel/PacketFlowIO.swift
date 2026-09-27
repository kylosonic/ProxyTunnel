//
//  PacketFlowIO.swift
//  ProxyTunnelCore
//

import Foundation

/// The tunnel's view of the virtual network interface.
///
/// `NEPacketTunnelFlow` conforms to this in the extension target (see
/// `NEPacketTunnelFlowAdapter`). Tests use `ScriptedPacketFlow`, which makes the
/// whole engine testable without a device.
public protocol PacketFlowIO: AnyObject {

    /// Requests the next batch of IP packets. `completion` is called with the
    /// packets and, in parallel, the address family of each packet as an
    /// `AF_INET` / `AF_INET6` `NSNumber`.
    func readPackets(completion: @escaping ([Data], [NSNumber]) -> Void)

    /// Writes IP packets back to the virtual interface.
    func writePackets(_ packets: [Data], protocols: [NSNumber], completion: @escaping (Bool) -> Void)
}

/// Batches packet writes.
///
/// `NEPacketTunnelFlow.writePackets` takes an array for a reason: crossing into
/// the kernel once per packet is far more expensive than once per batch. The
/// engine produces packets from many independent flows, so a tiny coalescer sits
/// in front of the flow.
final class PacketWriteCoalescer {

    private let flow: PacketFlowIO
    private let queue: DispatchQueue
    private let maximumBatch: Int
    private let maximumDelay: TimeInterval

    private var packets: [Data] = []
    private var protocols: [NSNumber] = []
    private var flushScheduled = false

    init(flow: PacketFlowIO, queue: DispatchQueue, maximumBatch: Int = 32, maximumDelay: TimeInterval = 0.005) {
        self.flow = flow
        self.queue = queue
        self.maximumBatch = maximumBatch
        self.maximumDelay = maximumDelay
    }

    /// Enqueues one packet. Must be called on `queue`.
    func write(_ packet: Data, family: Int32) {
        packets.append(packet)
        protocols.append(NSNumber(value: family))
        if packets.count >= maximumBatch {
            flush()
        } else if !flushScheduled {
            flushScheduled = true
            queue.asyncAfter(deadline: .now() + maximumDelay) { [weak self] in
                self?.flush()
            }
        }
    }

    /// Flushes everything pending. Must be called on `queue`.
    func flush() {
        flushScheduled = false
        guard !packets.isEmpty else { return }
        let batch = packets
        let families = protocols
        packets.removeAll(keepingCapacity: true)
        protocols.removeAll(keepingCapacity: true)
        flow.writePackets(batch, protocols: families) { _ in }
    }
}
