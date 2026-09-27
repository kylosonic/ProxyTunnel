//
//  HostValidator.swift
//  ProxyTunnelCore
//

import Foundation

/// What kind of thing the user typed into the "Host" field.
public enum HostKind: Equatable, Sendable {
    case ipv4(IPAddress)
    case ipv6(IPAddress)
    case hostname(String)

    public var isLiteral: Bool {
        switch self {
        case .ipv4, .ipv6: return true
        case .hostname:    return false
        }
    }

    /// Value sent to a proxy in a CONNECT request / SOCKS5 request when the
    /// protocol supports passing a name through (remote DNS).
    public var wireValue: String {
        switch self {
        case .ipv4(let a), .ipv6(let a): return a.description
        case .hostname(let h):           return h
        }
    }
}

public struct HostValidation: Equatable, Sendable {
    public let sanitized: String
    public let kind: HostKind?
    public let issues: [ValidationIssue]

    public var isValid: Bool { !issues.contains { $0.severity == .error } }
}

/// Validates and normalises the proxy host field.
///
/// Accepts:
///   * IPv4 literals            `203.0.113.7`
///   * IPv6 literals            `2001:db8::1`, `[2001:db8::1]`
///   * DNS host names           `proxy.example.com`
///
/// Explicitly rejects, with an actionable message:
///   * empty input
///   * anything with a URL scheme (`socks5://host`) — the protocol is a separate
///     field, and silently accepting a scheme would hide a real mistake
///   * embedded credentials (`user:pass@host`)
///   * a trailing port or path (`host:1080`, `host/path`)
///   * control characters and embedded whitespace
public enum HostValidator {

    /// RFC 1035 limits a fully-qualified name to 255 octets on the wire; 253 is
    /// the practical textual limit.
    public static let maxHostnameLength = 253
    public static let maxLabelLength = 63

    public static func validate(_ raw: String) -> HostValidation {
        var issues: [ValidationIssue] = []
        var text = Sanitizer.clean(raw)

        // ---- empty -------------------------------------------------------
        guard !text.isEmpty else {
            return HostValidation(
                sanitized: "",
                kind: nil,
                issues: [.error(.host, "Host is required.")]
            )
        }

        // ---- control characters -----------------------------------------
        if Sanitizer.containsControlCharacters(text) {
            issues.append(.error(.host, "Host contains control characters."))
            text = text.unicodeScalars.filter { $0.value >= 0x20 && !(0x7F...0x9F).contains($0.value) }
                .reduce(into: "") { $0.unicodeScalars.append($1) }
        }

        // ---- embedded credentials ---------------------------------------
        if let at = text.lastIndex(of: "@"), !text.hasSuffix("@") {
            let userInfo = text[text.startIndex..<at]
            if userInfo.contains(":") || !userInfo.isEmpty {
                issues.append(.error(
                    .host,
                    "Remove \"\(userInfo)@\" from the host. Enter the username and password in their own fields."
                ))
                text = String(text[text.index(after: at)...])
            }
        }

        // ---- URL scheme --------------------------------------------------
        if let schemeRange = text.range(of: "://") {
            let scheme = String(text[text.startIndex..<schemeRange.lowerBound]).lowercased()
            issues.append(.warning(
                .host,
                "Removed the \"\(scheme)://\" prefix. The protocol is chosen in the Protocol field; the host is stored on its own."
            ))
            text = String(text[schemeRange.upperBound...])
        }

        // ---- path / query ------------------------------------------------
        if let slash = text.firstIndex(of: "/") {
            issues.append(.warning(.host, "Removed the path \"/\(text[text.index(after: slash)...])\" from the host."))
            text = String(text[text.startIndex..<slash])
        }
        if let query = text.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            text = String(text[text.startIndex..<query])
            issues.append(.warning(.host, "Removed the query string from the host."))
        }

        // ---- embedded whitespace ----------------------------------------
        if text.contains(where: { $0 == " " || $0 == "\t" }) {
            issues.append(.error(.host, "Host must not contain spaces."))
            text = text.replacingOccurrences(of: " ", with: "")
            text = text.replacingOccurrences(of: "\t", with: "")
        }

        // ---- bracketed IPv6 ---------------------------------------------
        var bracketed = false
        if text.hasPrefix("[") && text.hasSuffix("]") && text.count > 2 {
            bracketed = true
            text = String(text.dropFirst().dropLast())
        }

