//
//  AboutView.swift
//  ProxyTunnel
//
//  The honest-limitations screen. This is deliberately part of the app and not
//  only of the README: the person holding the phone needs to know what the app
//  can and cannot do *on that phone*, with the build they actually installed.
//

import SwiftUI
import ProxyTunnelCore

struct AboutView: View {

    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                headerCard
                if environment.entitlements.entitlementDefinitelyMissing {
                    entitlementCard
                }
                architectureCard
                protocolCard
                dnsCard
                privacyCard
                versionCard
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .appBackground()
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.title2)
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ProxyTunnel").font(.headline)
                        Text("Route your iPhone through a proxy you control")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                Text("""
                ProxyTunnel terminates TCP inside a Network Extension packet tunnel and re-opens each connection through your proxy using SOCKS5 or HTTP CONNECT. There is no mock VPN screen: the CONNECT button creates a real NETunnelProviderManager configuration and starts a real packet tunnel.
                """)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var entitlementCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("This build cannot run the tunnel", systemImage: "xmark.octagon.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.danger)
                Text("""
                A Packet Tunnel Provider needs the Apple entitlement \
                com.apple.developer.networking.networkextension with the value \
                packet-tunnel-provider. That capability is only issued to Apple \
                Developer Program members; it cannot be provisioned with a free \
                Apple ID, which is what most sideloading tools use.

                What still works in this build: proxy profiles, validation, \
                Keychain storage, the connectivity test (which really does move \
                bytes through your proxy and shows its egress IP), diagnostics \
                and logs.

                What does not work: the tunnel. iOS will refuse to create or \
                start the VPN configuration.
                """)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.danger.opacity(0.4), lineWidth: 1)
        )
    }

    private var architectureCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("How it is built", systemImage: "square.stack.3d.up")
                    .font(.subheadline.weight(.semibold))
                monoLines([
                    "ProxyTunnel (SwiftUI app)",
                    "  └ NETunnelProviderManager → NETunnelProviderProtocol",
                    "      └ ProxyTunnelExtension (NEPacketTunnelProvider)",
                    "          └ TunnelEngine",
                    "              ├ TCPConnection  (userspace TCP, IPv4 + IPv6)",
                    "              ├ SOCKS5 / HTTP CONNECT client",
                    "              └ DNS interception (UDP relay or DNS-over-TCP)",
                    "                  └ your proxy ──▶ internet"
                ])
                Text("""
                The extension answers the app's SYN, reassembles the byte stream \
                and forwards it over a proxy connection. The reverse direction is \
                re-segmented into TCP packets written back to the virtual \
                interface. Retransmission, window scaling, flow control and \
                graceful close are all implemented; congestion control and SACK \
                are not.
                """)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var protocolCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Protocol support", systemImage: "arrow.left.arrow.right")
                    .font(.subheadline.weight(.semibold))
                ForEach(ProxyProtocol.allCases) { protocolType in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            ProtocolBadge(protocolType: protocolType)
                            Text(protocolType.supportsUDP ? "TCP + UDP" : "TCP only")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(protocolType.supportsUDP ? Theme.success : Theme.warning)
                        }
                        Text(protocolType.shortDescription)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var dnsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("DNS, IPv4 and IPv6", systemImage: "globe")
                    .font(.subheadline.weight(.semibold))
                monoLines([
                    "DNS  intercepted in-tunnel, re-issued through the proxy",
                    "     SOCKS5: over the UDP association",
                    "     HTTP/HTTPS: as DNS-over-TCP inside the tunnelled stream",
                    "IPv4 default route captured; proxy addresses excluded",
                    "IPv6 captured too, unless you turn it off in Settings",
                    "     turning it off is a leak, not a block"
                ])
                Text("""
                DNS never reaches the resolver your carrier handed you, and there \
                is no second resolver configured. Encrypted DNS (DoH/DoT) started \
                by an app is not intercepted — it is proxied like any other \
                connection, which is fine because it is already encrypted.

                Fragmented IP packets are dropped rather than reassembled, so very \
                large UDP datagrams (some DNS answers, some QUIC handshakes) will \
                fail. TCP is unaffected.
                """)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var privacyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("What the proxy can see", systemImage: "eye")
                    .font(.subheadline.weight(.semibold))
                Text("""
                A proxy is not a VPN in the privacy sense. Your proxy operator can \
                see every destination you connect to and, for plain HTTP, the \
                contents of your traffic. TLS protects the payload of HTTPS \
                connections end-to-end, but the destination names are visible to \
                the proxy, and SNI is visible on the wire between you and the \
                proxy unless you use an HTTPS proxy.

                SOCKS5 and HTTP CONNECT carry no encryption of their own. If you \
                are on an untrusted network, use an HTTPS proxy endpoint so at \
                least the hop from your phone to the proxy is encrypted.
                """)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var versionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Build", systemImage: "hammer")
                    .font(.subheadline.weight(.semibold))
                DetailRow(label: "Version", value: AppVersion.displayString)
                DetailRow(label: "App bundle ID", value: AppVersion.bundleIdentifier, monospaced: true)
                DetailRow(label: "Extension bundle ID", value: AppVersion.extensionBundleIdentifier, monospaced: true)
                DetailRow(label: "App Group ID", value: AppIdentifiers.appGroupIdentifier, monospaced: true)
                DetailRow(
                    label: "App Group available",
                    value: SharedContainer.isAvailable ? "yes" : "no",
                    valueColor: SharedContainer.isAvailable ? Theme.success : Theme.warning
                )
                DetailRow(
                    label: "Tunnel entitlement",
                    value: environment.entitlements.canStartPacketTunnel ? "present" : "MISSING",
                    valueColor: environment.entitlements.canStartPacketTunnel ? Theme.success : Theme.danger
                )
            }
        }
    }

    private func monoLines(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
