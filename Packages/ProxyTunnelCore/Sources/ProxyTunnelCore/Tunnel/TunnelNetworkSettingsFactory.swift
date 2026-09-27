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
//  Everything the factory decided is copied into `BuiltSettings`, so the
//  diagnostics screen can report the routing without reading it back out of the
//  NetworkExtension objects.
//

import Foundation
import Network
import NetworkExtension

public enum TunnelNetworkSettingsFactory {

    /// What the factory produced, plus enough information for the diagnostics
    /// screen to explain the routing without re-deriving it.
    public struct BuiltSettings {
        public let settings: NEPacketTunnelNetworkSettings
        /// The value handed to `tunnelRemoteAddress`.
        public let tunnelRemoteAddress: String

        public let ipv4Address: String
        public let ipv4SubnetMask: String
        public let ipv4IncludedRoutes: [String]
        public let ipv4ExcludedRoutes: [String]

        public let ipv6Address: String?
        public let ipv6PrefixLength: Int?
        public let ipv6IncludedRoutes: [String]
        public let ipv6ExcludedRoutes: [String]

        public let dnsServers: [String]
        public let mtu: Int

        /// Everything that was added to `excludedRoutes`, for diagnostics.
        public let excludedNetworks: [IPNetwork]
        /// Anything that could not be parsed and was therefore skipped.
        public let warnings: [String]
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
        var excludedNetworks: [IPNetwork] = []

        // Which addresses must never be routed into the tunnel: the proxy's own.
        var proxyAddressesToExclude = configuration.resolvedProxyAddresses
        proxyAddressesToExclude.append(contentsOf: additionallyExcludedAddresses)
        for text in proxyAddressesToExclude where IPAddress(presentationName: text) == nil {
            warnings.append("could not parse the proxy address \"\(text)\"")
        }

        // ---------------------------------------------------------------- IPv4
        let ipv4 = NEIPv4Settings(
            addresses: [configuration.ipv4Address],
            subnetMasks: [configuration.ipv4SubnetMask]
        )

        var ipv4IncludedDescriptions: [String] = []
        if configuration.routeAllTraffic {
            ipv4.includedRoutes = [NEIPv4Route.default()]
            ipv4IncludedDescriptions = ["0.0.0.0/0"]
        } else {
            // Split tunnel: only the destinations the app listed. The app does not
            // currently expose a route editor, so this captures nothing — which is
            // stated in the UI rather than silently meaning something else.
            ipv4.includedRoutes = []
        }

        var ipv4Routes: [NEIPv4Route] = []
        var ipv4ExcludedDescriptions: [String] = []

        for text in proxyAddressesToExclude {
            guard let address = IPAddress(presentationName: text), address.isIPv4 else { continue }
            excludedNetworks.append(IPNetwork.hostRoute(address))
            ipv4Routes.append(NEIPv4Route(destinationAddress: address.description, subnetMask: "255.255.255.255"))
            ipv4ExcludedDescriptions.append("\(address.description)/32")
        }
        for cidr in configuration.excludedRoutes {
            guard let network = IPNetwork(cidr: cidr), network.address.isIPv4 else {
                if IPAddress(presentationName: String(cidr.split(separator: "/").first ?? ""))?.isIPv4 == true {
                    warnings.append("could not parse the excluded route \"\(cidr)\"")
                }
                continue
            }
            excludedNetworks.append(network)
            ipv4Routes.append(NEIPv4Route(
                destinationAddress: network.address.description,
                subnetMask: subnetMask(prefixLength: network.prefixLength)
            ))
            ipv4ExcludedDescriptions.append(network.cidr)
        }

        ipv4.excludedRoutes = ipv4Routes

        // `tunnelRemoteAddress` is informational — iOS does not route anything to
        // it — but it must be an address literal. Prefer a real resolved proxy
        // address; fall back to TEST-NET-1 (RFC 5737), which is guaranteed never
        // to be a real host.
        let remoteAddress = configuration.resolvedProxyAddresses
            .first(where: { IPAddress(presentationName: $0) != nil }) ?? "192.0.2.1"

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddress)
        settings.ipv4Settings = ipv4

