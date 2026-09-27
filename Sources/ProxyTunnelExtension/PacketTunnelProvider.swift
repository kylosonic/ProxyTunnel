//
//  PacketTunnelProvider.swift
//  ProxyTunnelExtension
//
//  The Network Extension entry point.
//
//  Lifecycle:
//
//    startTunnel(options:)
//        1. decode the TunnelConfiguration the app put in providerConfiguration
//        2. obtain the proxy credential (shared container, or inline)
//        3. build NEPacketTunnelNetworkSettings — routes, DNS, MTU
//        4. setTunnelNetworkSettings(...)   ← this is what installs the routes
//        5. create and start TunnelEngine, which begins reading packets
//
//    stopTunnel(with:)
//        stop the engine, drop the credential, complete
//
//  The ordering in step 4 before step 5 is not negotiable: reading packets before
//  the settings are applied yields a flow that is not yet attached to anything,
//  and the tunnel appears to run while carrying nothing.
//

import Foundation
import Network
import NetworkExtension
import ProxyTunnelCore

final class PacketTunnelProvider: NEPacketTunnelProvider {

    /// Everything the engine touches runs on this queue. See `TunnelEngine` for
    /// why a single serial queue is the whole concurrency design.
    private let engineQueue = DispatchQueue(label: "io.github.kylosonic.proxytunnel.engine", qos: .userInitiated)

    private let log = DiagnosticLog.extensionLog

    private var configuration: TunnelConfiguration?
    private var credential: ProxyCredential?
    private var engine: TunnelEngine?
    private var interfaceResolver: PhysicalInterfaceResolver?
    private var logMirror: ExtensionLogMirror?
    private var isStopping = false

    // MARK: - Start

    /// - Note: the options dictionary is `[String: NSObject]?` in the SDK, not
    ///   `[String: Any]?`. Getting that wrong produces the confusing error
    ///   "method does not override any method from its superclass".
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        log.info("provider", "startTunnel called")

        // Mirror the log into the App Group container so the main app can show it.
        let mirror = ExtensionLogMirror(log: log)
        mirror.start()
        logMirror = mirror

        // Any failure here must still call the completion handler exactly once, or
        // iOS will sit on "Connecting…" until it gives up.
        var hasCompleted = false
        func complete(_ error: Error?) {
            guard !hasCompleted else { return }
            hasCompleted = true
            completionHandler(error)
        }

