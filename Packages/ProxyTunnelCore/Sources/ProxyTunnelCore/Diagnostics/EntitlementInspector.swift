//
//  EntitlementInspector.swift
//  ProxyTunnelCore
//
//  Answers, at runtime on the device, the only question that actually matters
//  for this project:
//
//      "Did the way this app was signed give the Network Extension the
//       entitlement it needs to start a Packet Tunnel Provider?"
//
//  ## How it works
//
//  A sideloaded app keeps its provisioning profile at
//  `<App>.app/embedded.mobileprovision`, and an app may read its own bundle. The
//  profile is a CMS SignedData blob whose payload is an ordinary XML property
//  list, in the clear. We therefore do not need any private API: read the file,
//  slice out the `<?xml … </plist>` region, and parse it.
//
//  The same is done for every `.appex` in the app's `PlugIns` directory, because
//  the entitlement that matters belongs to the *extension*, not to the host app.
//
//  ## What this is not
//
//  This is *not* a way to acquire entitlements. It only reads and reports what
//  the signature already contains, so that the app can tell the user the truth
//  instead of failing with `NEVPNErrorDomain error 1` and a shrug.
//

import Foundation

public enum EntitlementInspector {

    public static let networkExtensionKey = "com.apple.developer.networking.networkextension"
    public static let personalVPNKey = "com.apple.developer.networking.vpn.api"
    public static let appGroupsKey = "com.apple.security.application-groups"
    public static let packetTunnelValue = "packet-tunnel-provider"

    /// What a single provisioning profile grants.
    public struct ProfileSummary: Sendable, Equatable {
        public let path: String
        public let name: String?
        public let applicationIdentifier: String?
        public let teamIdentifier: [String]
        public let expirationDate: Date?
        public let creationDate: Date?
        public let provisionedDeviceCount: Int?
        public let entitlements: [String: [String]]
        /// Entitlement keys that are booleans rather than arrays (e.g. get-task-allow).
        public let booleanEntitlements: [String: Bool]

        public var hasNetworkExtension: Bool {
            guard let values = entitlements[networkExtensionKey] else { return false }
            return values.contains(packetTunnelValue)
        }

        public var networkExtensionValues: [String] {
            entitlements[networkExtensionKey] ?? []
        }

        public var hasPersonalVPN: Bool {
            entitlements[personalVPNKey]?.contains("allow-vpn") ?? false
        }

        public var hasAppGroups: Bool {
            !(entitlements[appGroupsKey] ?? []).isEmpty
        }

        public var isExpired: Bool {
            guard let expirationDate else { return false }
            return expirationDate < Date()
        }

        /// Apple's free "Personal Team" profiles expire after 7 days and are
        /// issued by a team whose name is the user's Apple ID. We can only infer
        /// this from the profile contents, so the heuristic is deliberately loose
        /// and labelled as an inference wherever it is shown.
        public var looksLikeFreeProvisioning: Bool {
            guard let expirationDate, let creationDate else { return false }
            let lifetime = expirationDate.timeIntervalSince(creationDate)
            return lifetime > 0 && lifetime <= 8 * 24 * 3600
        }

        public var summaryLines: [String] {
            var lines: [String] = []
            lines.append("Profile: \(name ?? "(unnamed)")")
            lines.append("Path: \(path)")
            if let applicationIdentifier {
                lines.append("App identifier: \(applicationIdentifier)")
            }
            if !teamIdentifier.isEmpty {
                lines.append("Team: \(teamIdentifier.joined(separator: ", "))")
            }
            if let creationDate, let expirationDate {
                lines.append("Validity: \(Self.dateFormatter.string(from: creationDate)) → \(Self.dateFormatter.string(from: expirationDate))")
            }
            if let provisionedDeviceCount {
                lines.append("Provisioned devices: \(provisionedDeviceCount)")
            }
            lines.append("\(networkExtensionKey): \(networkExtensionValues.isEmpty ? "ABSENT" : networkExtensionValues.joined(separator: ", "))")
            lines.append("\(personalVPNKey): \(hasPersonalVPN ? "allow-vpn" : "absent")")
            lines.append("\(appGroupsKey): \(hasAppGroups ? (entitlements[appGroupsKey] ?? []).joined(separator: ", ") : "absent")")
            if isExpired {
                lines.append("STATE: EXPIRED — re-sign and reinstall the app.")
            } else if looksLikeFreeProvisioning {
                lines.append("STATE: this profile has a short (≈7 day) lifetime, which is what free Apple ID provisioning produces. It must be renewed regularly.")
            }
            return lines
        }
    }

    /// The verdict for the whole app bundle.
    public struct Report: Sendable {
        public let appProfile: ProfileSummary?
        public let extensionProfiles: [ProfileSummary]
        public let appGroupIdentifier: String
        public let appGroupContainerAvailable: Bool
        public let problems: [String]