        // ---------------------------------------------------------------- IPv6
        var ipv6IncludedDescriptions: [String] = []
        var ipv6ExcludedDescriptions: [String] = []

        if configuration.allowIPv6 {
            let ipv6 = NEIPv6Settings(
                addresses: [configuration.ipv6Address],
                networkPrefixLengths: [NSNumber(value: configuration.ipv6PrefixLength)]
            )
            if configuration.routeAllTraffic {
                ipv6.includedRoutes = [NEIPv6Route.default()]
                ipv6IncludedDescriptions = ["::/0"]
            } else {
                ipv6.includedRoutes = []
            }

            var ipv6Routes: [NEIPv6Route] = []
            for text in proxyAddressesToExclude {
                guard let address = IPAddress(presentationName: text), address.isIPv6 else { continue }
                excludedNetworks.append(IPNetwork.hostRoute(address))
                ipv6Routes.append(NEIPv6Route(
                    destinationAddress: address.description,
                    networkPrefixLength: NSNumber(value: 128)
                ))
                ipv6ExcludedDescriptions.append("\(address.description)/128")
            }
            for cidr in configuration.excludedRoutes {
                guard let network = IPNetwork(cidr: cidr), network.address.isIPv6 else { continue }
                excludedNetworks.append(network)
                ipv6Routes.append(NEIPv6Route(
                    destinationAddress: network.address.description,
                    networkPrefixLength: NSNumber(value: network.prefixLength)
                ))
                ipv6ExcludedDescriptions.append(network.cidr)
            }
            ipv6.excludedRoutes = ipv6Routes
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
            tunnelRemoteAddress: remoteAddress,
            ipv4Address: configuration.ipv4Address,
            ipv4SubnetMask: configuration.ipv4SubnetMask,
            ipv4IncludedRoutes: ipv4IncludedDescriptions,
            ipv4ExcludedRoutes: ipv4ExcludedDescriptions,
            ipv6Address: configuration.allowIPv6 ? configuration.ipv6Address : nil,
            ipv6PrefixLength: configuration.allowIPv6 ? configuration.ipv6PrefixLength : nil,
            ipv6IncludedRoutes: ipv6IncludedDescriptions,
            ipv6ExcludedRoutes: ipv6ExcludedDescriptions,
            dnsServers: dnsServers,
            mtu: configuration.mtu,
            excludedNetworks: excludedNetworks,
            warnings: warnings
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
        lines.append("IPv4 addresses: \(result.ipv4Address) mask \(result.ipv4SubnetMask)")
        lines.append("IPv4 included routes: \(result.ipv4IncludedRoutes.isEmpty ? "(none)" : result.ipv4IncludedRoutes.joined(separator: ", "))")
        lines.append("IPv4 excluded routes: \(result.ipv4ExcludedRoutes.isEmpty ? "(none)" : result.ipv4ExcludedRoutes.joined(separator: ", "))")

        if let ipv6Address = result.ipv6Address, let prefix = result.ipv6PrefixLength {
            lines.append("IPv6 addresses: \(ipv6Address)/\(prefix)")
            lines.append("IPv6 included routes: \(result.ipv6IncludedRoutes.isEmpty ? "(none)" : result.ipv6IncludedRoutes.joined(separator: ", "))")
            lines.append("IPv6 excluded routes: \(result.ipv6ExcludedRoutes.isEmpty ? "(none)" : result.ipv6ExcludedRoutes.joined(separator: ", "))")
        } else {
            lines.append("IPv6: not routed into the tunnel")
        }

        lines.append("DNS servers: \(result.dnsServers.isEmpty ? "(none)" : result.dnsServers.joined(separator: ", ")) (default resolver for all domains)")
        lines.append("MTU: \(result.mtu)")

        for warning in result.warnings {
            lines.append("WARNING: \(warning)")
        }
        return lines
    }
}
