//
//  TunnelConnectionState.swift
//  ProxyTunnelCore
//

import Foundation

/// The single source of truth for what the main screen displays.
///
/// The state is *derived* from `NEVPNStatus` plus the extension's own reported
/// status; the UI never invents a state of its own. `TunnelController` is the
/// only thing allowed to produce these values.
public enum TunnelConnectionState: Equatable, Sendable {

    /// No VPN configuration is active.
    case disconnected

    /// `startVPNTunnel()` has been called and we are waiting for the extension
    /// to report that the tunnel is up.
    case connecting(startedAt: Date)

    /// The packet tunnel is running and `setTunnelNetworkSettings` succeeded.
    case connected(since: Date, profileName: String?)

    /// `stopVPNTunnel()` has been called and we are waiting for teardown.
    case disconnecting

    /// The last attempt failed. `failure` carries a redacted, user-facing
    /// explanation.
    case failed(TunnelFailure)

    /// Whether a tunnel is (or is becoming) active. Used to disable controls.
    public var isBusy: Bool {
        switch self {
        case .connecting, .disconnecting: return true
        default: return false
        }
    }

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    /// Headline shown under the app logo.
    public var title: String {
        switch self {
        case .disconnected:   return "Disconnected"
        case .connecting:     return "Connecting…"
        case .connected:      return "Connected"
        case .disconnecting:  return "Disconnecting…"
        case .failed:         return "Connection Failed"
        }
    }

    /// The instant the current session started, if any. Drives the duration
    /// readout.
    public var sessionStart: Date? {
        switch self {
        case .connected(let since, _):     return since
        case .connecting(let startedAt):   return startedAt
        default:                           return nil
        }
    }

    /// Status as reported by `NEVPNStatus`, mapped onto our own vocabulary.
    /// `mockActive` marks a development-mode connection so the UI can be
    /// explicit that nothing is really being routed.
    public static func from(
        vpnStatus: NEVPNStatusValue,
        profileName: String?,
        connectedSince: Date?,
        lastFailure: TunnelFailure?,
        mockActive: Bool
    ) -> TunnelConnectionState {
        switch vpnStatus {
        case .invalid:
            if let lastFailure { return .failed(lastFailure) }
            return .disconnected
        case .disconnected:
            if let lastFailure, !mockActive { return .failed(lastFailure) }
            return .disconnected
        case .connecting, .reasserting:
            if mockActive { return .connected(since: connectedSince ?? Date(), profileName: profileName) }
            return .connecting(startedAt: connectedSince ?? Date())
        case .connected:
            return .connected(since: connectedSince ?? Date(), profileName: profileName)
        case .disconnecting:
            return .disconnecting
        }
    }
}

/// A plain-mirror of `NEVPNStatus` so that `ProxyTunnelCore` can be compiled and
/// unit-tested without importing NetworkExtension into the model layer.
///
/// `TunnelController` maps the real enum onto this one in a single place.
public enum NEVPNStatusValue: Int, Sendable, CaseIterable {
    case invalid = 0
    case disconnected = 1
    case connecting = 2
    case connected = 3
    case reasserting = 4
    case disconnecting = 5
}