        /// The entitlement that decides whether a Packet Tunnel Provider may run.
        public var extensionHasPacketTunnelEntitlement: Bool {
            extensionProfiles.contains { $0.hasNetworkExtension }
        }

        /// `true` when we found a profile and it definitively lacks the
        /// entitlement. `false` when there is no profile to inspect (a
        /// distribution-signed build) — that is not the same thing.
        public var entitlementDefinitelyMissing: Bool {
            !extensionProfiles.isEmpty && !extensionHasPacketTunnelEntitlement
        }

        public var canStartPacketTunnel: Bool {
            // A build with no embedded profile was signed by Xcode with a real
            // developer account (or distributed through the App Store), and in
            // that case we cannot inspect it — assume it is fine and let the
            // actual start attempt be the judge.
            extensionProfiles.isEmpty || extensionHasPacketTunnelEntitlement
        }

        /// A blunt, user-facing verdict. Never optimistic.
        public var verdict: String {
            if entitlementDefinitelyMissing {
                return "The packet tunnel extension in this build does NOT have the \(networkExtensionKey) entitlement with the value \"\(packetTunnelValue)\". iOS will refuse to start it. The rest of the app (profile management, credential storage and the connectivity test) still works."
            }
            if extensionProfiles.isEmpty {
                return "No embedded provisioning profile was found. That is normal for an App Store or development-signed build; it means the entitlements cannot be inspected from inside the app."
            }
            if !appGroupContainerAvailable {
                return "The packet tunnel entitlement is present, but the App Group container is not available in this build, so the proxy password is passed inline in the VPN configuration instead of through the shared container."
            }
            return "The packet tunnel extension has the required entitlement and the App Group container is available."
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    // MARK: - Inspection

    public static func inspect() -> Report {
        var problems: [String] = []

        let appProfile = readProfile(at: Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision"))
            .map { summarise($0, path: "embedded.mobileprovision") }

        var extensionProfiles: [ProfileSummary] = []
        if let pluginsURL = Bundle.main.builtInPlugInsURL,
           let contents = try? FileManager.default.contentsOfDirectory(at: pluginsURL, includingPropertiesForKeys: nil) {
            for plugin in contents where plugin.pathExtension == "appex" {
                let profileURL = plugin.appendingPathComponent("embedded.mobileprovision")
                if let parsed = readProfile(at: profileURL) {
                    extensionProfiles.append(summarise(parsed, path: "\(plugin.lastPathComponent)/embedded.mobileprovision"))
                } else {
                    problems.append("No embedded provisioning profile inside \(plugin.lastPathComponent). Its entitlements cannot be inspected.")
                }
            }
        }
        if extensionProfiles.isEmpty && (Bundle.main.builtInPlugInsURL == nil) {
            problems.append("This app bundle contains no PlugIns directory, so the packet tunnel extension is missing entirely.")
        }

        return Report(
            appProfile: appProfile,
            extensionProfiles: extensionProfiles,
            appGroupIdentifier: AppIdentifiers.appGroupIdentifier,
            appGroupContainerAvailable: SharedContainer.isAvailable,
            problems: problems
        )
    }

    /// Parses a `.mobileprovision` file.
    static func readProfile(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let plistData = extractPlist(from: data) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let dictionary = plist as? [String: Any] else { return nil }
        return dictionary
    }

    /// Slices the XML property list out of the CMS container.
    static func extractPlist(from data: Data) -> Data? {
        guard let startRange = data.range(of: Data("<?xml".utf8)) else { return nil }
        guard let endRange = data.range(of: Data("</plist>".utf8), in: startRange.lowerBound..<data.endIndex) else {
            return nil
        }
        return data[startRange.lowerBound..<endRange.upperBound]
    }

    static func summarise(_ profile: [String: Any], path: String) -> ProfileSummary {
        let entitlements = profile["Entitlements"] as? [String: Any] ?? [:]

        var arrayEntitlements: [String: [String]] = [:]
        var booleanEntitlements: [String: Bool] = [:]
        for (key, value) in entitlements {
            if let array = value as? [String] {
                arrayEntitlements[key] = array
            } else if let bool = value as? Bool {
                booleanEntitlements[key] = bool
            } else if let string = value as? String {
                arrayEntitlements[key] = [string]
            }
        }

        let deviceCount = (profile["ProvisionedDevices"] as? [String])?.count

        return ProfileSummary(
            path: path,
            name: profile["Name"] as? String,
            applicationIdentifier: entitlements["application-identifier"] as? String,
            teamIdentifier: (profile["TeamIdentifier"] as? [String]) ?? [],
            expirationDate: profile["ExpirationDate"] as? Date,
            creationDate: profile["CreationDate"] as? Date,
            provisionedDeviceCount: deviceCount,
            entitlements: arrayEntitlements,
            booleanEntitlements: booleanEntitlements
        )
    }
}
