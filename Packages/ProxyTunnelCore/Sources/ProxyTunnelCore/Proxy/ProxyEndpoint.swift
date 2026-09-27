//
//  ProxyEndpoint.swift
//  ProxyTunnelCore
//

import Foundation

/// Everything needed to reach and authenticate to one proxy.
///
/// This is the value that crosses the app → extension boundary, and it is the
/// only thing the proxy client layer ever sees. It is deliberately independent
/// of `ProxyProfile` so that the wire code has no knowledge of persistence.
public struct ProxyEndpoint: Equatable, Hashable, Sendable {

    public let host: String
    public let port: Int
    public let protocolType: ProxyProtocol
    public let credential: ProxyCredential?

    public init(host: String, port: Int, protocolType: ProxyProtocol, credential: ProxyCredential? = nil) {
        self.host = host
        self.port = port
        self.protocolType = protocolType
        self.credential = credential
    }

    public init(profile: ProxyProfile, credential: ProxyCredential?) {
        self.host = profile.host
        self.port = profile.port
        self.protocolType = profile.protocolType
        self.credential = credential
    }

    /// Ready to be put in `NWEndpoint.Port`.
    public var portValue: UInt16 { UInt16(clamping: port) }

    /// `host:port`, IPv6 bracketed. Safe to log.
    public var redactedEndpoint: String {
        ProxyProfile.formatEndpoint(host: host, port: port)
    }

    /// The authority string used in an HTTP CONNECT request line.
    public var connectAuthority: String {
        IPAddress(presentationName: host)?.authority(port: portValue) ?? "\(host):\(port)"
    }
}

extension ProxyEndpoint: CustomStringConvertible {
    public var description: String {
        "\(protocolType.displayName) \(redactedEndpoint) auth=\(credential != nil ? "yes" : "no")"
    }
}

// MARK: - Errors

/// Everything that can go wrong while talking to a proxy.
///
/// These are *transport and protocol* errors. `TunnelFailure.from(proxyError:)`
/// turns them into user-facing text.
public enum ProxyError: Error, Equatable, CustomStringConvertible {

    /// `getaddrinfo` failed for the proxy host name.
    case cannotResolveHost(String)
    /// The TCP connection could not be established.
    case connectionFailed(String)
    /// Nothing responded within the deadline.
    case connectionTimeout
    /// The TLS handshake with the proxy failed (trust, protocol, version…).
    case tlsFailed(String)
    /// The proxy asked for authentication and we have no credentials.
    case authenticationRequired
    /// The proxy rejected the credentials we sent.
    case authenticationRejected
    /// SOCKS5: the server picked an auth method we do not implement.
    case unsupportedAuthMethod(UInt8)
    /// The server sent something that is not valid for its protocol.
    case badServerResponse(String)
    /// The proxy accepted us but refused the requested destination.
    case proxyRefusedConnection(String)
    /// The proxy cannot handle the address family (e.g. IPv6 to an IPv4-only relay).
    case addressFamilyUnsupported
    /// A protocol invariant was violated mid-stream.
    case protocolViolation(String)
    case cancelled

    public var description: String { diagnosticDescription }

    /// Safe to log: contains no credentials.
    public var diagnosticDescription: String {
        switch self {
        case .cannotResolveHost(let host):     return "cannotResolveHost(\(host))"
        case .connectionFailed(let detail):    return "connectionFailed(\(detail))"
        case .connectionTimeout:               return "connectionTimeout"
        case .tlsFailed(let detail):           return "tlsFailed(\(detail))"
        case .authenticationRequired:          return "authenticationRequired"
        case .authenticationRejected:          return "authenticationRejected"
        case .unsupportedAuthMethod(let m):    return String(format: "unsupportedAuthMethod(0x%02x)", m)
        case .badServerResponse(let detail):   return "badServerResponse(\(detail))"
        case .proxyRefusedConnection(let r):   return "proxyRefusedConnection(\(r))"
        case .addressFamilyUnsupported:        return "addressFamilyUnsupported"
        case .protocolViolation(let detail):   return "protocolViolation(\(detail))"
        case .cancelled:                       return "cancelled"
        }
    }

    /// Whether a fresh attempt could succeed.
    public var isTransient: Bool {
        switch self {
        case .connectionFailed, .connectionTimeout, .cannotResolveHost: return true
        default: return false
        }
    }
}
