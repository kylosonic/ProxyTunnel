//
//  DiagnosticsView.swift
//  ProxyTunnel
//
//  The screen that answers "why is this not working?" without guesswork.
//
//  It reports four independent things, each with its own evidence:
//
//    1. What the signature actually granted (read from the embedded profile).
//    2. What iOS thinks the VPN state is.
//    3. What the extension says it is doing, with counters.
//    4. Whether the proxy itself works, proved by moving bytes through it.
//

import SwiftUI
import ProxyTunnelCore

struct DiagnosticsView: View {

    @EnvironmentObject private var environment: AppEnvironment

    @State private var isRunning = false
    @State private var report: DiagnosticRun?

    struct DiagnosticRun {
        var validation: ValidationReport?
        var resolvedAddresses: [String]
        var probe: ProxyProbeReport?
        var notes: [String]
        var finishedAt: Date
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                entitlementCard
                sharedContainerCard
                vpnStateCard
                extensionCard
                runCard
                if let report { reportCard(report) }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .appBackground()
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await environment.tunnel.fetchStatusOnce()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }

    // MARK: Signing

    private var entitlementCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Signing & entitlements", systemImage: "checkmark.shield")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    statusPill(
                        environment.entitlements.canStartPacketTunnel ? "tunnel entitlement present" : "tunnel entitlement MISSING",
                        ok: environment.entitlements.canStartPacketTunnel
                    )
                }

                Text(environment.entitlements.verdict)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let app = environment.entitlements.appProfile {
                    DisclosureGroup {
                        monoLines(app.summaryLines)
                    } label: {
                        Text("Host app profile").font(.footnote.weight(.semibold))
                    }
                } else {
                    Text("Host app: no embedded provisioning profile found (normal for a distribution-signed build).")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
                }

                ForEach(environment.entitlements.extensionProfiles, id: \.path) { profile in
                    DisclosureGroup {
                        monoLines(profile.summaryLines)
                    } label: {
                        Text("Extension profile").font(.footnote.weight(.semibold))
                    }
                }

                ForEach(environment.entitlements.problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var sharedContainerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Credential delivery", systemImage: "key.horizontal")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    statusPill(
                        SharedContainer.isAvailable ? "shared container" : "inline",
                        ok: SharedContainer.isAvailable
                    )
                }
                Text(SharedContainer.statusDescription)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let payload = environment.tunnel.status, let summary = payload.configurationSummary {
                    Text(summary)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: VPN state

    private var vpnStateCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("iOS VPN state", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.subheadline.weight(.semibold))
                DetailRow(label: "App view", value: environment.tunnel.state.title)
                DetailRow(label: "Configuration", value: environment.tunnel.managerSummary)
                if let failure = environment.tunnel.lastFailure {
                    DetailRow(label: "Last failure", value: "\(failure.kind.rawValue): \(failure.title)", valueColor: Theme.danger)
                    Text(failure.diagnosticLine)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Extension

    private var extensionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Packet tunnel extension", systemImage: "gearshape.2")
                    .font(.subheadline.weight(.semibold))

                if let payload = environment.tunnel.status {
                    DetailRow(label: "Engine state", value: payload.engineState)
                    DetailRow(
                        label: "Network settings",
                        value: payload.networkSettingsApplied ? "applied" : "not applied",
                        valueColor: payload.networkSettingsApplied ? Theme.success : Theme.warning
                    )
                    if let interface = payload.physicalInterface {
                        DetailRow(label: "Transport interface", value: interface)
                    }
                    ForEach(payload.statistics.summaryLines, id: \.self) { line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !payload.networkSettingsDescription.isEmpty {
                        DisclosureGroup {
                            monoLines(payload.networkSettingsDescription)
                        } label: {
                            Text("Routing actually installed").font(.footnote.weight(.semibold))
                        }
                    }
                } else {
                    Text("No status yet. The extension only reports while the tunnel is running.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }

    // MARK: Full run

    private var runCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Full check", systemImage: "play.circle")
                    .font(.subheadline.weight(.semibold))
                Text("Validates the selected proxy, resolves its host, opens it and fetches a page through it. This bypasses the VPN tunnel, so it works even when the tunnel cannot start.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task { await runDiagnostics() }
                } label: {
                    HStack {
                        if isRunning { ProgressView().controlSize(.small) }
                        Text(isRunning ? "Running…" : "Run full check")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)

                if environment.profileStore.selectedProfile == nil {
                    Text("Select a proxy first.")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                }
            }
        }
    }

    @ViewBuilder
    private func reportCard(_ run: DiagnosticRun) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Result", systemImage: "list.bullet.clipboard")
                    .font(.subheadline.weight(.semibold))

                if let validation = run.validation {
                    statusPill(
                        validation.isValid ? "profile valid" : "profile has \(validation.errors.count) error(s)",
                        ok: validation.isValid
                    )
                }
                if !run.resolvedAddresses.isEmpty {
                    Text("Resolved to \(run.resolvedAddresses.joined(separator: ", "))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                }
                ForEach(run.notes, id: \.self) { note in
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let probe = run.probe {
                    ProbeReportView(report: probe)
                }
                Text("Checked \(run.finishedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
    }

    // MARK: Helpers

    private func statusPill(_ text: String, ok: Bool) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill((ok ? Theme.success : Theme.danger).opacity(0.16)))
            .foregroundStyle(ok ? Theme.success : Theme.danger)
    }

    private func monoLines(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func refreshAll() async {
        environment.refreshEntitlements()
        await environment.tunnel.fetchStatusOnce()
    }

    private func runDiagnostics() async {
        guard let profile = environment.profileStore.selectedProfile else { return }
        isRunning = true
        var notes: [String] = []

        let validation = ProxyProfileValidator.validate(profile: profile)
        if !validation.isValid {
            notes.append("Validation: \(validation.summary)")
        }

        var addresses: [String] = []
        do {
            addresses = try await HostResolver.resolveAsync(host: profile.host, port: profile.port)
        } catch {
            notes.append("Resolution failed: \(error)")
        }

        if environment.profileStore.isMissingStoredPassword(for: profile) {
            notes.append("The Keychain item for this profile's password is missing; the proxy will reject authentication.")
        }

        if !environment.entitlements.canStartPacketTunnel {
            notes.append("The tunnel cannot start in this build, so the check below uses a direct proxy connection instead. A successful result proves the proxy and credentials are correct; it does not prove the tunnel works.")
        }

        let credential = try? environment.profileStore.credential(for: profile)
        let endpoint = ProxyEndpoint(profile: profile, credential: credential)

        var probeConfiguration = ProxyProbeConfiguration.default
        probeConfiguration.checkHost = environment.settings.probeHost
        probeConfiguration.checkPath = environment.settings.probePath
        probeConfiguration.resolvedAddresses = addresses.isEmpty ? nil : addresses

        let probe = await ProxyProbe.run(
            endpoint: endpoint,
            configuration: probeConfiguration,
            log: environment.log
        )

        report = DiagnosticRun(
            validation: validation,
            resolvedAddresses: addresses,
            probe: probe,
            notes: notes,
            finishedAt: Date()
        )
        isRunning = false
    }
}
