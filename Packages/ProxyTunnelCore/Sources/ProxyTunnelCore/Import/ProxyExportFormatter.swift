//
//  ProxyExportFormatter.swift
//  ProxyTunnelCore
//
//  The other half of the interchange module: turn a stored profile into something
//  another app can consume.
//
//  ## Why this exists
//
//  On a build whose signature lacks the Network Extension entitlement, this app
//  cannot run a packet tunnel — but plenty of App Store apps can, because *their*
//  developers hold that entitlement and shipped it. The useful thing this app can
//  do in that situation is hand the proxy over in a shape those apps accept.
//
//  ## Formats, and why only these three
//
//    * **Share link** — `socks5://user:pass@host:1080#Name`. Nearly every proxy
//      client accepts one of these in its "add" or "import" box. It is the most
//      portable thing here and the one to reach for first.
//    * **Outbound object** — the single JSON block that sing-box, Stash, Loon and
//      their relatives use to describe an outbound proxy.
//    * **Plain fields** — labelled lines for clients that only offer a form.
//
//  A *complete* sing-box configuration is deliberately not generated. Its schema
//  has changed across releases (`inet4_address` became `address`, `sniff: true`
//  became a route action, `"outbound": "dns-out"` became `hijack-dns`), and the
//  apps that embed it — Hiddify and friends — layer their own format on top. A
//  generated full config would be wrong for somebody's version and would look
//  authoritative while being wrong. The outbound block is the part that has stayed
//  stable, so that is what is offered, and the app says so.
//
//  ## Secrets
//
//  An export contains the password in plain text, because that is the entire point
//  of moving a proxy into another app. `includePassword` defaults to `true` so the
//  result actually works, the UI states plainly what it contains, and the
//  alternative is one toggle away. Nothing here is ever logged.
//

import Foundation

public enum ProxyExportFormat: String, CaseIterable, Identifiable, Sendable {
    case shareLink
    case singBoxOutbound
    case plainFields

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .shareLink:       return "Share link"
        case .singBoxOutbound: return "Outbound block (JSON)"
        case .plainFields:     return "Plain fields"
        }
    }

    public var subtitle: String {
        switch self {
        case .shareLink:
            return "Paste into the Add or Import box of almost any proxy client."
        case .singBoxOutbound:
            return "One JSON object for sing-box, Stash, Loon and similar. Add it to the outbounds list of a config your app generates."
        case .plainFields:
            return "Labelled values, for a client that only offers a manual form."
        }
    }

    public var fileExtension: String {
        self == .singBoxOutbound ? "json" : "txt"
    }
}

public struct ProxyExportOptions: Equatable, Sendable {

    /// Whether to include the password.
    ///
    /// Defaults to `true`: an export without it is not usable, which is the point
    /// of exporting. The UI states what the text contains before it is copied.
    public var includePassword: Bool

    /// Optional override for the name carried in a share link's fragment and used
    /// as the outbound tag.
    public var nameOverride: String?

    public init(includePassword: Bool = true, nameOverride: String? = nil) {
        self.includePassword = includePassword
        self.nameOverride = nameOverride
    }
}

public enum ProxyExportFormatter {

    /// Renders `profile` in `format`.
    ///
    /// - Parameter credential: the password, from the Keychain. Pass `nil` for a
    ///   profile that needs no authentication.
    public static func text(
        for profile: ProxyProfile,
        credential: ProxyCredential?,
        format: ProxyExportFormat,
        options: ProxyExportOptions = ProxyExportOptions()
    ) -> String {
        let name = options.nameOverride ?? profile.name
        let password = options.includePassword ? credential?.password : nil

        switch format {
        case .shareLink:
            return shareLink(for: profile, username: credential?.username, password: password, name: name)
        case .singBoxOutbound:
            return singBoxOutbound(for: profile, username: credential?.username, password: password, tag: name)
        case .plainFields:
            return plainFields(for: profile, username: credential?.username, password: password)
        }
    }

    // MARK: Share link

    /// `scheme://user:pass@host:port#Name`
    ///
    /// The scheme mapping matches what the importer understands, so a link this
    /// produces can be pasted straight back in — which is what the round-trip test
    /// checks.
    public static func shareLink(
        for profile: ProxyProfile,
        username: String?,
        password: String?,
        name: String?
    ) -> String {
        let scheme: String
        switch profile.protocolType {
        case .socks5:       scheme = "socks5"
        case .httpConnect:  scheme = "http"
        case .httpsConnect: scheme = "https"
        }

        var link = "\(scheme)://"

        if let username, !username.isEmpty {
            link += percentEncode(username)
            if let password, !password.isEmpty {
                link += ":" + percentEncode(password)
            }
            link += "@"
        }

        link += authority(host: profile.host, port: profile.port)

        if let name, !name.isEmpty {
            link += "#" + percentEncode(name)
        }
        return link
    }

    // MARK: sing-box outbound

    /// A single outbound object, pretty-printed.
    ///
    /// Built as a dictionary and serialised by `JSONSerialization` rather than
    /// assembled as a string, so the output is valid JSON by construction.
    public static func singBoxOutbound(
        for profile: ProxyProfile,
        username: String?,
        password: String?,
        tag: String
    ) -> String {
        var outbound: [String: Any] = [
            "type": profile.protocolType == .socks5 ? "socks" : "http",
            "tag": tag.isEmpty ? "proxy" : tag,
            "server": profile.host,
            "server_port": profile.port
        ]

        if profile.protocolType == .socks5 {
            // `version` distinguishes SOCKS5 from SOCKS4; sing-box defaults to 5 but
            // states it explicitly here so the intent is unambiguous.
            outbound["version"] = "5"
        }

        if let username, !username.isEmpty {
            outbound["username"] = username
            if let password, !password.isEmpty {
                outbound["password"] = password
            }
        }

        if profile.protocolType == .httpsConnect {
            // sing-box has no separate "https proxy" type: TLS to the proxy is an
            // HTTP outbound with a TLS block.
            outbound["tls"] = [
                "enabled": true,
                "server_name": profile.host
            ] as [String: Any]
        }

        return serialise(outbound)
    }

    // MARK: Plain fields

    public static func plainFields(
        for profile: ProxyProfile,
        username: String?,
        password: String?
    ) -> String {
        var lines: [String] = []
        lines.append("Name:     \(profile.name)")
        lines.append("Protocol: \(profile.protocolType.displayName)")
        lines.append("Server:   \(profile.host)")
        lines.append("Port:     \(profile.port)")
        lines.append("Username: \(username ?? "(none)")")
        if let password, !password.isEmpty {
            lines.append("Password: \(password)")
        } else if username != nil {
            lines.append("Password: (not included)")
        } else {
            lines.append("Password: (none)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    /// `host:port`, with an IPv6 literal bracketed.
    static func authority(host: String, port: Int) -> String {
        if let address = IPAddress(presentationName: host) {
            return address.authority(port: UInt16(clamping: port))
        }
        return "\(host):\(port)"
    }

    /// RFC 3986 percent-encoding for a URL component: everything except the
    /// unreserved set is escaped, which is stricter than necessary for userinfo but
    /// is the safe direction to be wrong in.
    static func percentEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    static let unreserved: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return set
    }()

    static func serialise(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
