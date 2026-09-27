// swift-tools-version: 5.9
//
//  Package.swift
//  ProxyTunnelCore
//
//  Shared, platform-neutral core of ProxyTunnel:
//    * proxy profile model + validation
//    * Keychain-backed secret storage
//    * SOCKS5 / HTTP CONNECT / HTTPS proxy protocol codecs and sessions
//    * a userspace IPv4/IPv6 + TCP/IP stack used by the packet tunnel
//    * the tunnel engine that bridges NEPacketTunnelFlow to the proxy
//
//  This is a *static* library product on purpose: the main app and the Network
//  Extension each link their own copy into their own Mach-O image. That keeps
//  the app bundle free of embedded frameworks, which matters a great deal when
//  the IPA is later re-signed by a third-party tool (Sideloadly): fewer nested
//  code objects means fewer things that can go wrong during re-signing.
//
import PackageDescription

let package = Package(
    name: "ProxyTunnelCore",
    platforms: [
        // iOS 16 gives us NavigationStack, Grid, and modern SwiftUI without
        // requiring the very latest devices.
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "ProxyTunnelCore",
            type: .static,
            targets: ["ProxyTunnelCore"]
        )
    ],
    dependencies: [
        // Intentionally zero external dependencies. Everything here is built on
        // Apple's own frameworks so that a GitHub-hosted macOS runner can build
        // the project with nothing but Xcode installed.
    ],
    targets: [
        .target(
            name: "ProxyTunnelCore",
            path: "Sources/ProxyTunnelCore",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("Network"),
                .linkedFramework("NetworkExtension"),
                .linkedFramework("Security")
            ]
        )
    ]
)
