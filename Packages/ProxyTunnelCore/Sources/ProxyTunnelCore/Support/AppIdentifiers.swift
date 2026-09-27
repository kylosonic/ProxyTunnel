//
//  AppIdentifiers.swift
//  ProxyTunnelCore
//
//  Single source of truth for the bundle identifiers that tie the main app, the
//  Network Extension, and (optionally) the shared App Group container together.
//
//  Everything is derived from `Bundle.main.bundleIdentifier` at runtime so the
//  values stay correct no matter what bundle-ID prefix a particular build used.
//  In the extension process `Bundle.main` is the .appex, whose identifier is
//  always "<app bundle id>" + `extensionSuffix`.
//

import Foundation

public enum AppIdentifiers {

    /// Suffix appended to the main app's bundle identifier to form the packet
    /// tunnel provider's bundle identifier. Must match `project.yml`.
    public static let extensionSuffix = ".tunnel"

    /// Bundle identifier of the already-signed process we are running in.
    public static var currentBundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "io.github.kylosonic.proxytunnel"
    }

    /// Bundle identifier of the *containing application*.
    ///
    /// Works both from the app (returns its own id) and from the extension
    /// (strips the `.tunnel` suffix).
    public static var mainAppBundleIdentifier: String {
        let id = currentBundleIdentifier
        if id.hasSuffix(extensionSuffix) {
            return String(id.dropLast(extensionSuffix.count))
        }
        return id
    }

    /// Bundle identifier of the Network Extension that hosts the packet tunnel.
    ///
    /// ## Why this is discovered rather than computed
    ///
    /// Free-Apple-ID sideloading tools are documented as *rewriting* the bundle
    /// identifier of the app they install, because Apple refuses to let a free
    /// account register an App ID that already exists (for example one that
    /// belongs to an App Store app). When that happens, an app that assumed
    /// `<own id>.tunnel` would point `NETunnelProviderProtocol` at a bundle
    /// identifier that does not exist, and `saveToPreferences` would fail with a
    /// generic error.
    ///
    /// So we read the real identifier from the embedded `.appex` instead. The
    /// suffix is only a fallback for the case where the PlugIns directory cannot
    /// be enumerated.
    public static var tunnelProviderBundleIdentifier: String {
        if let discovered = discoveredExtensionBundleIdentifier() {
            return discovered
        }
        return mainAppBundleIdentifier + extensionSuffix
    }

    /// Reads `CFBundleIdentifier` from the first `.appex` inside the app bundle.
    public static func discoveredExtensionBundleIdentifier() -> String? {
        guard let pluginsURL = Bundle.main.builtInPlugInsURL,
              let contents = try? FileManager.default.contentsOfDirectory(
                at: pluginsURL,
                includingPropertiesForKeys: nil
              ) else {
            return nil
        }
        for plugin in contents where plugin.pathExtension == "appex" {
            guard let bundle = Bundle(url: plugin) else { continue }
            if let identifier = bundle.bundleIdentifier, !identifier.isEmpty {
                return identifier
            }
        }
        return nil
    }

    /// URL of the embedded packet tunnel extension, when present.
    public static var extensionBundleURL: URL? {
        guard let pluginsURL = Bundle.main.builtInPlugInsURL,
              let contents = try? FileManager.default.contentsOfDirectory(
                at: pluginsURL,
                includingPropertiesForKeys: nil
              ) else {
            return nil
        }
        return contents.first { $0.pathExtension == "appex" }
    }

    /// App Group identifier shared by the app and the extension.
    ///
    /// Using an App Group requires the `com.apple.security.application-groups`
    /// entitlement. When that entitlement is unavailable (for example when the
    /// app is re-signed with a free Apple ID) `SharedContainer` transparently
    /// falls back to passing the tunnel configuration inline in
    /// `NETunnelProviderProtocol.providerConfiguration`.
    public static var appGroupIdentifier: String {
        "group." + mainAppBundleIdentifier
    }

    /// Keychain service string used for every secret this app stores.
    public static var keychainService: String {
        mainAppBundleIdentifier + ".secrets"
    }
}
