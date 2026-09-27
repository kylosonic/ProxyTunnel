//
//  TunnelFailure.swift
//  ProxyTunnelCore
//

import Foundation

/// Every user-visible failure the app can produce, with a stable machine-readable
/// kind so the UI, the logs and the tests agree on what happened.
///
/// The `message` and `recoverySuggestion` strings are guaranteed *not* to
/// contain credentials: they are built from `ProxyProfile.redactedSummary` and
/// from protocol identifiers only.
public struct TunnelFailure: Error, Equatable, Sendable, Identifiable, Codable {

    public enum Kind: String, Codable, Sendable {
        case invalidHost
        case invalidPort
        case invalidCredentials
        case proxyUnreachable
        case authenticationFailed
        case connectionTimeout
        case tlsFailure
        case vpnPermissionDenied
        case vpnConfigurationFailed
        case tunnelFailed
        case unsupportedProtocol
        case unsupportedCapability
        case dnsConfigurationFailed
        case networkUnavailable
        case missingEntitlement
        case providerNotInstalled
        case cancelled
        case internalError
    }

    public let kind: Kind
    /// Short headline, e.g. "Authentication failed".
    public let title: String
    /// One or two sentences explaining what happened. Never contains secrets.
    public let message: String
    /// What the user can do about it.
    public let recoverySuggestion: String?
    /// Underlying error description, already redacted.
    public let underlyingDescription: String?
    /// `true` when retrying the same action could plausibly succeed.
    public let isRetryable: Bool
    /// When the failure happened.
    public let timestamp: Date

    public var id: String { "\(kind.rawValue)-\(timestamp.timeIntervalSince1970)" }

    public init(
        kind: Kind,
        title: String,
        message: String,
        recoverySuggestion: String? = nil,
        underlyingDescription: String? = nil,
        isRetryable: Bool = false,
        timestamp: Date = Date()
    ) {
        self.kind = kind
        self.title = title
        self.message = LogRedactor.redact(message)
        self.recoverySuggestion = recoverySuggestion.map(LogRedactor.redact)
        self.underlyingDescription = underlyingDescription.map(LogRedactor.redact)
        self.isRetryable = isRetryable
        self.timestamp = timestamp
    }

    /// A one-line, safe-to-log rendering.
    public var diagnosticLine: String {
        var line = "[\(kind.rawValue)] \(title): \(message)"
        if let recoverySuggestion { line += " | fix: \(recoverySuggestion)" }
        if let underlyingDescription { line += " | underlying: \(underlyingDescription)" }
        return line
    }
}

// MARK: - Mapping from lower-level errors

extension TunnelFailure {

    /// Errors raised by `ProxySession` / `ProxyConnector`.
    public static func from(proxyError error: ProxyError, endpoint: ProxyEndpoint?) -> TunnelFailure {
        let where_ = endpoint.map { " (\($0.redactedEndpoint))" } ?? ""
        switch error {
        case .cannotResolveHost(let host):
            return TunnelFailure(
                kind: .proxyUnreachable,
                title: "Proxy host not found",
                message: "The proxy host \"\(host)\" could not be resolved to an IP address.",
                recoverySuggestion: "Check the host name for typos and make sure you have a working internet connection.",
                underlyingDescription: error.diagnosticDescription,
                isRetryable: true
            )
        case .connectionFailed(let detail):
            return TunnelFailure(
                kind: .proxyUnreachable,
                title: "Proxy unreachable",
                message: "Could not open a TCP connection to the proxy\(where_).",
                recoverySuggestion: "Verify the host and port, confirm the proxy is online, and check that your current network allows outbound connections to that port.",
                underlyingDescription: detail,
                isRetryable: true
            )
        case .connectionTimeout:
            return TunnelFailure(
                kind: .connectionTimeout,
                title: "Connection timed out",
                message: "The proxy\(where_) did not respond in time.",
                recoverySuggestion: "The port may be blocked by your mobile carrier, or the proxy may be offline. Try another network or another proxy.",
                underlyingDescription: error.diagnosticDescription,
                isRetryable: true
            )
        case .tlsFailed(let detail):
            return TunnelFailure(
                kind: .tlsFailure,
                title: "TLS handshake with the proxy failed",
                message: "Could not establish a TLS session with the proxy\(where_).",
                recoverySuggestion: "If your provider gives you a plain HTTP proxy port, select \"HTTP CONNECT\" instead of \"HTTPS CONNECT\". A certificate error here means the proxy is not really speaking TLS.",
                underlyingDescription: detail,
                isRetryable: false
            )
        case .authenticationRejected:
            return TunnelFailure(
                kind: .authenticationFailed,
                title: "Authentication failed",
                message: "The proxy rejected the username or password.",
                recoverySuggestion: "Re-enter the credentials in the proxy settings. Passwords are masked here on purpose and are never shown in logs.",
                underlyingDescription: error.diagnosticDescription,
                isRetryable: false
            )
        case .authenticationRequired:
            return TunnelFailure(
                kind: .invalidCredentials,
                title: "Credentials required",
                message: "The proxy requires authentication but this profile has no username.",
                recoverySuggestion: "Edit the proxy and enter the username and password your provider gave you.",
                underlyingDescription: error.diagnosticDescription,
                isRetryable: false
            )
        case .unsupportedAuthMethod(let method):
            return TunnelFailure(
                kind: .unsupportedCapability,
                title: "Unsupported authentication",
                message: "The proxy only offers an authentication method this client does not implement (method 0x\(String(format: "%02x", method))).",
                recoverySuggestion: "Use a proxy endpoint that supports \"no authentication\" or username/password (RFC 1929).",
                underlyingDescription: error.diagnosticDescription,
                isRetryable: false
            )
        case .badServerResponse(let detail):
            return TunnelFailure(
                kind: .proxyUnreachable,
                title: "Unexpected reply from the proxy",
                message: "The proxy\(where_) replied with something that is not valid for \(endpoint?.protocolType.displayName ?? "this protocol").",
                recoverySuggestion: "Make sure the protocol selected in the app matches the protocol the server actually speaks, and that you are connecting to the proxy port rather than a web port.",
                underlyingDescription: detail,
                isRetryable: false
            )
        case .proxyRefusedConnection(let reply):
            return TunnelFailure(
                kind: .proxyUnreachable,
                title: "Proxy refused the target connection",
                message: "The proxy accepted our credentials but refused to connect to the destination (\(reply)).",
                recoverySuggestion: "The destination may be unreachable from the proxy, or your proxy plan may block that port.",
                underlyingDescription: error.diagnosticDescription,
                isRetryable: false
            )
        case .addressFamilyUnsupported:
            return TunnelFailure(
                kind: .unsupportedCapability,
                title: "Address family not supported",
                message: "The proxy cannot reach this kind of address.",
                recoverySuggestion: "Try a proxy that supports the address family you need, or disable IPv6 in the app's settings.",
                underlyingDescription: error.diagnosticDescription,
                isRetryable: false
            )
        case .cancelled:
            return TunnelFailure(
                kind: .cancelled,
                title: "Cancelled",
                message: "The operation was cancelled.",
                isRetryable: true
            )
        case .protocolViolation(let detail):
            return TunnelFailure(
                kind: .proxyUnreachable,
                title: "Protocol error",
                message: "The proxy violated the \(endpoint?.protocolType.displayName ?? "proxy") protocol.",
                recoverySuggestion: "Check that the selected protocol matches the server.",
                underlyingDescription: detail,
                isRetryable: false
            )
        }
    }
}
