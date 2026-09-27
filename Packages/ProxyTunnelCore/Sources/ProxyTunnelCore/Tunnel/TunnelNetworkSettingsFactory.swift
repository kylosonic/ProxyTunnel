//
//  TunnelNetworkSettingsFactory.swift
//  ProxyTunnelCore
//
//  Builds the `NEPacketTunnelNetworkSettings` handed to iOS.
//
//  This is where the routing decisions live, and they are the difference between
//  a tunnel that works and one that either leaks or deadlocks:
//
//    * a default route in each enabled family pulls all traffic in;
//    * the proxy's own resolved addresses are punched *out* of the tunnel, or the
//      tunnel's transport would be routed back into itself;
//    * the tunnel's DNS servers point at resolvers that are themselves only
//      reachable through the proxy, and the engine answers them locally so no
//      query ever escapes on the physical interface.
//

import Foundation
import Network
import NetworkExtension

public enum TunnelNetworkSettingsFactory {

    /// What the factory produced, plus enough information for the diagnostics
    /// screen to explain the routing without re-deriving it.
    public struct BuiltSettings {
        public let settings: NEPacketTunnelNetworkSettings
        /// Everything that was added to `excludedRoutes`, for diagnostics.
        public let excludedNetworks: [IPNetwork]
        /// Anything that could not be parsed and was therefore skipped.
        public let warnings: [String]
        /// The value handed to `tunnelRemoteAddress`.
        public let tunnelRemoteAddress: String
    }

    /// Builds the settings.
    ///
    /// - Parameters:
    ///   - configuration: what the app asked for.
    ///   - additionallyExcludedAddresses: extra addresses to keep out of the
    ///     tunnel (used for a proxy address discovered after the tunnel started).
    public static func make(
        configuration: TunnelConfiguration,
        additionallyExcludedAddresses: [String] = []
    ) -> BuiltSettings {

        var warnings: [String] = []

        // ---------------------------------------------------------------- IPv4
        let ipv4 = NEIPv4Settings(
            addresses: [configuration.ipv4Address],
            subnetMasks: [configuration.ipv4SubnetMask]
        )
        if configuration.routeAllTraffic {
            ipv4.includedRoutes = [NEIPv4Route.default()]
        } else {
            // Split tunnel: only the destinations the app listed. Because the app
            // does not currently expose a route editor, this is equivalent to
            // "no routes", which captures nothing — that is intentional and is
            // spelled out in the UI rather than silently meaning something else.
            ipv4.includedRoutes = []
        }

        var excluded: [IPNetwork] = []
        var excludedRoutes: [NEIPv4Route] = []

        // The addresses the proxy resolved to must bypass the tunnel.
        var proxyAddressesToExclude = configuration.resolvedProxyAddresses
        proxyAddressesToExclude.append(contentsOf: additionallyExcludedAddresses)
        for text in proxyAddressesToExclude {
            guard let address = IPAddress(presentationName: text) else {
                warnings.append("could not parse the proxy address \"\(text)\"")
                continue
            }
            guard address.isIPv4 else { continue }   // handled in the IPv6 block
            let network = IPNetwork.hostRoute(address)
            excluded.append(network)
            excludedRoutes.append(NEVIPv4Route(
                destinationAddress: address.description,
                subnetMask: "255.255.255.255"
            ))
        }

        for cidr in configuration.excludedRoutes {
            guard let network = IPNetwork(cidr: cidr), network.address.isIPv4 else {
                warnings.append("could not parse the excluded route \"\(cidr)\"")
                continue
            }
            excluded.append(network)
            excludedRoutes.append(NEVIPv4Route(
                destinationAddress: network.address.description,
                subnetMask: Self.subnetMask(prefixLength: network.prefixLength)
            ))
        }

        ipv4.excludedRoutes = excludedRoutes

        // `tunnelRemoteAddress` is informational — iOS does not route anything to
        // it — but it must be an address literal. Prefer a real resolved proxy
        // address; fall back to TEST-NET-1 (RFC 5737), which is guaranteed never
        // to be a real host.
        let remoteAddress = configuration.resolvedProxyAddresses
            .first(where: { IPAddress(presentationName: $0) != nil }) ?? "192.0.2.1"

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddress)
        settings.ipv4Settings = ipv4

