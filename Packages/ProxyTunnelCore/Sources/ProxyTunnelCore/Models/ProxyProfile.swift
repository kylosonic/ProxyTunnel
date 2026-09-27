//
//  ProxyProfile.swift
//  ProxyTunnelCore
//

import Foundation

/// A user-configured proxy.
///
/// ## Where the password lives
///
/// `ProxyProfile` deliberately does **not** contain a password field. It holds a
/// `passwordReference`, which is an opaque lookup key into the Keychain
/// (`SecretStoring`). The profile itself is plain metadata and is safe to encode
/// to disk, to include in diagnostics, and to print.
///
/// This split is what lets the app satisfy the "never store passwords in
/// UserDefaults / plain files / logs" requirement structurally rather than by
/// discipline: there is no property that *could* hold a secret.
public struct ProxyProfile: Identifiable, Codable, Hashable, Sendable {

    public var id: UUID

    /// Human-readable label shown in the UI, e.g. "ProxyCheap - Frankfurt".
    public var name: String

    /// Hostname, IPv4 literal or IPv6 literal. Stored exactly as the user typed
    /// it minus surrounding whitespace; sanitisation happens in the validator.
    public var host: String

    /// TCP port, 1...65535.
    public var port: Int

    /// Wire protocol. Encoded as `"protocol"` in JSON for readability.
    public var protocolType: ProxyProtocol

    /// Optional username. Not a secret on its own, but treated as sensitive for
    /// logging purposes.
    public var username: String?

    /// Opaque Keychain account key for the password. `nil` when the profile has
    /// no password (or when no credentials are required at all).
    public var passwordReference: String?

    /// Whether the profile is offered for selection on the main screen.
    public var isEnabled: Bool

    /// Marks a profile that only exists to exercise the UI. Mock profiles are
    /// labelled in the interface and are never presented as real connections.
    public var isMock: Bool

    /// Optional free-form note. Must not contain secrets; the UI warns about it.
    public var notes: String?

    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int,
        protocolType: ProxyProtocol,
        username: String? = nil,
        passwordReference: String? = nil,
        isEnabled: Bool = true,
        isMock: Bool = false,
        notes: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.protocolType = protocolType
        self.username = username
        self.passwordReference = passwordReference
        self.isEnabled = isEnabled
        self.isMock = isMock
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port
        case protocolType = "protocol"
        case username, passwordReference, isEnabled, isMock, notes
        case createdAt, updatedAt
    }

    // Tolerate profiles written by an older build that did not have `isMock`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try c.decode(String.self, forKey: .name)
        self.host = try c.decode(String.self, forKey: .host)
        self.port = try c.decode(Int.self, forKey: .port)
        self.protocolType = try c.decode(ProxyProtocol.self, forKey: .protocolType)
        self.username = try c.decodeIfPresent(String.self, forKey: .username)
        self.passwordReference = try c.decodeIfPresent(String.self, forKey: .passwordReference)
        self.isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.isMock = try c.decodeIfPresent(Bool.self, forKey: .isMock) ?? false
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes)
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

// MARK: - Derived values

extension ProxyProfile {

    /// `host:port`, with IPv6 literals bracketed so the result is unambiguous.
    public var displayEndpoint: String {
        Self.formatEndpoint(host: host, port: port)
    }

    /// Whether the profile carries (or claims to carry) credentials.
    public var usesAuthentication: Bool {
        guard let u = username, !u.isEmpty else { return false }
        return true
    }

    /// Keychain account key generated for a new profile.
    public static func makePasswordReference(for id: UUID) -> String {
        "proxy-password-" + id.uuidString
    }

    public static func formatEndpoint(host: String, port: Int) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(":") && !trimmed.hasPrefix("[") {
            return "[\(trimmed)]:\(port)"
        }
        return "\(trimmed):\(port)"
    }

    /// A redacted one-line summary that is safe to write to logs, to the
    /// diagnostics screen and to a bug report.
    public var redactedSummary: String {
        let user = LogRedactor.maskUsername(username)
        return "ProxyProfile(id: \(id.uuidString.prefix(8))…, "
            + "name: \"\(name)\", "
            + "endpoint: \(displayEndpoint), "
            + "protocol: \(protocolType.rawValue), "
            + "user: \(user), "
            + "hasPassword: \(passwordReference != nil), "
            + "enabled: \(isEnabled), mock: \(isMock))"
    }
}

extension ProxyProfile: CustomStringConvertible, CustomDebugStringConvertible {
    /// Both of these go through `redactedSummary`, so an accidental
    /// string-interpolation of a profile in a log statement cannot leak
    /// credentials.
    public var description: String { redactedSummary }
    public var debugDescription: String { redactedSummary }
}

// MARK: - Example data used in docs, previews and mock mode

extension ProxyProfile {

    /// A profile that points nowhere. Used by SwiftUI previews and by the
    /// "development / mock mode" toggle so the UI can be exercised without a
    /// real proxy. It is flagged `isMock` so every screen can label it.
    public static func mockProfile() -> ProxyProfile {
        ProxyProfile(
            name: "Mock Proxy (not real)",
            host: "example.proxy.com",
            port: 12345,
            protocolType: .socks5,
            username: "example-user",
            passwordReference: nil,
            isEnabled: true,
            isMock: true,
            notes: "Placeholder profile for development mode. No traffic is routed."
        )
    }
}