        let providerConfiguration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]

        let configuration: TunnelConfiguration
        do {
            configuration = try TunnelConfiguration.decode(providerConfiguration: providerConfiguration)
        } catch {
            let failure = TunnelFailure(
                kind: .vpnConfigurationFailed,
                title: "Bad tunnel configuration",
                message: "The extension could not read the configuration the app saved.",
                recoverySuggestion: "Reconnect from the app so the configuration is rewritten.",
                underlyingDescription: "\(error)"
            )
            log.log(failure)
            complete(failure)
            return
        }
        self.configuration = configuration
        log.info("provider", "configuration: \(configuration.redactedSummary)")

        // ---- Credential ------------------------------------------------------
        credential = resolveCredential(for: configuration)
        if configuration.username?.isEmpty == false && credential == nil {
            let failure = TunnelFailure(
                kind: .invalidCredentials,
                title: "Proxy password unavailable",
                message: "This proxy needs a username and password, but the extension could not read the password.",
                recoverySuggestion: configuration.credentialDelivery == .sharedContainer
                    ? "The App Group container is not readable by the extension. Re-save the proxy in the app so the password is passed inline instead."
                    : "Re-enter the password in the app.",
                underlyingDescription: "credential delivery: \(configuration.credentialDelivery.rawValue), app group available here: \(SharedContainer.isAvailable)"
            )
            log.log(failure)
            complete(failure)
            return
        }

        // ---- Physical interface ---------------------------------------------
        // Bias the proxy transport towards the real network interface. The
        // excluded routes are the primary mechanism; this is the second line of
        // defence on a multi-homed device.
        let resolver = PhysicalInterfaceResolver(log: log, queue: engineQueue)
        resolver.start()
        interfaceResolver = resolver

        // ---- Network settings ------------------------------------------------
        let built = TunnelNetworkSettingsFactory.make(
            configuration: configuration,
            additionallyExcludedAddresses: []
        )
        let settingsDescription = TunnelNetworkSettingsFactory.describe(built)
        for line in settingsDescription { log.info("provider", line) }

        // `setTunnelNetworkSettings` replaces any previous settings, so this is
        // also the correct thing to do on a restart.
        setTunnelNetworkSettings(built.settings) { [weak self] error in
            guard let self else { return }
            if let error {
                let failure = TunnelFailure(
                    kind: .dnsConfigurationFailed,
                    title: "iOS rejected the tunnel settings",
                    message: "The tunnel could not install its routes and DNS configuration.",
                    recoverySuggestion: "This usually means another VPN is active, or the addresses conflict with an existing interface. Disconnect other VPNs and try again.",
                    underlyingDescription: "\(error)"
                )
                self.log.log(failure)
                complete(failure)
                return
            }

            self.log.info("provider", "network settings applied")

            // ---- Engine ------------------------------------------------------
            let adapter = NEPacketTunnelFlowAdapter(flow: self.packetFlow)
            let engine = TunnelEngine(dependencies: .init(
                configuration: configuration,
                credential: self.credential,
                packetFlow: adapter,
                queue: self.engineQueue,
                log: self.log,
                requiredInterface: resolver.currentInterface,
                additionallyExcludedAddresses: []
            ))
            engine.networkSettingsApplied = true
            engine.networkSettingsDescription = settingsDescription
            engine.onStateChange = { [weak self] state in
                self?.log.info("provider", "engine state: \(state.rawValue)")
            }
            self.engine = engine
            engine.start()

            complete(nil)
        }
    }

    // MARK: - Stop

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log.info("provider", "stopTunnel called, reason \(describe(reason))")
        isStopping = true

        engineQueue.async { [weak self] in
            guard let self else {
                completionHandler()
                return
            }
            self.engine?.stop(reason: "provider stop: \(self.describe(reason))")
            self.engine = nil
            self.interfaceResolver?.stop()
            self.interfaceResolver = nil
            self.logMirror?.flush()
            self.logMirror = nil
            // Drop the plaintext credential as soon as the tunnel is gone.
            self.credential = nil
            completionHandler()
        }
    }

    /// Called by iOS when the device wakes.
    ///
    /// There is deliberately no `sleep()` override: on iOS `NEProvider` exposes
    /// sleep only through `sleep(completionHandler:)`, which the Swift overlay
    /// imports as an `async` method rather than an overridable one. Nothing here
    /// needs to run at sleep time — the sockets are owned by the system and the
    /// engine's idle timers simply do not fire while the process is suspended.
    override func wake() {
        super.wake()
        log.info("provider", "device woke")
    }

    // MARK: - App messages

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let completionHandler else { return }

        let envelope: TunnelRequestEnvelope
        do {
            envelope = try TunnelMessageCodec.decodeRequest(messageData)
        } catch {
            log.warning("provider", "could not decode an app message: \(error)")
            completionHandler(nil)
            return
        }

        engineQueue.async { [weak self] in
            guard let self else {
                completionHandler(nil)
                return
            }
            switch envelope.kind {
            case .ping:
                completionHandler(try? TunnelMessageCodec.encode(TunnelResponseEnvelope()))

            case .clearLog:
                self.log.clear()
                completionHandler(try? TunnelMessageCodec.encode(TunnelResponseEnvelope()))

            case .setTracePackets:
                let enabled = envelope.tracePackets ?? false
                self.engine?.setTracePackets(enabled)
                self.configuration?.tracePackets = enabled
                completionHandler(try? TunnelMessageCodec.encode(TunnelResponseEnvelope()))

            case .status:
                let payload = self.engine?.makeStatusPayload()
                    ?? TunnelStatusPayload(
                        engineState: self.isStopping ? "stopping" : "idle",
                        networkSettingsApplied: false,
                        configurationSummary: self.configuration?.redactedSummary
                    )
                completionHandler(try? TunnelMessageCodec.encode(TunnelResponseEnvelope(status: payload)))
            }
        }
    }

    // MARK: - Helpers

    /// Reads the proxy credential.
    ///
    /// Preference order is deliberate: the shared container keeps the password
    /// out of the system VPN preferences, and the inline copy is only used when
    /// the App Group entitlement was not granted to this extension.
    private func resolveCredential(for configuration: TunnelConfiguration) -> ProxyCredential? {
        guard let username = configuration.username, !username.isEmpty else { return nil }

        if let record = SharedContainer.readCredential(for: configuration.profileID) {
            log.info("provider", "proxy credential read from the App Group container")
            return ProxyCredential(username: record.username, password: record.password)
        }

        switch configuration.credentialDelivery {
        case .sharedContainer:
            log.warning("provider", "the configuration says the credential is in the App Group container, but it was not found there; is the App Group entitlement present on the extension?")
        case .inlineProviderConfiguration, .none:
            break
        }

        if let inline = configuration.inlinePassword {
            log.info("provider", "using the inline proxy credential (the App Group container was not available)")
            return ProxyCredential(username: username, password: inline)
        }
        return nil
    }

    private func describe(_ reason: NEProviderStopReason) -> String {
        // Only the reasons that exist across the whole supported OS range are
        // spelled out; anything newer falls through to the numeric value rather
        // than failing to compile against an older SDK.
        switch reason {
        case .none:                       return "none"
        case .userInitiated:              return "user initiated"
        case .providerFailed:             return "provider failed"
        case .noNetworkAvailable:         return "no network available"
        case .unrecoverableNetworkChange: return "unrecoverable network change"
        case .providerDisabled:           return "provider disabled"
        case .authenticationCanceled:     return "authentication cancelled"
        case .configurationFailed:        return "configuration failed"
        case .idleTimeout:                return "idle timeout"
        case .configurationDisabled:      return "configuration disabled"
        case .configurationRemoved:       return "configuration removed"
        case .superceded:                 return "superseded by another VPN"
        @unknown default:                 return "unknown (\(reason.rawValue))"
        }
    }
}
