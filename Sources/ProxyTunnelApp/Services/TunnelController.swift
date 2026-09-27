//
//  TunnelController.swift
//  ProxyTunnel
//
//  Owns the `NETunnelProviderManager` and is the single source of truth for the
//  connection state shown in the UI.
//
//  Design rules that this file follows, and that matter:
//
//   1. The UI never invents a state. `state` is derived from `NEVPNStatus` plus
//      the extension's own status payload.
//   2. A CONNECT tap really does create/refresh a VPN configuration and call
//      `startVPNTunnel()`. There is no code path that only changes a label.
//   3. Every failure is turned into a `TunnelFailure` with an actionable message.
//      Entitlement failures are detected explicitly and explained, because that
//      is the failure a free-Apple-ID install will hit.
//   4. Disconnecting temporarily clears the on-demand rule. Without that, an
//      "always connect" rule makes DISCONNECT appear to do nothing, which is a
//      genuinely confusing bug in a lot of VPN apps.
//

import Foundation
import NetworkExtension
import ProxyTunnelCore

@MainActor
final class TunnelController: ObservableObject {

    @Published private(set) var state: TunnelConnectionState = .disconnected
    @Published private(set) var status: TunnelStatusPayload?
    @Published private(set) var managerSummary: String = "No VPN configuration yet"
    @Published private(set) var entitlements: EntitlementInspector.Report
    @Published private(set) var lastFailure: TunnelFailure?

    /// Set when `saveToPreferences` or `startVPNTunnel` fails in a way that
    /// points at a missing entitlement, so the UI can show the dedicated panel.
    @Published private(set) var entitlementBlocked = false

    private let log: DiagnosticLog
    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var statusPollTask: Task<Void, Never>?
    private var connectedSince: Date?
    private var hasBootstrapped = false