        // ---------------------------------------------------------------- IPv6
        if configuration.allowIPv6 {
            let ipv6 = NEIPv6Settings(
                addresses: [configuration.ipv6Address],
                networkPrefixLengths: [NSNumber(value: configuration.ipv6PrefixLength)]
            )
            ipv6.includedRoutes = configuration.routeAllTraffic ? [NEIPv6Route.default()] : []

            var ipv6Excluded: [NEIPv6Route] = []
            for text in proxyAddressesToExclude {
                guard let address = IPAddress(presentationName: text), address.isIPv6 else { continue }
                let network = IPNetwork.hostRoute(address)
                excluded.append(network)
                ipv6Excluded.append(NEVIPv6Route(
                    destinationAddress: address.description,
                    networkPrefixLength: NSNumber(value: 128)
                ))
            }
            for cidr in configuration.excludedRoutes {
                guard let network = IPNetwork(cidr: cidr), network.address.isIPv6 else { continue }
                excluded.append(network)
                ipv6Excluded.append(NEVIPv6Route(
                    destinationAddress: network.address.description,
                    networkPrefixLength: NSNumber(value: network.prefixLength)
                ))
            }
            ipv6.excludedRoutes = ipv6Excluded
            settings.ipv6Settings = ipv6
        } else {
            // No IPv6 settings means iOS will not route IPv6 into the tunnel.
            // That is a deliberate choice and it is reported as a leak risk in the
            // diagnostics screen: on an IPv6-only carrier network there would be
            // no connectivity at all, and on a dual-stack network IPv6 traffic
            // takes the physical path.
            warnings.append("IPv6 is disabled: IPv6 traffic will NOT go through the proxy.")
        }

        // ----------------------------------------------------------------- DNS
        let dnsServers = configuration.dnsServers.filter { !$0.isEmpty }
        if dnsServers.isEmpty {
            warnings.append("no DNS servers configured")
        } else {
            let dns = NEDNSSettings(servers: dnsServers)
            // An empty-string match domain makes this the *default* resolver for
            // every name, which is what stops iOS from falling back to a resolver
            // learned from the physical network.
            dns.matchDomains = [""]
            settings.dnsSettings = dns
            // Deliberately NOT setting `supplementalMatchDomains`: we want no
            // second resolver anywhere.
        }

        // ---------------------------------------------------------------- MTU
        settings.mtu = NSNumber(value: configuration.mtu)

        return BuiltSettings(
            settings: settings,
            excludedNetworks: excluded,
            warnings: warnings,
            tunnelRemoteAddress: remoteAddress
        )
    }

    /// Dotted-quad subnet mask for a prefix length.
    public static func subnetMask(prefixLength: Int) -> String {
        let clamped = max(0, min(32, prefixLength))
        var value: UInt32 = 0
        if clamped > 0 {
            value = ~UInt32(0) << (32 - clamped)
        }
        return [
            (value >> 24) & 0xFF,
            (value >> 16) & 0xFF,
            (value >> 8) & 0xFF,
            value & 0xFF
        ].map(String.init).joined(separator: ".")
    }

    /// A full description of what the settings do, shown on the Diagnostics
    /// screen so the user can verify the routing rather than trust it.
    public static func describe(_ result: BuiltSettings) -> [String] {
        var lines: [String] = []
        lines.append("Tunnel remote address (informational): \(result.tunnelRemoteAddress)")
        if let ipv4 = result.settings.ipv4Settings {
            lines.append("IPv4 addresses: \(ipv4.addresses.joined(separator: ", ")) masks \(ipv4.subnetMasks.joined(separator: ", "))")
            let included = ipv4.includedRoutes.map { "\($0.destinationAddress)/\($0.destinationSubnetMask)" }
            lines.append("IPv4 included routes: \(included.isEmpty ? "(none)" : included.joined(separator: ", "))")
            let excludedRoutes = ipv4.excludedRoutes.map { "\($0.destinationAddress)/\($0.destinationSubnetMask)" }
            lines.append("IPv4 excluded routes: \(excludedRoutes.isEmpty ? "(none)" : excludedRoutes.joined(separator: ", "))")
        }
        if let ipv6 = result.settings.ipv6Settings {
            lines.append("IPv6 addresses: \(ipv6.addresses.joined(separator: ", "))")
            let included = ipv6.includedRoutes.map { "\($0.destinationAddress)/\($0.networkPrefixLength)" }
            lines.append("IPv6 included routes: \(included.isEmpty ? "(none)" : included.joined(separator: ", "))")
            let excludedRoutes = ipv6.excludedRoutes.map { "\($0.destinationAddress)/\($0.networkPrefixLength)" }
            lines.append("IPv6 excluded routes: \(excludedRoutes.isEmpty ? "(none)" : excludedRoutes.joined(separator: ", "))")
        } else {
            lines.append("IPv6: not routed into the tunnel")
        }
        if let dns = result.settings.dnsSettings {
            lines.append("DNS servers: \(dns.servers.joined(separator: ", ")) matchDomains=\(dns.matchDomains ?? [])")
        }
        if let mtu = result.settings.mtu {
            lines.append("MTU: \(mtu)")
        }
        for warning in result.warnings {
            lines.append("WARNING: \(warning)")
        }
        return lines
    }
}
