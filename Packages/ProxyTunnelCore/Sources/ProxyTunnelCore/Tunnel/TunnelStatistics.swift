//
//  TunnelStatistics.swift
//  ProxyTunnelCore
//

import Foundation

/// Counters the tunnel keeps and reports to the app.
///
/// These are deliberately *facts about work actually done*, not estimates, so
/// that the diagnostics screen can be trusted: if `tcpConnectionsOpened` is zero
/// then no TCP connection was ever proxied, whatever the status light says.
public struct TunnelStatistics: Codable, Equatable, Sendable {

    /// Explicit public initialiser: the synthesised member-wise one is internal,
    /// which would make `TunnelStatistics()` unusable as a default argument in
    /// the public initialisers of other types.
    public init() {}

    public var startedAt: Date?
    public var stoppedAt: Date?

    // ---- Packets exchanged with the virtual interface ----------------------
    public var packetsFromTunnel: Int = 0
    public var packetsToTunnel: Int = 0
    public var bytesFromTunnel: Int = 0
    public var bytesToTunnel: Int = 0

    // ---- TCP ---------------------------------------------------------------
    public var tcpConnectionsOpened: Int = 0
    public var tcpConnectionsClosed: Int = 0
    public var tcpConnectionsRejected: Int = 0
    public var tcpActiveConnections: Int = 0
    public var tcpBytesToProxy: Int = 0
    public var tcpBytesFromProxy: Int = 0
    public var tcpRetransmissions: Int = 0

    // ---- UDP ---------------------------------------------------------------
    public var udpRelayAvailable: Bool = false
    public var udpDatagramsRelayed: Int = 0
    public var udpDatagramsReceived: Int = 0
    public var udpDatagramsDropped: Int = 0

    // ---- DNS ---------------------------------------------------------------
    public var dnsQueriesHandled: Int = 0
    public var dnsQueriesFailed: Int = 0

    // ---- Dropped traffic ---------------------------------------------------
    public var droppedMalformedPackets: Int = 0
    public var droppedFragments: Int = 0
    public var droppedUnsupportedTransport: Int = 0
    public var droppedBlockedDestination: Int = 0

    /// Proxy handshake failures, keyed by the failure kind.
    public var proxyFailures: [String: Int] = [:]

    public var duration: TimeInterval {
        guard let startedAt else { return 0 }
        return (stoppedAt ?? Date()).timeIntervalSince(startedAt)
    }

    /// Lines for the Diagnostics screen.
    public var summaryLines: [String] {
        var lines: [String] = []
        lines.append("Tunnel interface: \(packetsFromTunnel) packets in (\(formatBytes(bytesFromTunnel))), \(packetsToTunnel) packets out (\(formatBytes(bytesToTunnel)))")
        lines.append("TCP: \(tcpConnectionsOpened) opened, \(tcpConnectionsClosed) closed, \(tcpActiveConnections) active, \(tcpConnectionsRejected) rejected")
        lines.append("TCP payload: \(formatBytes(tcpBytesToProxy)) sent to the proxy, \(formatBytes(tcpBytesFromProxy)) received")
        if tcpRetransmissions > 0 {
            lines.append("TCP retransmissions: \(tcpRetransmissions)")
        }
        lines.append("UDP relay: \(udpRelayAvailable ? "active" : "unavailable for this protocol"); \(udpDatagramsRelayed) relayed, \(udpDatagramsReceived) received, \(udpDatagramsDropped) dropped")
        lines.append("DNS: \(dnsQueriesHandled) queries handled, \(dnsQueriesFailed) failed")
        let dropped = droppedMalformedPackets + droppedFragments + droppedUnsupportedTransport + droppedBlockedDestination
        if dropped > 0 {
            lines.append("Dropped: \(droppedMalformedPackets) malformed, \(droppedFragments) fragmented, \(droppedUnsupportedTransport) unsupported, \(droppedBlockedDestination) blocked")
        }
        if !proxyFailures.isEmpty {
            let described = proxyFailures
                .sorted { $0.key < $1.key }
                .map { "\($0.key)×\($0.value)" }
                .joined(separator: ", ")
            lines.append("Proxy failures: \(described)")
        }
        return lines
    }

    private func formatBytes(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(count))
    }

    public mutating func recordProxyFailure(_ error: ProxyError) {
        let key: String
        switch error {
        case .cannotResolveHost:        key = "resolve"
        case .connectionFailed:         key = "connect"
        case .connectionTimeout:        key = "timeout"
        case .tlsFailed:                key = "tls"
        case .authenticationRequired:   key = "auth-required"
        case .authenticationRejected:   key = "auth-rejected"
        case .unsupportedAuthMethod:    key = "auth-unsupported"
        case .badServerResponse:        key = "bad-response"
        case .proxyRefusedConnection:   key = "refused-target"
        case .addressFamilyUnsupported: key = "address-family"
        case .protocolViolation:        key = "protocol"
        case .cancelled:                key = "cancelled"
        }
        proxyFailures[key, default: 0] += 1
    }
}
