//
//  TunnelConfiguration.swift
//  ProxyTunnelCore
//
//  The complete, self-contained description of the tunnel the extension should
//  bring up. It is produced by the main app and delivered to the extension in
//  `NETunnelProviderProtocol.providerConfiguration`.
//

import Foundation

public struct TunnelConfiguration: Codable, Equatable, Sendable {

    /// Bumped whenever the on-the-wire shape changes. The extension refuses a
    /// configuration from the future instead of misreading it.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int

    // ---- Identity ----------------------------------------------------------
    public var profileID: String
    public var profileName: String
    public var isMock: Bool

    // ---- Proxy -------------------------------------------------------------
    public var host: String
    public var port: Int
    public var protocolType: ProxyProtocol
    public var username: String?
    /// Only populated when the credential could not be delivered through a shared
    /// container. See `credentialDelivery`.
    public var inlinePassword: String?

    /// Addresses the proxy host resolved to, resolved by the *app* before the
    /// tunnel existed.
    ///
    /// This is essential: inside the tunnel there is no DNS until the tunnel is
    /// up, so the extension must never have to resolve the proxy's own name. The
    /// same list is also punched out of the tunnel routes so that the tunnel's
    /// transport does not loop back into itself.
    public var resolvedProxyAddresses: [String]

    // ---- Virtual interface -------------------------------------------------
    public var ipv4Address: String
    public var ipv4SubnetMask: String
    public var ipv6Address: String
    public var ipv6PrefixLength: Int
    public var mtu: Int

    /// Send all traffic through the tunnel (`0.0.0.0/0`, `::/0`).
    public var routeAllTraffic: Bool
    /// Additional CIDRs to keep *outside* the tunnel.
    public var excludedRoutes: [String]

    // ---- DNS ---------------------------------------------------------------
    /// Resolvers the tunnel advertises to iOS. The tunnel intercepts port 53 and
    /// relays every query through the proxy, so these are the addresses the query
    /// is finally sent to — never a local network resolver.
    public var dnsServers: [String]
    /// Relay UDP through a SOCKS5 UDP ASSOCIATE when the protocol supports it.
    /// Ignored for HTTP proxies, which cannot carry datagrams.
    public var relayUDP: Bool

    // ---- Behaviour ---------------------------------------------------------
    /// Ask iOS to keep the tunnel up and block traffic while it is reconnecting.
    public var blockTrafficWhenTunnelDown: Bool
    public var allowIPv6: Bool
    public var tracePackets: Bool
    public var idleTimeoutSeconds: Int

    // ---- Provenance --------------------------------------------------------
    public var credentialDelivery: CredentialDelivery
    public var createdAt: Date

    public enum CredentialDelivery: String, Codable, Sendable {
        /// Read from the App Group shared container by the extension.
        case sharedContainer
        /// Carried inline in `providerConfiguration` (iOS stores it unencrypted).
        case inlineProviderConfiguration
        /// No credentials at all.
        case none
    }

    public init(
        profileID: String,
        profileName: String,
        isMock: Bool = false,
        host: String,
        port: Int,
        protocolType: ProxyProtocol,
        username: String?,
        inlinePassword: String?,
        resolvedProxyAddresses: [String],
        ipv4Address: String = TunnelNetworkDefaults.ipv4Address,
        ipv4SubnetMask: String = TunnelNetworkDefaults.ipv4SubnetMask,
        ipv6Address: String = TunnelNetworkDefaults.ipv6Address,
        ipv6PrefixLength: Int = TunnelNetworkDefaults.ipv6PrefixLength,
        mtu: Int = TunnelNetworkDefaults.mtu,
        routeAllTraffic: Bool = true,
        excludedRoutes: [String] = [],
        dnsServers: [String] = TunnelNetworkDefaults.dnsServers,
        relayUDP: Bool = true,
        blockTrafficWhenTunnelDown: Bool = false,
        allowIPv6: Bool = true,
        tracePackets: Bool = false,
        idleTimeoutSeconds: Int = 1800,
        credentialDelivery: CredentialDelivery = .none,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.profileID = profileID
        self.profileName = profileName
        self.isMock = isMock
        self.host = host
        self.port = port
        self.protocolType = protocolType
        self.username = username
        self.inlinePassword = inlinePassword
        self.resolvedProxyAddresses = resolvedProxyAddresses
        self.ipv4Address = ipv4Address
        self.ipv4SubnetMask = ipv4SubnetMask
        self.ipv6Address = ipv6Address
        self.ipv6PrefixLength = ipv6PrefixLength
        self.mtu = mtu
        self.routeAllTraffic = routeAllTraffic
        self.excludedRoutes = excludedRoutes
        self.dnsServers = dnsServers
        self.relayUDP = relayUDP
        self.blockTrafficWhenTunnelDown = blockTrafficWhenTunnelDown
        self.allowIPv6 = allowIPv6
        self.tracePackets = tracePackets
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.credentialDelivery = credentialDelivery
        self.createdAt = createdAt
    }

