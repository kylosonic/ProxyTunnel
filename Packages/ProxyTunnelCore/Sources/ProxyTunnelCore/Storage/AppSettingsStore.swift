//
//  AppSettingsStore.swift
//  ProxyTunnelCore
//

import Foundation

/// Everything on the Settings screen.
public struct AppSettings: Codable, Equatable, Sendable {

    public var schemaVersion: Int

    // ---- Connection --------------------------------------------------------
    /// Start the tunnel automatically when the app is launched and a proxy is
    /// selected. iOS shows the VPN consent prompt the first time.
    public var autoConnectOnLaunch: Bool

    /// Install an on-demand rule that tells iOS to re-establish the tunnel
    /// whenever it drops, and to hold traffic until it is back.
    ///
    /// This is iOS's own fail-closed behaviour for on-demand VPN, not a firewall
    /// written by this app. See docs/ARCHITECTURE.md for exactly what it does and
    /// does not guarantee.
    public var blockTrafficWhenTunnelDown: Bool

    /// Route IPv6 into the tunnel. Turning this off means IPv6 traffic takes the
    /// physical path — faster on some networks, but it is a leak, and the
    /// diagnostics screen says so.
    public var allowIPv6: Bool

    // ---- DNS ---------------------------------------------------------------
    /// Resolvers advertised to iOS. Every query is intercepted in the tunnel and
    /// re-issued through the proxy, so these addresses are never contacted
    /// directly by the device.
    public var dnsServers: [String]

    // ---- Transport ---------------------------------------------------------
    /// Use the SOCKS5 UDP association to carry UDP other than DNS. Only
    /// meaningful for SOCKS5.
    public var relayUDP: Bool

    /// Connection idle timeout, in seconds.
    public var idleTimeoutSeconds: Int

    // ---- Diagnostics -------------------------------------------------------
    /// Write a line for every packet to the log. Extremely noisy.
    public var tracePackets: Bool

    /// Host used by the "Test connection" probe.
    public var probeHost: String
    public var probePath: String

    /// Replace the VPN connection with a clearly-labelled simulation.
    ///
    /// Exists so the interface can be exercised on a build where the packet
    /// tunnel extension cannot run. It never routes traffic and never reports a
    /// real connection; see `MockTunnelSession` in the app target.
    public var useMockMode: Bool

    public init() {
        self.schemaVersion = 1
        self.autoConnectOnLaunch = false
        self.blockTrafficWhenTunnelDown = false
        self.allowIPv6 = true
        self.dnsServers = TunnelNetworkDefaults.dnsServers
        self.relayUDP = true
        self.idleTimeoutSeconds = 1800
        self.tracePackets = false
        self.probeHost = "api.ipify.org"
        self.probePath = "/"
        self.useMockMode = false
    }

    /// True when IPv6 traffic is deliberately left outside the tunnel.
    public var hasIPv6LeakByDesign: Bool { !allowIPv6 }

    public var dnsSummary: String {
        dnsServers.isEmpty ? "none (DNS will fail)" : dnsServers.joined(separator: ", ")
    }
}

public enum AppSettingsStore {

    public static func fileURL() -> URL {
        ProfileStore.defaultDirectory().appendingPathComponent("settings.json")
    }

    public static func load(from url: URL = AppSettingsStore.fileURL()) -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    public static func save(_ settings: AppSettings, to url: URL = AppSettingsStore.fileURL()) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // Settings contain no secrets, so ordinary file protection is right.
            try encoder.encode(settings).write(to: url, options: .atomic)
        } catch {
            // Settings are not important enough to surface a failure: the app
            // falls back to defaults on the next launch.
        }
    }
}

/// Validates the DNS field on the Settings screen.
public enum DNSSettingsValidator {

    public struct Result: Equatable, Sendable {
        public let servers: [String]
        public let issues: [ValidationIssue]

        public var isValid: Bool { !issues.contains { $0.severity == .error } }
    }

    public static func validate(_ raw: [String]) -> Result {
        var issues: [ValidationIssue] = []
        var servers: [String] = []

        for entry in raw {
            let text = Sanitizer.clean(entry)
            if text.isEmpty { continue }
            if let address = IPAddress(presentationName: text) {
                if address.isMulticast || address.isUnspecified {
                    issues.append(.error(.general, "\"\(text)\" is not a usable DNS server address."))
                    continue
                }
                if !servers.contains(address.description) {
                    servers.append(address.description)
                }
            } else {
                issues.append(.error(
                    .general,
                    "\"\(text)\" is not an IP address. Enter a resolver's address, for example 1.1.1.1."
                ))
            }
        }

        if servers.isEmpty {
            issues.append(.warning(
                .general,
                "No DNS servers configured. Name resolution inside the tunnel will fail; apps will report \"cannot find server\"."
            ))
        }
        for server in servers where IPAddress(presentationName: server)?.isIPv6 == true {
            issues.append(.warning(
                .general,
                "\(server) is an IPv6 resolver. It only works if the proxy can reach IPv6 addresses."
            ))
        }

        return Result(servers: servers, issues: issues)
    }

    /// Turns the "one entry per line" text field into an array.
    public static func split(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " })
            .map { Sanitizer.clean(String($0)) }
            .filter { !$0.isEmpty }
    }
}
