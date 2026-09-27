//
//  TunnelMessaging.swift
//  ProxyTunnelCore
//
//  The app ⇄ extension channel.
//
//  `NETunnelProviderSession.sendProviderMessage(_:responseHandler:)` carries an
//  opaque `Data`. Everything crossing it is Codable JSON with an explicit schema
//  version, so a stale extension from a previous install cannot be misread.
//

import Foundation

public enum TunnelMessageKey {
    public static let request = "ProxyTunnel.Request"
    public static let response = "ProxyTunnel.Response"
}

public enum TunnelRequestKind: String, Codable, Sendable {
    /// Ask the extension for a full status snapshot.
    case status
    /// Clear the extension's in-memory log.
    case clearLog
    /// Turn per-packet tracing on or off at runtime.
    case setTracePackets
    /// Liveness check that does not read any tunnel state.
    case ping
}

public struct TunnelRequestEnvelope: Codable, Sendable {
    public var schemaVersion: Int
    public var kind: TunnelRequestKind
    public var tracePackets: Bool?

    public init(kind: TunnelRequestKind, tracePackets: Bool? = nil) {
        self.schemaVersion = TunnelConfiguration.currentSchemaVersion
        self.kind = kind
        self.tracePackets = tracePackets
    }
}

/// Everything the app needs to render the connection screen truthfully.
public struct TunnelStatusPayload: Codable, Equatable, Sendable {

    public var schemaVersion: Int
    /// `TunnelEngine.EngineState` raw value.
    public var engineState: String
    public var connectedSince: Date?
    public var statistics: TunnelStatistics
    public var lastFailure: TunnelFailure?

    /// Whether `setTunnelNetworkSettings` completed successfully. Until it has,
    /// the tunnel carries no traffic even though the extension is running.
    public var networkSettingsApplied: Bool
    /// Human-readable routing description from `TunnelNetworkSettingsFactory`.
    public var networkSettingsDescription: [String]
    /// Redacted configuration summary.
    public var configurationSummary: String?
    /// Description of the SOCKS5 UDP relay, when one was established.
    public var udpRelayDescription: String?
    /// The physical interface the tunnel bound its transport to, if it could
    /// determine one.
    public var physicalInterface: String?
    /// Lines of the extension's log, newest last, capped by the extension.
    public var recentLog: [String]

    public init(
        engineState: String,
        connectedSince: Date? = nil,
        statistics: TunnelStatistics = TunnelStatistics(),
        lastFailure: TunnelFailure? = nil,
        networkSettingsApplied: Bool = false,
        networkSettingsDescription: [String] = [],
        configurationSummary: String? = nil,
        udpRelayDescription: String? = nil,
        physicalInterface: String? = nil,
        recentLog: [String] = []
    ) {
        self.schemaVersion = TunnelConfiguration.currentSchemaVersion
        self.engineState = engineState
        self.connectedSince = connectedSince
        self.statistics = statistics
        self.lastFailure = lastFailure
        self.networkSettingsApplied = networkSettingsApplied
        self.networkSettingsDescription = networkSettingsDescription
        self.configurationSummary = configurationSummary
        self.udpRelayDescription = udpRelayDescription
        self.physicalInterface = physicalInterface
        self.recentLog = recentLog
    }

    /// Whether the tunnel is up *and* actually carrying traffic.
    public var isCarryingTraffic: Bool {
        engineState == "running" && networkSettingsApplied
    }
}

public struct TunnelResponseEnvelope: Codable, Sendable {
    public var schemaVersion: Int
    public var status: TunnelStatusPayload?
    public var error: String?

    public init(status: TunnelStatusPayload? = nil, error: String? = nil) {
        self.schemaVersion = TunnelConfiguration.currentSchemaVersion
        self.status = status
        self.error = error
    }
}

public enum TunnelMessageCodec {

    public static func encode(_ request: TunnelRequestEnvelope) throws -> Data {
        try JSONEncoder().encode(request)
    }

    public static func decodeRequest(_ data: Data) throws -> TunnelRequestEnvelope {
        let envelope = try JSONDecoder().decode(TunnelRequestEnvelope.self, from: data)
        guard envelope.schemaVersion <= TunnelConfiguration.currentSchemaVersion else {
            throw TunnelConfiguration.CodingError.unsupportedSchemaVersion(envelope.schemaVersion)
        }
        return envelope
    }

    public static func encode(_ response: TunnelResponseEnvelope) throws -> Data {
        try JSONEncoder().encode(response)
    }

    public static func decodeResponse(_ data: Data) throws -> TunnelResponseEnvelope {
        try JSONDecoder().decode(TunnelResponseEnvelope.self, from: data)
    }
}
