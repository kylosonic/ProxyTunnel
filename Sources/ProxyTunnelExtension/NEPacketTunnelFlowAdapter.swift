//
//  NEPacketTunnelFlowAdapter.swift
//  ProxyTunnelExtension
//
//  Bridges Apple's `NEPacketTunnelFlow` to the `PacketFlowIO` protocol the tunnel
//  engine is written against.
//
//  Keeping this adapter in the extension target (rather than in the core package)
//  is what lets the engine be unit-tested with a scripted packet flow and no
//  device, no entitlement and no simulator networking.
//

import Foundation
import NetworkExtension
import ProxyTunnelCore

final class NEPacketTunnelFlowAdapter: PacketFlowIO {

    private let flow: NEPacketTunnelFlow

    init(flow: NEPacketTunnelFlow) {
        self.flow = flow
    }

    func readPackets(completion: @escaping ([Data], [NSNumber]) -> Void) {
        flow.readPackets { packets, protocolFamilies in
            completion(packets, protocolFamilies)
        }
    }

    func writePackets(_ packets: [Data], protocols: [NSNumber], completion: @escaping (Bool) -> Void) {
        // The array form matters: each call crosses into the kernel's network
        // stack, so batching is a real performance win on a busy tunnel. The
        // engine's coalescer hands us batches.
        flow.writePackets(packets, withProtocols: protocols) { success in
            completion(success)
        }
    }
}
