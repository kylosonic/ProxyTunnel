//
//  RootView.swift
//  ProxyTunnel
//

import SwiftUI
import ProxyTunnelCore

struct RootView: View {

    @EnvironmentObject private var environment: AppEnvironment
    @State private var selection: Tab = .connect

    enum Tab: Hashable {
        case connect, proxies, settings
    }

    var body: some View {
        TabView(selection: $selection) {
            ConnectView()
                .tabItem { Label("Connect", systemImage: "shield.lefthalf.filled") }
                .tag(Tab.connect)

            ProxyListView()
                .tabItem { Label("Proxies", systemImage: "server.rack") }
                .tag(Tab.proxies)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(Theme.accent)
        .task {
            await environment.bootstrap()
        }
    }
}

/// Placeholder shown when there is nothing to display yet. Replaces
/// `ContentUnavailableView`, which is iOS 17+.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.tertiaryText)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
