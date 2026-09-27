//
//  AppEnvironment.swift
//  ProxyTunnel
//
//  The object graph for the app. Everything is created once, here, so there is
//  exactly one `ProfileStore`, one `DiagnosticLog` and one `TunnelController` for
//  the whole process.
//

import Foundation
import SwiftUI
import ProxyTunnelCore

@MainActor
final class AppEnvironment: ObservableObject {

    let log: DiagnosticLog
    let profileStore: ProfileStore
    let secrets: SecretStoring
    let tunnel: TunnelController
    let mock: MockTunnelSession

    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            AppSettingsStore.save(settings)
            log.info("settings", "settings updated: autoConnect=\(settings.autoConnectOnLaunch) ipv6=\(settings.allowIPv6) udp=\(settings.relayUDP) blockWhenDown=\(settings.blockTrafficWhenTunnelDown)")
        }
    }

    /// Cached so the Diagnostics screen does not re-read the bundle on every
    /// render.
    @Published private(set) var entitlements: EntitlementInspector.Report

    init(
        secrets: SecretStoring = SecretStoreProvider.current,
        log: DiagnosticLog = .shared
    ) {
        self.log = log
        self.secrets = secrets
        self.settings = AppSettingsStore.load()
        self.profileStore = ProfileStore.makeDefault(secrets: secrets, log: log)
        // Bind to a local first: reading a stored property back here would be a
        // use of `self` before every stored property is initialised.
        let report = EntitlementInspector.inspect()
        self.entitlements = report
        self.tunnel = TunnelController(log: log, entitlements: report)
        self.mock = MockTunnelSession()

        log.info("app", "ProxyTunnel \(AppVersion.displayString) started")
        log.info("app", "bundle id: \(AppIdentifiers.mainAppBundleIdentifier)")
        log.info("app", "app group available: \(SharedContainer.isAvailable)")
        log.info("app", "packet tunnel entitlement present: \(entitlements.extensionHasPacketTunnelEntitlement)")
        if entitlements.entitlementDefinitelyMissing {
            log.warning("app", "the tunnel extension lacks com.apple.developer.networking.networkextension; the VPN part of this app cannot run in this build")
        }
    }

    /// Called once from the root view's `.task`.
    func bootstrap() async {
        entitlements = EntitlementInspector.inspect()
        await tunnel.bootstrap()
        if settings.autoConnectOnLaunch, let profile = profileStore.selectedProfile,
           !settings.useMockMode {
            await startTunnel(profile: profile)
        }
    }

    func refreshEntitlements() {
        entitlements = EntitlementInspector.inspect()
        tunnel.updateEntitlementReport(entitlements)
    }

    // MARK: - Actions

    func startTunnel(profile: ProxyProfile) async {
        if settings.useMockMode {
            mock.start(profile: profile)
            return
        }
        await tunnel.connect(profile: profile, settings: settings) { [profileStore] profile in
            try profileStore.credential(for: profile)
        }
    }

    func stopTunnel() async {
        mock.stop()
        await tunnel.disconnect()
    }

    var isMockActive: Bool { settings.useMockMode && mock.isActive }
}

// MARK: - Version helpers

enum AppVersion {

    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    static var displayString: String {
        "\(shortVersion) (\(buildNumber))"
    }

    static var bundleIdentifier: String {
        AppIdentifiers.mainAppBundleIdentifier
    }

    static var extensionBundleIdentifier: String {
        AppIdentifiers.tunnelProviderBundleIdentifier
    }
}