    init(log: DiagnosticLog, entitlements: EntitlementInspector.Report) {
        self.log = log
        self.entitlements = entitlements
        self.entitlementBlocked = entitlements.entitlementDefinitelyMissing
        // NEVPNStatusDidChange is posted on an arbitrary queue; hop to the main
        // actor before touching published state.
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshStateFromVPN() }
        }
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        statusPollTask?.cancel()
    }

    func updateEntitlementReport(_ report: EntitlementInspector.Report) {
        entitlements = report
        entitlementBlocked = report.entitlementDefinitelyMissing
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        guard !hasBootstrapped else {
            await loadExistingConfiguration()
            return
        }
        hasBootstrapped = true
        await loadExistingConfiguration()
    }

    private func loadExistingConfiguration() async {
        do {
            let managers = try await Self.loadAllFromPreferences()
            manager = managers.first { manager in
                (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == AppIdentifiers.tunnelProviderBundleIdentifier
            }
            if let manager {
                managerSummary = describe(manager)
                log.info("vpn", "found an existing VPN configuration: \(managerSummary)")
            } else {
                managerSummary = "No VPN configuration yet — one is created the first time you tap CONNECT."
            }
            refreshStateFromVPN()
        } catch {
            let failure = mapVPNError(error, stage: .load)
            lastFailure = failure
            log.log(failure)
            managerSummary = "Could not read the VPN configurations: \(failure.title)"
        }
    }

    // MARK: - Connect

    /// Creates or refreshes the VPN configuration for `profile` and starts the
    /// tunnel.
    ///
    /// - Parameter credentialProvider: called to obtain the password. Kept as a
    ///   closure so the controller never has to hold a password in a stored
    ///   property.
    func connect(
        profile: ProxyProfile,
        settings: AppSettings,
        credentialProvider: (ProxyProfile) throws -> ProxyCredential?
    ) async {
        lastFailure = nil
        entitlementBlocked = entitlements.entitlementDefinitelyMissing

        // ---- 0. Fail loudly and early rather than pretending to connect ----
        if entitlements.entitlementDefinitelyMissing {
            let failure = TunnelFailure(
                kind: .missingEntitlement,
                title: "This build cannot start a VPN",
                message: "The packet tunnel extension was signed without the com.apple.developer.networking.networkextension entitlement, so iOS will not launch it.",
                recoverySuggestion: "See Diagnostics ▸ Signing & entitlements for the exact profile contents. You need a paid Apple Developer Program account to provision this entitlement.",
                underlyingDescription: entitlements.verdict,
                isRetryable: false
            )
            lastFailure = failure
            state = .failed(failure)
            log.log(failure)
            return
        }

        state = .connecting(startedAt: Date())
        connectedSince = Date()

        do {
            // ---- 1. Resolve the proxy *here*, where DNS still works ---------
            // The extension must never resolve the proxy's own name: inside the
            // tunnel there is no resolver until the tunnel is up.
            let addresses = try await HostResolver.resolveAsync(host: profile.host, port: profile.port)
            log.info("vpn", "resolved \(profile.host) -> \(addresses.joined(separator: ", "))")

            let credential = try credentialProvider(profile)
            let (configuration, delivery) = try makeConfiguration(
                profile: profile,
                settings: settings,
                credential: credential,
                resolvedAddresses: addresses
            )
            log.info("vpn", "credential delivery: \(delivery.rawValue)")

            // ---- 2. Build / update the VPN configuration -------------------
            let providerManager = try await prepareManager(
                profile: profile,
                configuration: configuration,
                settings: settings
            )
            manager = providerManager
            managerSummary = describe(providerManager)

            // ---- 3. Start it ----------------------------------------------
            providerManager.connection.startVPNTunnel()
            log.info("vpn", "startVPNTunnel() called")
            startStatusPolling()

        } catch let error as HostResolverError {
            fail(with: TunnelFailure(
                kind: .networkUnavailable,
                title: "Cannot resolve the proxy",
                message: "\(error)",
                recoverySuggestion: "Check the host name and make sure this iPhone has a working internet connection.",
                isRetryable: true
            ))
        } catch {
            fail(with: mapVPNError(error, stage: .start))
        }
    }

    /// Builds the `TunnelConfiguration` and decides how the password travels.
    private func makeConfiguration(
        profile: ProxyProfile,
        settings: AppSettings,
        credential: ProxyCredential?,
        resolvedAddresses: [String]
    ) throws -> (TunnelConfiguration, TunnelConfiguration.CredentialDelivery) {

        var delivery = TunnelConfiguration.CredentialDelivery.none
        var inlinePassword: String?

        if let credential {
            // The shared container is only useful if BOTH processes can see it.
            // We can check the extension's own provisioning profile, which is
            // exactly the information needed: if App Groups was stripped from the
            // extension, writing to the container would produce a tunnel that
            // starts and then fails to authenticate with no explanation.
            let extensionCanUseAppGroup = entitlements.extensionProfiles.isEmpty
                || entitlements.extensionProfiles.contains { $0.hasAppGroups }

            if SharedContainer.isAvailable && extensionCanUseAppGroup {
                do {
                    try SharedContainer.writeCredential(.init(
                        profileID: profile.id.uuidString,
                        username: credential.username,
                        password: credential.password
                    ))
                    delivery = .sharedContainer
                } catch {
                    log.warning("vpn", "could not write to the App Group container (\(error)); falling back to an inline credential")
                    inlinePassword = credential.password
                    delivery = .inlineProviderConfiguration
                }
            } else {
                inlinePassword = credential.password
                delivery = .inlineProviderConfiguration
                if !SharedContainer.isAvailable {
                    log.warning("vpn", "App Group container unavailable; the proxy password will be stored inline in the system VPN preferences")
                } else {
                    log.warning("vpn", "the extension's provisioning profile has no App Group, so the password will be passed inline")
                }
            }
        }

        let dnsValidation = DNSSettingsValidator.validate(settings.dnsServers)
        let dnsServers = dnsValidation.servers.isEmpty ? TunnelNetworkDefaults.dnsServers : dnsValidation.servers

        let configuration = TunnelConfiguration(
            profileID: profile.id.uuidString,
            profileName: profile.name,
            isMock: profile.isMock,
            host: profile.host,
            port: profile.port,
            protocolType: profile.protocolType,
            username: profile.username,
            inlinePassword: inlinePassword,
            resolvedProxyAddresses: resolvedAddresses,
            routeAllTraffic: true,
            excludedRoutes: [],
            dnsServers: dnsServers,
            relayUDP: settings.relayUDP,
            blockTrafficWhenTunnelDown: settings.blockTrafficWhenTunnelDown,
            allowIPv6: settings.allowIPv6,
            tracePackets: settings.tracePackets,
            idleTimeoutSeconds: settings.idleTimeoutSeconds,
            credentialDelivery: delivery
        )
        return (configuration, delivery)
    }

    private func prepareManager(
        profile: ProxyProfile,
        configuration: TunnelConfiguration,
        settings: AppSettings
    ) async throws -> NETunnelProviderManager {

        let providerManager: NETunnelProviderManager
        if let existing = manager {
            providerManager = existing
        } else {
            let managers = try await Self.loadAllFromPreferences()
            providerManager = managers.first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == AppIdentifiers.tunnelProviderBundleIdentifier
            } ?? NETunnelProviderManager()
        }

        let protocolConfiguration = NETunnelProviderProtocol()
        protocolConfiguration.providerBundleIdentifier = AppIdentifiers.tunnelProviderBundleIdentifier
        // `serverAddress` is what iOS shows in Settings ▸ VPN. There is no single
        // server address for a proxy tunnel, so the proxy endpoint is used.
        protocolConfiguration.serverAddress = profile.displayEndpoint
        protocolConfiguration.username = profile.username
        protocolConfiguration.providerConfiguration = try configuration.providerConfiguration()
        // Keep the tunnel alive across screen lock: a proxy tunnel is useless if
        // it drops whenever the phone sleeps.
        protocolConfiguration.disconnectOnSleep = false
        // Do not send the tunnel's own traffic through a cellular APN proxy.
        protocolConfiguration.enforceRoutes = true
        protocolConfiguration.excludeAPNs = false
        protocolConfiguration.excludeLocalNetworks = false

        providerManager.protocolConfiguration = protocolConfiguration
        providerManager.localizedDescription = "ProxyTunnel — \(profile.name)"
        providerManager.isEnabled = true

        // On-demand: iOS's own fail-closed behaviour. When enabled, iOS holds
        // traffic until the tunnel is up and re-establishes it after a drop.
        if settings.blockTrafficWhenTunnelDown {
            let rule = NEOnDemandRuleConnect()
            rule.interfaceTypeMatch = .any
            providerManager.onDemandRules = [rule]
            providerManager.isOnDemandEnabled = true
        } else {
            providerManager.onDemandRules = []
            providerManager.isOnDemandEnabled = false
        }

        try await Self.saveToPreferences(providerManager)
        // Apple requires a reload after saving before the configuration can be
        // started; skipping it produces `NEVPNError.configurationStale`.
        try await Self.loadFromPreferences(providerManager)
        return providerManager
    }

    // MARK: - Disconnect

    func disconnect() async {
        guard let manager else {
            state = .disconnected
            return
        }
        state = .disconnecting
        stopStatusPolling()

        // Clear on-demand first. An "always connect" rule would otherwise bring
        // the tunnel straight back up and the DISCONNECT button would look broken.
        if manager.isOnDemandEnabled {
            manager.isOnDemandEnabled = false
            manager.onDemandRules = []
            do {
                try await Self.saveToPreferences(manager)
                log.info("vpn", "on-demand disabled before disconnecting")
            } catch {
                log.warning("vpn", "could not disable on-demand: \(error)")
            }
        }

        manager.connection.stopVPNTunnel()
        log.info("vpn", "stopVPNTunnel() called")
        connectedSince = nil
        status = nil
        state = .disconnected
    }

    /// Removes the VPN configuration from the system entirely, including the
    /// credential left in the App Group container.
    func removeConfiguration() async {
        guard let manager else { return }
        do {
            try await Self.removeFromPreferences(manager)
            log.info("vpn", "VPN configuration removed")
        } catch {
            log.warning("vpn", "could not remove the VPN configuration: \(error)")
        }
        SharedContainer.deleteCredential()
        self.manager = nil
        managerSummary = "No VPN configuration yet"
        status = nil
        state = .disconnected
    }

    // MARK: - State

    private func refreshStateFromVPN() {
        guard let manager else {
            state = lastFailure.map { TunnelConnectionState.failed($0) } ?? .disconnected
            return
        }
        let statusValue = Self.map(manager.connection.status)
        state = TunnelConnectionState.from(
            vpnStatus: statusValue,
            profileName: nil,
            connectedSince: connectedSince,
            lastFailure: lastFailure,
            mockActive: false
        )
        switch statusValue {
        case .connected:
            startStatusPolling()
        case .disconnected, .invalid:
            stopStatusPolling()
        default:
            break
        }
    }

    private func fail(with failure: TunnelFailure) {
        lastFailure = failure
        state = .failed(failure)
        log.log(failure)
        if failure.kind == .missingEntitlement || failure.kind == .vpnConfigurationFailed {
            entitlementBlocked = entitlements.entitlementDefinitelyMissing
        }
    }

    // MARK: - Extension status polling

    private func startStatusPolling() {
        guard statusPollTask == nil else { return }
        statusPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchStatusOnce()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private func stopStatusPolling() {
        statusPollTask?.cancel()
        statusPollTask = nil
    }

    /// Asks the extension for a status snapshot. Fails silently when the tunnel
    /// is not running, because that is the normal case.
    @discardableResult
    func fetchStatusOnce() async -> TunnelStatusPayload? {
        guard let manager,
              let session = manager.connection as? NETunnelProviderSession,
              manager.connection.status == .connected || manager.connection.status == .reasserting else {
            return nil
        }
        do {
            let request = try TunnelMessageCodec.encode(TunnelRequestEnvelope(kind: .status))
            let responseData: Data = try await withCheckedThrowingContinuation { continuation in
                do {
                    try session.sendProviderMessage(request) { data in
                        if let data {
                            continuation.resume(returning: data)
                        } else {
                            continuation.resume(throwing: TunnelControllerError.emptyResponse)
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            let envelope = try TunnelMessageCodec.decodeResponse(responseData)
            if let payload = envelope.status {
                status = payload
                if let engineConnectedSince = payload.connectedSince, connectedSince == nil {
                    connectedSince = engineConnectedSince
                }
                if !payload.networkSettingsApplied, payload.engineState == "running" {
                    log.warning("vpn", "the extension is running but has not applied network settings yet")
                }
            }
            return envelope.status
        } catch {
            log.debug("vpn", "status request failed (this is normal while the tunnel is starting): \(error)")
            return nil
        }
    }

    func setTracePackets(_ enabled: Bool) async {
        guard let manager,
              let session = manager.connection as? NETunnelProviderSession,
              manager.connection.status == .connected else { return }
        guard let request = try? TunnelMessageCodec.encode(
            TunnelRequestEnvelope(kind: .setTracePackets, tracePackets: enabled)
        ) else { return }
        try? session.sendProviderMessage(request) { _ in }
    }

    // MARK: - Persistence wrappers

    private static func loadAllFromPreferences() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: managers ?? [])
                }
            }
        }
    }

    private static func saveToPreferences(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private static func loadFromPreferences(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private static func removeFromPreferences(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.removeFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private static func map(_ status: NEVPNStatus) -> NEVPNStatusValue {
        switch status {
        case .invalid:       return .invalid
        case .disconnected:  return .disconnected
        case .connecting:    return .connecting
        case .connected:     return .connected
        case .reasserting:   return .reasserting
        case .disconnecting: return .disconnecting
        @unknown default:    return .invalid
        }
    }

    private func describe(_ manager: NETunnelProviderManager) -> String {
        let statusText: String
        switch manager.connection.status {
        case .invalid:       statusText = "invalid"
        case .disconnected:  statusText = "disconnected"
        case .connecting:    statusText = "connecting"
        case .connected:     statusText = "connected"
        case .reasserting:   statusText = "reasserting"
        case .disconnecting: statusText = "disconnecting"
        @unknown default:    statusText = "unknown"
        }
        let provider = manager.protocolConfiguration as? NETunnelProviderProtocol
        return "“\(manager.localizedDescription ?? "ProxyTunnel")” · \(provider?.serverAddress ?? "?") · on-demand \(manager.isOnDemandEnabled ? "on" : "off") · iOS reports: \(statusText)"
    }

    // MARK: - Error mapping

    enum Stage { case load, save, start }

    private func mapVPNError(_ error: Error, stage: Stage) -> TunnelFailure {
        let nsError = error as NSError
        log.error("vpn", "\(stage) failed: \(nsError.domain) \(nsError.code) — \(nsError.localizedDescription)")

        if nsError.domain == NEVPNErrorDomain {
            // The numeric values come from Apple's shipped NEVPNManager.h:
            //   1 ConfigurationInvalid
            //   2 ConfigurationDisabled
            //   3 ConnectionFailed
            //   4 ConfigurationStale
            //   5 ConfigurationReadWriteFailed
            //   6 ConfigurationUnknown
            // Apple's documentation publishes the case names but not the numbers,
            // so they are spelled out here rather than relying on the Swift
            // constant names — several of which are easy to mix up (4 and 5 in
            // particular).
            switch nsError.code {
            case 1:
                return TunnelFailure(
                    kind: .vpnConfigurationFailed,
                    title: "iOS rejected the VPN configuration",
                    message: "The configuration is not valid. On a sideloaded build the usual cause is that the packet tunnel extension does not have the Network Extension entitlement, so iOS will not accept a tunnel pointing at it.",
                    recoverySuggestion: "Open Diagnostics ▸ Signing & entitlements to see what was actually signed. Provisioning the Network Extensions capability requires an Apple Developer Program membership.",
                    underlyingDescription: "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)",
                    isRetryable: false
                )

            case 2:
                return TunnelFailure(
                    kind: .vpnConfigurationFailed,
                    title: "The VPN configuration is disabled",
                    message: "iOS has this VPN configuration marked as disabled.",
                    recoverySuggestion: "Open Settings ▸ General ▸ VPN & Device Management, delete the ProxyTunnel configuration, then try again from the app.",
                    underlyingDescription: "\(nsError.domain) \(nsError.code)",
                    isRetryable: true
                )

            case 3:
                return TunnelFailure(
                    kind: .tunnelFailed,
                    title: "The tunnel failed to start",
                    message: "iOS could not bring the tunnel up.",
                    recoverySuggestion: "Check the log on the Diagnostics screen. If the extension started and then failed, its own log will say why.",
                    underlyingDescription: "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)",
                    isRetryable: true
                )

            case 4:
                return TunnelFailure(
                    kind: .vpnConfigurationFailed,
                    title: "The VPN configuration was out of date",
                    message: "The configuration changed between saving it and starting it.",
                    recoverySuggestion: "Tap CONNECT again — the app rewrites and reloads the configuration on every attempt.",
                    underlyingDescription: "\(nsError.domain) \(nsError.code)",
                    isRetryable: true
                )

            case 5:
                // This is the error developers actually report when the packet
                // tunnel entitlement is missing: NEVPNErrorDomain code 5 carrying
                // the text "permission denied". It never mentions entitlements,
                // which is exactly why this app inspects its own provisioning
                // profile and states the finding on the Diagnostics screen.
                return TunnelFailure(
                    kind: .missingEntitlement,
                    title: "iOS refused to save the VPN configuration (permission denied)",
                    message: "iOS would not write the tunnel configuration. On a build whose packet tunnel extension lacks the com.apple.developer.networking.networkextension entitlement this is the error you get — and the message iOS returns never says so.",
                    recoverySuggestion: entitlements.entitlementDefinitelyMissing
                        ? "Diagnostics ▸ Signing & entitlements confirms the entitlement is missing from this build. A working tunnel requires an Apple Developer Program membership."
                        : "Check Diagnostics ▸ Signing & entitlements, and make sure no other VPN app already holds the active VPN configuration on this device.",
                    underlyingDescription: "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)",
                    isRetryable: false
                )

            default:
                return TunnelFailure(
                    kind: .vpnConfigurationFailed,
                    title: "VPN configuration error",
                    message: "iOS reported a VPN configuration error (code \(nsError.code)).",
                    recoverySuggestion: "Delete the ProxyTunnel entry in Settings ▸ General ▸ VPN & Device Management and try again.",
                    underlyingDescription: "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)",
                    isRetryable: true
                )
            }
        }

        if nsError.domain == NSCocoaErrorDomain, nsError.code == 4097 || nsError.code == 4099 {
            return TunnelFailure(
                kind: .providerNotInstalled,
                title: "The tunnel extension is missing",
                message: "iOS could not find the packet tunnel extension inside this app bundle.",
                recoverySuggestion: "The IPA was probably built without the extension target. Re-download the artifact and check that Diagnostics lists an extension profile.",
                underlyingDescription: "\(nsError.domain) \(nsError.code)",
                isRetryable: false
            )
        }

        return TunnelFailure(
            kind: stage == .start ? .tunnelFailed : .vpnConfigurationFailed,
            title: stage == .start ? "Could not start the tunnel" : "VPN configuration failed",
            message: nsError.localizedDescription,
            recoverySuggestion: "Check the log on the Diagnostics screen for the underlying error.",
            underlyingDescription: "\(nsError.domain) \(nsError.code)",
            isRetryable: true
        )
    }
}

enum TunnelControllerError: Error, CustomStringConvertible {
    case emptyResponse

    var description: String {
        switch self {
        case .emptyResponse: return "the tunnel extension returned no data"
        }
    }
}
