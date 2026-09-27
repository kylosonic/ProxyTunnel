//
//  SharedContainer.swift
//  ProxyTunnelCore
//
//  The App Group container, when the app has been signed with an entitlement
//  that grants one.
//
//  ## Why this is optional
//
//  The Network Extension needs the proxy password. There are three ways to get it
//  there, and they are not equally good:
//
//  1. **Shared Keychain access group** — best, but needs the
//     `keychain-access-groups` entitlement AND the same team identifier on both
//     processes.
//  2. **App Group container** — good, needs `com.apple.security.application-groups`.
//  3. **Inline in `NETunnelProviderProtocol.providerConfiguration`** — always
//     works, but iOS persists that dictionary in the system VPN preferences,
//     outside the app sandbox and without the app's data protection key.
//
//  This type implements (2) and reports honestly whether it is available, so the
//  rest of the app can fall back to (3) and *tell the user which one is in use*.
//

import Foundation

public enum SharedContainer {

    /// `nil` when the process has no App Group container.
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroupIdentifier)
    }

    /// Whether the App Group entitlement survived code signing.
    ///
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` returns `nil` (and
    /// logs a warning) when the entitlement is absent, which is exactly the
    /// signal we need. It never throws and never crashes.
    public static var isAvailable: Bool {
        containerURL != nil
    }

    /// Human-readable explanation used by the Diagnostics screen.
    public static var statusDescription: String {
        if isAvailable {
            return "App Group \(AppIdentifiers.appGroupIdentifier) is available; the tunnel credential is passed through the shared container."
        }
        return "App Group \(AppIdentifiers.appGroupIdentifier) is NOT available in this build. The proxy password is passed inline in the VPN configuration instead, which iOS stores unencrypted in the system VPN preferences. See docs/ENTITLEMENTS-AND-SIGNING.md."
    }

    private static let credentialFileName = "tunnel-credential.json"
    private static let configurationFileName = "tunnel-configuration.json"

    /// A credential plus the profile it belongs to, written by the app and read
    /// by the extension.
    public struct CredentialRecord: Codable, Equatable, Sendable {
        public let profileID: String
        public let username: String
        public let password: String
        public let writtenAt: Date

        public init(profileID: String, username: String, password: String, writtenAt: Date = Date()) {
            self.profileID = profileID
            self.username = username
            self.password = password
            self.writtenAt = writtenAt
        }
    }

    // MARK: Writing (main app)

    /// Stores the credential in the shared container, readable only by this app
    /// group while the device has been unlocked at least once since boot.
    ///
    /// - Throws: `SharedContainerError.unavailable` when there is no container.
    public static func writeCredential(_ record: CredentialRecord) throws {
        guard let url = containerURL else { throw SharedContainerError.unavailable }
        let data = try JSONEncoder().encode(record)
        try data.write(to: url.appendingPathComponent(credentialFileName), options: [.atomic, .completeFileProtection])
    }

    /// Removes the shared credential. Called when the profile is deleted or the
    /// tunnel is torn down permanently.
    public static func deleteCredential() {
        guard let url = containerURL else { return }
        try? FileManager.default.removeItem(at: url.appendingPathComponent(credentialFileName))
    }

    // MARK: Reading (extension)

    /// Reads the credential for `profileID`, or `nil` when there is none.
    public static func readCredential(for profileID: String) -> CredentialRecord? {
        guard let url = containerURL else { return nil }
        guard let data = try? Data(contentsOf: url.appendingPathComponent(credentialFileName)) else { return nil }
        guard let record = try? JSONDecoder().decode(CredentialRecord.self, from: data) else { return nil }
        // Guard against a stale record from a previously selected profile.
        guard record.profileID == profileID else { return nil }
        return record
    }

    public static func deleteCredentialIfStale(except profileID: String) {
        guard let url = containerURL else { return }
        guard let data = try? Data(contentsOf: url.appendingPathComponent(credentialFileName)),
              let record = try? JSONDecoder().decode(CredentialRecord.self, from: data) else { return }
        if record.profileID != profileID {
            try? FileManager.default.removeItem(at: url.appendingPathComponent(credentialFileName))
        }
    }

    // MARK: Extension → app log mirroring

    /// The extension mirrors its diagnostics into the shared container so the
    /// main app's Logs screen can show what the tunnel did. Without an App Group
    /// the extension's log is only reachable through Console.app.
    public static func writeExtensionLog(_ text: String) {
        guard let url = containerURL else { return }
        try? Data(text.utf8).write(to: url.appendingPathComponent("extension-log.txt"), options: .atomic)
    }

    public static func readExtensionLog() -> String? {
        guard let url = containerURL else { return nil }
        guard let data = try? Data(contentsOf: url.appendingPathComponent("extension-log.txt")) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func clearExtensionLog() {
        guard let url = containerURL else { return }
        try? FileManager.default.removeItem(at: url.appendingPathComponent("extension-log.txt"))
    }
}

public enum SharedContainerError: Error, CustomStringConvertible {
    case unavailable

    public var description: String {
        "The App Group container is not available; the app is signed without the com.apple.security.application-groups entitlement."
    }
}
