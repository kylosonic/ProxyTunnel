//
//  MockTunnelSession.swift
//  ProxyTunnel
//
//  DEVELOPMENT / MOCK MODE.
//
//  This exists for one reason: on a build whose packet tunnel extension lacks the
//  Network Extension entitlement, the VPN half of the app is unavailable, but the
//  UI, the profile editor, validation, Keychain storage and the connectivity test
//  all still work. Mock mode lets those be exercised without a real tunnel.
//
//  The rules this type follows, deliberately and strictly:
//
//    * It never claims traffic is routed. The banner text says so on every screen
//      that shows connection state, and the headline reads "MOCK CONNECTED"
//      rather than "Connected".
//    * It never touches NetworkExtension, and it never creates a VPN profile.
//    * It has no `statistics`. There are no counters to misread as real traffic.
//
//  In other words: it is a labelled development affordance, not a fake VPN.
//

import Foundation
import ProxyTunnelCore

@MainActor
final class MockTunnelSession: ObservableObject {

    @Published private(set) var isActive = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var profileName: String?

    /// Shown verbatim wherever mock state is displayed.
    static let banner = "MOCK / DEVELOPMENT MODE — no VPN tunnel exists and no traffic is being routed."

    /// The longer explanation shown on the connection screen.
    static let explanation = """
    This is a simulation. Tapping the button below only changes what this screen \
    displays. Your iPhone's traffic is not being routed through any proxy, and \
    your real IP address is unchanged.
    """

    func start(profile: ProxyProfile) {
        isActive = true
        startedAt = Date()
        profileName = profile.name
    }

    func stop() {
        isActive = false
        startedAt = nil
        profileName = nil
    }

    var duration: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }
}
