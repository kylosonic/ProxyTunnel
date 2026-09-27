//
//  ProxyProtocol.swift
//  ProxyTunnelCore
//

import Foundation

/// The proxy protocols this app can speak.
///
/// The capabilities reported here are deliberately conservative and match what
/// the client implementations in `Sources/ProxyTunnelCore/Proxy` actually do.
/// See `docs/PROXY-PROTOCOLS.md` for the long-form discussion.
public enum ProxyProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    /// SOCKS5, RFC 1928, with username/password auth per RFC 1929.
    case socks5 = "socks5"

    /// Plain HTTP proxy using the CONNECT method (RFC 9110 §9.3.6).
    case httpConnect = "http-connect"

    /// TLS-wrapped HTTP proxy: a normal CONNECT exchange carried inside a TLS
    /// session established with the *proxy* itself.
    case httpsConnect = "https-connect"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .socks5:       return "SOCKS5"
        case .httpConnect:  return "HTTP CONNECT"
        case .httpsConnect: return "HTTPS CONNECT"
        }
    }

    public var shortDescription: String {
        switch self {
        case .socks5:
            return "Full TCP proxying with remote name resolution, plus UDP relaying."
        case .httpConnect:
            return "TCP tunnelling through an HTTP CONNECT proxy. No UDP."
        case .httpsConnect:
            return "Same as HTTP CONNECT, but the connection to the proxy is TLS-encrypted."
        }
    }

    /// Conventional default port offered in the "add proxy" form.
    public var defaultPort: Int {
        switch self {
        case .socks5:       return 1080
        case .httpConnect:  return 8080
        case .httpsConnect: return 443
        }
    }

    /// Whether the tunnel can carry TCP streams over this protocol.
    /// All three can: that is their whole purpose.
    public var supportsTCP: Bool { true }

    /// Whether the tunnel can carry UDP datagrams.
    ///
    /// Only SOCKS5 can, via the UDP ASSOCIATE command (RFC 1928 §7). HTTP
    /// CONNECT has no mechanism for relaying datagrams, so with an HTTP or
    /// HTTPS proxy all non-DNS UDP is dropped by the tunnel. DNS itself still
    /// works because the tunnel terminates UDP:53 locally and re-issues the
    /// query as DNS-over-TCP through the proxy.
    public var supportsUDP: Bool {
        switch self {
        case .socks5:                      return true
        case .httpConnect, .httpsConnect:  return false
        }
    }

    /// Whether a TLS handshake is performed with the proxy before proxying.
    public var usesTLS: Bool { self == .httpsConnect }

    /// Whether the protocol lets the *proxy* perform name resolution, which is
    /// what keeps DNS from leaking to the local network.
    public var supportsRemoteNameResolution: Bool { true }

    /// Whether username/password authentication is defined by the protocol.
    public var supportsAuthentication: Bool { true }
}

// MARK: - Capability matrix

/// A printable summary of one protocol's capabilities. Used by the UI and by
/// the diagnostics screen so that what we tell the user is exactly what the
/// code does.
public struct ProxyProtocolCapabilities: Identifiable, Sendable {
    public let protocolType: ProxyProtocol
    public let tcp: String
    public let udp: String
    public let dns: String
    public let ipv4: String
    public let ipv6: String
    public let notes: [String]

    public var id: String { protocolType.rawValue }

    public static func describe(_ p: ProxyProtocol) -> ProxyProtocolCapabilities {
        switch p {
        case .socks5:
            return ProxyProtocolCapabilities(
                protocolType: p,
                tcp: "Yes - full stream tunnelling via CONNECT",
                udp: "Yes - via UDP ASSOCIATE (RFC 1928 §7). Fragmented datagrams (FRAG != 0) are dropped.",
                dns: "UDP:53 relayed to the proxy's UDP relay. With \"remote DNS\" enabled the proxy performs resolution.",
                ipv4: "Yes - CONNECT with ATYP=1, and IPv4 targets through the UDP relay",
                ipv6: "Yes - CONNECT with ATYP=4, and IPv6 targets through the UDP relay, but only if the proxy itself supports IPv6",
                notes: [
                    "Preferred protocol: it is the only one of the three that can carry UDP.",
                    "SOCKS5 has no built-in confidentiality. Credentials and payload are in the clear between the device and the proxy unless you tunnel it yourself.",
                    "FRAG support is optional in RFC 1928 and almost never implemented; this client requires FRAG=0."
                ]
            )
        case .httpConnect:
            return ProxyProtocolCapabilities(
                protocolType: p,
                tcp: "Yes - full stream tunnelling via the CONNECT method",
                udp: "No - HTTP CONNECT has no datagram relay. Non-DNS UDP is dropped by the tunnel.",
                dns: "UDP:53 is terminated inside the tunnel and re-issued as DNS-over-TCP through the proxy, so queries still do not leak.",
                ipv4: "Yes - CONNECT to a dotted-quad authority",
                ipv6: "Yes - CONNECT to a bracketed [v6] authority, if the proxy supports it",
                notes: [
                    "Only plaintext HTTP CONNECT is supported on the wire; the payload inside the tunnel is untouched.",
                    "QUIC/HTTP-3 and other UDP applications will not work through an HTTP CONNECT proxy.",
                    "Credentials use HTTP Basic auth in the Proxy-Authorization header, so use an HTTPS proxy if the proxy is not on a trusted network."
                ]
            )
        case .httpsConnect:
            return ProxyProtocolCapabilities(
                protocolType: p,
                tcp: "Yes - TCP connection to the proxy is wrapped in TLS, then CONNECT runs inside it",
                udp: "No - same limitation as plain HTTP CONNECT",
                dns: "Terminated in-tunnel and re-issued as DNS-over-TCP inside the TLS session",
                ipv4: "Yes",
                ipv6: "Yes, if the proxy publishes an IPv6 address and your network can reach it",
                notes: [
                    "The certificate is validated against the system trust store using the proxy hostname as the SNI/verification name.",
                    "Use this when the proxy provider advertises an \"HTTPS proxy\" or \"TLS proxy\" endpoint.",
                    "This is NOT the same thing as an HTTP proxy that happens to listen on port 443."
                ]
            )
        }
    }
}