        // ---- trailing port in the host field ----------------------------
        // Careful: IPv6 literals legitimately contain colons, so only treat a
        // single colon as a port separator.
        if !bracketed, text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
            let maybePort = String(text[text.index(after: colon)...])
            if !maybePort.isEmpty, Int(maybePort) != nil {
                issues.append(.error(
                    .host,
                    "Host must not include a port. Put \(maybePort) in the Port field and keep the host as \"\(text[text.startIndex..<colon])\"."
                ))
                text = String(text[text.startIndex..<colon])
            }
        }

        guard !text.isEmpty else {
            issues.append(.error(.host, "Host is required."))
            return HostValidation(sanitized: "", kind: nil, issues: issues)
        }

        // ---- IP literals -------------------------------------------------
        if let ip = IPAddress(presentationName: text) {
            if ip.isUnspecified {
                issues.append(.error(.host, "\(ip.description) is not a usable proxy address."))
            } else if ip.isMulticast {
                issues.append(.error(.host, "\(ip.description) is a multicast address, not a proxy."))
            } else if ip.isLoopback {
                issues.append(.warning(
                    .host,
                    "\(ip.description) is the local loopback address. Inside the tunnel this points at your own device, not at a proxy."
                ))
            } else if ip.isLinkLocal {
                issues.append(.warning(
                    .host,
                    "\(ip.description) is a link-local address; it is only reachable on the local network and cannot be used from cellular."
                ))
            }
            return HostValidation(sanitized: ip.description, kind: ip.isIPv6 ? .ipv6(ip) : .ipv4(ip), issues: issues)
        }

        // ---- something that looks like a broken IPv4 literal -------------
        if text.allSatisfy({ $0.isNumber || $0 == "." }), text.contains(".") {
            issues.append(.error(
                .host,
                "\"\(text)\" is not a valid IPv4 address. Check the octets (each must be 0-255)."
            ))
            return HostValidation(sanitized: text, kind: nil, issues: issues)
        }

        // ---- host name ---------------------------------------------------
        let lowered = text.lowercased()
        if lowered.count > maxHostnameLength {
            issues.append(.error(.host, "Host name is longer than \(maxHostnameLength) characters."))
        }
        if lowered.contains("..") {
            issues.append(.error(.host, "Host name contains an empty label (\"..\")."))
        }

        let labels = lowered.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        for label in labels where !label.isEmpty {
            if label.count > maxLabelLength {
                issues.append(.error(.host, "The label \"\(label)\" is longer than \(maxLabelLength) characters."))
            }
            if label.hasPrefix("-") || label.hasSuffix("-") {
                issues.append(.error(.host, "The label \"\(label)\" must not start or end with a hyphen."))
            }
            let allowed = label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
            if !allowed {
                if label.contains("_") {
                    issues.append(.warning(
                        .host,
                        "The label \"\(label)\" contains an underscore, which is not valid in a DNS host name but is sometimes used by internal proxies."
                    ))
                } else if label.contains(where: { !$0.isASCII }) {
                    issues.append(.warning(
                        .host,
                        "The label \"\(label)\" contains non-ASCII characters. DNS will need it in punycode (xn--) form on some networks."
                    ))
                } else {
                    issues.append(.error(.host, "The label \"\(label)\" contains characters that are not allowed in a host name."))
                }
            }
        }

        let nonEmptyLabels = labels.filter { !$0.isEmpty }
        if nonEmptyLabels.count == 1 {
            issues.append(.warning(
                .host,
                "Single-label host names only resolve on networks that provide a local search domain. If this is a public proxy, enter its full name."
            ))
        }
        if lowered.hasSuffix(".local") {
            issues.append(.warning(
                .host,
                "\".local\" names are resolved with multicast DNS on the local network and cannot be reached through a remote proxy."
            ))
        }
        if lowered == "localhost" {
            issues.append(.warning(.host, "\"localhost\" refers to the iPhone itself, not to a remote proxy."))
        }
        if lowered.contains(where: { !$0.isASCII }) {
            // Non-ASCII whole-name (IDN). getaddrinfo handles UTF-8, but be explicit.
            issues.append(.warning(.host, "Internationalised host names depend on the network's resolver supporting them."))
        }

        return HostValidation(sanitized: lowered, kind: .hostname(lowered), issues: issues)
    }
}