    // MARK: Derived

    public var credential: ProxyCredential? {
        guard let username, !username.isEmpty else { return nil }
        guard let inlinePassword else { return nil }
        return ProxyCredential(username: username, password: inlinePassword)
    }

    /// The endpoint the extension will dial, using only addresses the app already
    /// resolved.
    public func proxyEndpoint(credential override: ProxyCredential? = nil) -> ProxyEndpoint {
        ProxyEndpoint(
            host: host,
            port: port,
            protocolType: protocolType,
            credential: override ?? credential
        )
    }

    /// A single-line, log-safe description. Never contains the password.
    public var redactedSummary: String {
        var parts: [String] = []
        parts.append("profile=\"\(profileName)\"")
        parts.append("proxy=\(protocolType.displayName) \(ProxyProfile.formatEndpoint(host: host, port: port))")
        parts.append("resolved=\(resolvedProxyAddresses.joined(separator: ","))")
        parts.append("ipv4=\(ipv4Address)/\(ipv4SubnetMask)")
        parts.append("ipv6=\(allowIPv6 ? "\(ipv6Address)/\(ipv6PrefixLength)" : "disabled")")
        parts.append("routes=\(routeAllTraffic ? "default" : "split")")
        parts.append("excluded=\(excludedRoutes.count)")
        parts.append("dns=\(dnsServers.joined(separator: ","))")
        parts.append("udp=\(relayUDP ? "relay" : "off")")
        parts.append("credential=\(credentialDelivery.rawValue)")
        parts.append("mock=\(isMock)")
        return parts.joined(separator: " ")
    }

    // MARK: Provider-configuration marshalling

    public enum CodingError: Error, CustomStringConvertible {
        case missingPayload
        case unsupportedSchemaVersion(Int)
        case malformed(String)

        public var description: String {
            switch self {
            case .missingPayload:                        return "the VPN configuration has no ProxyTunnel payload"
            case .unsupportedSchemaVersion(let version): return "the VPN configuration was written by a newer version of the app (schema \(version))"
            case .malformed(let detail):                 return "the VPN configuration could not be decoded: \(detail)"
            }
        }
    }

    private static let payloadKey = "ProxyTunnelConfiguration"
    private static let schemaKey = "ProxyTunnelSchemaVersion"

    /// Encodes into the `[String: Any]` dictionary `NETunnelProviderProtocol`
    /// wants. Everything is stored as one JSON `Data` blob so that there is
    /// exactly one decoder and no plist type coercion surprises.
    public func providerConfiguration() throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        return [
            Self.payloadKey: data,
            Self.schemaKey: Self.currentSchemaVersion
        ]
    }

    public static func decode(providerConfiguration: [String: Any]) throws -> TunnelConfiguration {
        if let version = providerConfiguration[schemaKey] as? Int, version > currentSchemaVersion {
            throw CodingError.unsupportedSchemaVersion(version)
        }
        guard let data = providerConfiguration[payloadKey] as? Data else {
            throw CodingError.missingPayload
        }
        do {
            return try JSONDecoder().decode(TunnelConfiguration.self, from: data)
        } catch {
            throw CodingError.malformed("\(error)")
        }
    }
}

/// Addresses and defaults for the virtual interface.
public enum TunnelNetworkDefaults {

    /// The tunnel's own IPv4 address. `10.7.0.1` is inside the 10/8 private range
    /// and does not collide with the common `10.0.0.0/8` home-router or
    /// `192.168.0.0/16` ranges in a harmful way, because the tunnel takes the
    /// default route and supersedes them.
    public static let ipv4Address = "10.7.0.1"
    public static let ipv4SubnetMask = "255.255.255.0"

    /// A unique-local IPv6 address (RFC 4193) rather than a global one, so that
    /// nothing on the internet can ever route to it directly.
    public static let ipv6Address = "fd00:7:7:7::1"
    public static let ipv6PrefixLength = 64

    public static let mtu = 1500

    /// Default resolvers.
    ///
    /// These are *not* contacted directly: every query to port 53 is intercepted
    /// inside the tunnel and re-issued through the proxy. What matters is that
    /// they are unicast addresses of large public resolvers, so the queries are
    /// meaningful wherever the proxy's egress happens to be.
    public static let dnsServers = ["1.1.1.1", "1.0.0.1"]
}
