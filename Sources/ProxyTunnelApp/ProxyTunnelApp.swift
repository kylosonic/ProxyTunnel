//
//  ProxyTunnelApp.swift
//  ProxyTunnel
//

import SwiftUI
import ProxyTunnelCore

@main
struct ProxyTunnelApp: App {

    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}
