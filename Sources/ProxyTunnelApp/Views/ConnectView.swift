//
//  ConnectView.swift
//  ProxyTunnel
//
//  The main screen.
//
//  Every value shown here comes from a real source: `NEVPNStatus` through
//  `TunnelController`, the extension's own status payload, or the stored profile.
//  Nothing is optimistically faked, and if the tunnel cannot run at all the
//  screen says so and explains exactly why.
//

import SwiftUI
import ProxyTunnelCore

struct ConnectView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @State private var isBusy = false
    @State private var showProxyPicker = false

    private var profile: ProxyProfile? { environment.profileStore.selectedProfile }
    private var mockActive: Bool { environment.isMockActive }

    /// The state the screen renders.
    ///
    /// In mock mode the *label* changes as well as the colour: "MOCK CONNECTED",
    /// never "Connected".
    private var displayState: TunnelConnectionState {
        if mockActive {
            return .connected(since: environment.mock.startedAt ?? Date(), profileName: profile?.name)
        }
        return environment.tunnel.state
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    banners
                    connectButton
                    statusCard
                    if let failure = environment.tunnel.lastFailure, !mockActive {
                        failureCard(failure)
                    }
                    if let payload = environment.tunnel.status {
                        tunnelDetailCard(payload)
                    }
                    privacyCard
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
            }
            .appBackground()
            .navigationTitle("ProxyTunnel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        environment.refreshEntitlements()
                        Task { await environment.tunnel.fetchStatusOnce() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh status")
                }
            }
            .sheet(isPresented: $showProxyPicker) {
                ProxyPickerSheet()
                    .environmentObject(environment)
            }
        }
    }

    // MARK: Banners

    @ViewBuilder
    private var banners: some View {
        if environment.settings.useMockMode {
            NoticeBanner(
                level: .mock,
                title: "MOCK / DEVELOPMENT MODE IS ON",
                message: MockTunnelSession.explanation,
                action: ("Turn mock mode off", {
                    environment.settings.useMockMode = false
                    environment.mock.stop()
                })
            )
        }

        if environment.tunnel.entitlementBlocked && !environment.settings.useMockMode {
            NoticeBanner(
                level: .danger,
                title: "This build cannot start a VPN tunnel",
                message: environment.entitlements.verdict,
                action: nil
            )
        } else if environment.settings.hasIPv6LeakByDesign {
            NoticeBanner(
                level: .warning,
                title: "IPv6 is not routed through the tunnel",
                message: "IPv6 traffic will use your normal connection. If your network is IPv6-only, nothing will load at all. Re-enable IPv6 in Settings to fix both.",
                action: ("Open Settings", { environment.settings.allowIPv6 = true })
            )
        }

        if environment.settings.blockTrafficWhenTunnelDown {
            NoticeBanner(
                level: .info,
                title: "Fail-closed mode is on",
                message: "iOS will hold traffic and re-establish the tunnel automatically after a drop. Disconnecting from this screen temporarily clears that rule so DISCONNECT actually disconnects.",
                action: nil
            )
        }
    }

    // MARK: Connect button

    private var connectButton: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Theme.color(for: displayState).opacity(0.14), lineWidth: 18)
                    .frame(width: 226, height: 226)

                Circle()
                    .trim(from: 0, to: displayState.isBusy ? 0.28 : 1)
                    .stroke(
                        AngularGradient(
                            colors: [
                                Theme.color(for: displayState).opacity(0.15),
                                Theme.color(for: displayState)
                            ],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 18, lineCap: .round)
                    )
                    .frame(width: 226, height: 226)
                    .rotationEffect(.degrees(displayState.isBusy ? 360 : 0))
                    .animation(
                        displayState.isBusy
                            ? .linear(duration: 1).repeatForever(autoreverses: false)
                            : .default,
                        value: displayState.isBusy
                    )

                Button(action: toggleConnection) {
                    VStack(spacing: 10) {
                        Image(systemName: buttonSymbol)
                            .font(.system(size: 42, weight: .semibold))
                        Text(buttonTitle)
                            .font(.headline.weight(.bold))
                            .tracking(1.2)
                    }
                    .foregroundStyle(Theme.color(for: displayState))
                    .frame(width: 176, height: 176)
                    .background(
                        Circle().fill(Theme.surface)
                    )
                    .overlay(
                        Circle().stroke(Theme.color(for: displayState).opacity(0.4), lineWidth: 1.5)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isBusy || profile == nil || environment.tunnel.state.isBusy)
                .opacity(profile == nil ? 0.45 : 1)
            }
            .padding(.top, 8)

            if let failure = environment.tunnel.lastFailure, !mockActive, case .failed = environment.tunnel.state {
                Text(failure.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.danger)
            } else {
                Text(displayState.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.color(for: displayState))
            }
        }
    }

    private var buttonTitle: String {
        if mockActive { return "MOCK ON" }
        switch environment.tunnel.state {
        case .connected:                 return "DISCONNECT"
        case .connecting, .disconnecting: return "WAIT…"
        default:                         return "CONNECT"
        }
    }

    private var buttonSymbol: String {
        if mockActive { return "hammer.fill" }
        switch environment.tunnel.state {
        case .connected:                  return "stop.fill"
        case .connecting, .disconnecting: return "ellipsis"
        default:                          return "power"
        }
    }

    // MARK: Status card

    private var statusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(headline)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(mockActive ? Theme.mock : Theme.primaryText)
                    Spacer()
                    if let profile {
                        ProtocolBadge(protocolType: profile.protocolType)
                    }
                }

                if let profile {
                    Divider().overlay(Theme.hairline)
                    DetailRow(label: "Proxy", value: profile.name, symbol: "server.rack")
                    DetailRow(label: "Endpoint", value: profile.displayEndpoint, monospaced: true, symbol: "network")
                    DetailRow(
                        label: "Authentication",
                        value: profile.usesAuthentication ? "username + password" : "none",
                        symbol: "person.badge.key"
                    )
                    if displayState.sessionStart != nil {
                        DetailRow(
                            label: mockActive ? "Simulated for" : "Connected for",
                            value: Format.duration(displayState.sessionStart.map { Date().timeIntervalSince($0) } ?? 0),
                            monospaced: true,
                            symbol: "clock"
                        )
                    }
                } else {
                    Divider().overlay(Theme.hairline)
                    Text("No proxy selected. Add one on the Proxies tab, then select it here.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                    Button("Choose a proxy") { showProxyPicker = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            // Live duration, driven by the system clock rather than a stored value.
            if displayState.sessionStart != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let start = displayState.sessionStart ?? context.date
                    Text(Format.duration(context.date.timeIntervalSince(start)))
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(Theme.color(for: displayState))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Theme.color(for: displayState).opacity(0.14)))
                        .padding(12)
                }
            }
        }
    }

    private var headline: String {
        if mockActive { return "MOCK CONNECTED" }
        switch environment.tunnel.state {
        case .disconnected:  return "Not connected"
        case .connecting:    return "Connecting…"
        case .connected:     return "Connected"
        case .disconnecting: return "Disconnecting…"
        case .failed:        return "Connection failed"
        }
    }

    // MARK: Failure card

    private func failureCard(_ failure: TunnelFailure) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                    Text(failure.title)
                        .font(.subheadline.weight(.semibold))
                }
                Text(failure.message)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let suggestion = failure.recoverySuggestion {
                    Text(suggestion)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text(failure.kind.rawValue)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Theme.tertiaryText)
                    Spacer()
                    if failure.isRetryable {
                        Button("Try again") { toggleConnection() }
                            .font(.footnote.weight(.semibold))
                    }
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.danger.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: Tunnel detail

    private func tunnelDetailCard(_ payload: TunnelStatusPayload) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Tunnel (reported by the extension)")
                    .font(.subheadline.weight(.semibold))
                DetailRow(label: "Engine", value: payload.engineState, symbol: "gearshape.2")
                DetailRow(
                    label: "Network settings",
                    value: payload.networkSettingsApplied ? "applied" : "not applied yet",
                    valueColor: payload.networkSettingsApplied ? Theme.success : Theme.warning,
                    symbol: "wifi.router"
                )
                DetailRow(label: "TCP flows open", value: "\(payload.statistics.tcpActiveConnections)", symbol: "arrow.left.arrow.right")
                DetailRow(
                    label: "Proxied payload",
                    value: "\(Format.bytes(payload.statistics.tcpBytesToProxy)) up · \(Format.bytes(payload.statistics.tcpBytesFromProxy)) down",
                    symbol: "chart.bar"
                )
                DetailRow(label: "DNS queries handled", value: "\(payload.statistics.dnsQueriesHandled)", symbol: "text.magnifyingglass")
                if let relay = payload.udpRelayDescription {
                    DetailRow(label: "UDP", value: relay, symbol: "dot.radiowaves.left.and.right")
                } else {
                    DetailRow(
                        label: "UDP",
                        value: "not relayed (\(payload.configurationSummary?.contains("udp=off") == true ? "disabled" : "unsupported by this protocol"))",
                        valueColor: Theme.warning,
                        symbol: "dot.radiowaves.left.and.right"
                    )
                }
            }
        }
    }

    // MARK: Privacy card

    private var privacyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("What actually happens", systemImage: "lock.shield")
                    .font(.subheadline.weight(.semibold))
                BulletText("TCP connections are terminated in the tunnel and re-opened through your proxy (SOCKS5 CONNECT or HTTP CONNECT).")
                BulletText("DNS is intercepted inside the tunnel and re-issued through the proxy, so queries do not reach your carrier's resolver.")
                if let profile {
                    if profile.protocolType.supportsUDP {
                        BulletText("UDP is relayed through the proxy's SOCKS5 UDP association. Fragmented datagrams are dropped.")
                    } else {
                        BulletText("\(profile.protocolType.displayName) cannot carry UDP, so only DNS works over UDP. QUIC and other UDP applications will not work.")
                    }
                }
                BulletText("The proxy can see every destination you connect to and, unless it is an HTTPS proxy, so can anyone on the path between you and it.")
            }
        }
    }

    // MARK: Actions

    private func toggleConnection() {
        guard let profile else {
            showProxyPicker = true
            return
        }
        isBusy = true
        Task {
            if mockActive || environment.tunnel.state.isConnected {
                await environment.stopTunnel()
            } else {
                await environment.startTunnel(profile: profile)
            }
            isBusy = false
        }
    }
}

/// One line of body text with a leading dot.
struct BulletText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Theme.tertiaryText)
                .frame(width: 4, height: 4)
                .padding(.top, 7)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Proxy picker

struct ProxyPickerSheet: View {

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if environment.profileStore.enabledProfiles.isEmpty {
                    Text("No proxies yet. Add one on the Proxies tab.")
                        .foregroundStyle(Theme.secondaryText)
                }
                ForEach(environment.profileStore.enabledProfiles) { profile in
                    Button {
                        try? environment.profileStore.select(id: profile.id)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name)
                                    .foregroundStyle(Theme.primaryText)
                                Text(profile.displayEndpoint)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            Spacer()
                            ProtocolBadge(protocolType: profile.protocolType)
                            if environment.profileStore.selectedProfileID == profile.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Theme.success)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select proxy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
