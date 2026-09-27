//
//  SettingsView.swift
//  ProxyTunnel
//

import SwiftUI
import ProxyTunnelCore

struct SettingsView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @State private var dnsText: String = ""
    @State private var dnsReport = DNSSettingsValidator.Result(servers: [], issues: [])

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                dnsSection
                privacySection
                diagnosticsSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.backgroundGradient)
            .navigationTitle("Settings")
            .onAppear {
                dnsText = environment.settings.dnsServers.joined(separator: "\n")
                dnsReport = DNSSettingsValidator.validate(environment.settings.dnsServers)
            }
        }
    }

    // MARK: Connection

    private var connectionSection: some View {
        Section {
            Toggle("Connect on launch", isOn: Binding(
                get: { environment.settings.autoConnectOnLaunch },
                set: { environment.settings.autoConnectOnLaunch = $0 }
            ))

            Toggle("Block traffic while the tunnel is down", isOn: Binding(
                get: { environment.settings.blockTrafficWhenTunnelDown },
                set: { environment.settings.blockTrafficWhenTunnelDown = $0 }
            ))
        } header: {
            Text("Connection")
        } footer: {
            Text("""
            "Block traffic while the tunnel is down" installs an iOS on-demand rule that keeps the tunnel up and holds traffic until it reconnects. That is iOS's own fail-closed behaviour for on-demand VPN — it is not a firewall written by this app, and it cannot stop traffic that macOS-style kill switches block (for example traffic that was already established over the physical interface before the tunnel came up). While it is on, tapping DISCONNECT clears the rule first, so disconnecting works.
            """)
        }
    }

    // MARK: DNS

    private var dnsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                TextField("DNS servers", text: $dnsText, axis: .vertical)
                    .lineLimit(1...4)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                    .font(.system(.subheadline, design: .monospaced))
                    .onChange(of: dnsText) { newValue in
                        dnsReport = DNSSettingsValidator.validate(DNSSettingsValidator.split(newValue))
                    }

                ForEach(dnsReport.issues) { issue in
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: issue.severity == .error ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(issue.severity == .error ? Theme.danger : Theme.warning)
                        Text(issue.message)
                            .font(.caption)
                            .foregroundStyle(issue.severity == .error ? Theme.danger : Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Button("Save DNS servers") {
                environment.settings.dnsServers = dnsReport.servers
                dnsText = dnsReport.servers.joined(separator: "\n")
            }
            .disabled(!dnsReport.isValid)

            Button("Restore defaults (\(TunnelNetworkDefaults.dnsServers.joined(separator: ", ")))") {
                environment.settings.dnsServers = TunnelNetworkDefaults.dnsServers
                dnsText = TunnelNetworkDefaults.dnsServers.joined(separator: "\n")
                dnsReport = DNSSettingsValidator.validate(TunnelNetworkDefaults.dnsServers)
            }
        } header: {
            Text("DNS")
        } footer: {
            Text("""
            These addresses are advertised to iOS as the tunnel's resolvers. The device never contacts them directly: every query to port 53 is intercepted inside the tunnel and re-issued through your proxy. Changing them changes where the proxy sends the query, not who can see it — the proxy still sees every name you look up.
            """)
        }
    }

    // MARK: Privacy

    private var privacySection: some View {
        Section {
            Toggle("Route IPv6 through the tunnel", isOn: Binding(
                get: { environment.settings.allowIPv6 },
                set: { environment.settings.allowIPv6 = $0 }
            ))

            Toggle("Relay UDP through SOCKS5 (when supported)", isOn: Binding(
                get: { environment.settings.relayUDP },
                set: { environment.settings.relayUDP = $0 }
            ))

            Stepper(
                value: Binding(
                    get: { environment.settings.idleTimeoutSeconds },
                    set: { environment.settings.idleTimeoutSeconds = $0 }
                ),
                in: 60...7200,
                step: 60
            ) {
                DetailRow(
                    label: "Connection idle timeout",
                    value: Format.duration(TimeInterval(environment.settings.idleTimeoutSeconds))
                )
            }
        } header: {
            Text("Traffic")
        } footer: {
            Text("""
            Turning IPv6 off does not "block" it — IPv6 traffic simply leaves the tunnel and uses your normal connection, which is a leak. Only turn it off if your proxy provider cannot handle IPv6 destinations.
            """)
        }
    }

    // MARK: Diagnostics

    private var diagnosticsSection: some View {
        Section {
            Toggle("Development / mock mode", isOn: Binding(
                get: { environment.settings.useMockMode },
                set: { newValue in
                    environment.settings.useMockMode = newValue
                    if !newValue { environment.mock.stop() }
                }
            ))

            Toggle("Log every packet (very noisy)", isOn: Binding(
                get: { environment.settings.tracePackets },
                set: { newValue in
                    environment.settings.tracePackets = newValue
                    Task { await environment.tunnel.setTracePackets(newValue) }
                }
            ))

            NavigationLink {
                DiagnosticsView().environmentObject(environment)
            } label: {
                Label("Diagnostics", systemImage: "stethoscope")
            }

            NavigationLink {
                LogsView().environmentObject(environment)
            } label: {
                Label("Logs", systemImage: "doc.text.magnifyingglass")
            }

            NavigationLink {
                AboutView().environmentObject(environment)
            } label: {
                Label("About & limitations", systemImage: "info.circle")
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("""
            Mock mode replaces the VPN connection with a clearly-labelled simulation so the interface can be tested on a build where the packet tunnel extension cannot run. It never routes traffic and never reports a real connection.
            """)
        }
    }

    // MARK: About shortcut

    private var aboutSection: some View {
        Section {
            DetailRow(label: "Version", value: AppVersion.displayString)
            DetailRow(label: "Bundle ID", value: AppVersion.bundleIdentifier, monospaced: true)
            DetailRow(label: "Extension ID", value: AppVersion.extensionBundleIdentifier, monospaced: true)
        } header: {
            Text("Build")
        }
    }
}
