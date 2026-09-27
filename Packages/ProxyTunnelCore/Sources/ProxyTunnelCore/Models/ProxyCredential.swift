//
//  ProxyCredential.swift
//  ProxyTunnelCore
//

import Foundation

/// An in-memory username/password pair.
///
/// The password only ever exists in memory (in the app process while the user
/// types it, and in the extension process for the lifetime of a tunnel). It is
/// persisted exclusively through `SecretStoring`, i.e. the iOS Keychain.
///
/// `description` and `debugDescription` are overridden so that string
/// interpolation can never leak the password.
public struct ProxyCredential: Codable, Equatable, Sendable {

    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    /// `user:••••••`, safe for logs.
    public var redacted: String {
        "\(LogRedactor.maskUsername(username)):\(LogRedactor.maskSecret())"
    }
}

extension ProxyCredential: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "ProxyCredential(\(redacted))" }
    public var debugDescription: String { description }
}

// MARK: - Redaction helpers

/// Central place for every "do not log this" rule.
///
/// The tunnel logs a lot (packets, handshakes, errors). Rather than trusting
/// each call site to remember what is sensitive, all log lines are funnelled
/// through `LogRedactor.redact(_:)` before they are stored.
public enum LogRedactor {

    /// The literal string substituted for a secret.
    public static let mask = "••••••"

    /// Masks a secret entirely. Used for passwords and tokens.
    public static func maskSecret() -> String { mask }

    /// Shows only the first and last character of a username so the operator can
    /// correlate log lines without exposing the whole identity.
    public static func maskUsername(_ username: String?) -> String {
        guard let username, !username.isEmpty else { return "<none>" }
        if username.count <= 2 { return String(repeating: "•", count: username.count) }
        return "\(username.first!)•••\(username.last!)"
    }

    /// Masks the user-info portion of a URL-like string: `user:pass@host` ->
    /// `u•••r:••••••@host`.
    public static func maskUserInfo(_ value: String) -> String {
        guard let at = value.lastIndex(of: "@") else { return value }
        let userInfo = value[value.startIndex..<at]
        guard let colon = userInfo.firstIndex(of: ":") else {
            return maskUsername(String(userInfo)) + String(value[at...])
        }
        let user = String(userInfo[userInfo.startIndex..<colon])
        return maskUsername(user) + ":" + mask + String(value[at...])
    }

    /// Patterns that are scrubbed out of any message before it is persisted.
    /// Order matters: more specific patterns first.
    private static let rules: [(pattern: String, replacement: String)] = [
        // proxy-user:proxy-pass@host   (also matches http://user:pass@host)
        (#"(?<=//)[^/\s:@]+:[^/\s@]+(?=@)"#, mask),
        // Free-form "password=..." / "passwd: ..." / "token=..."
        (#"(?i)\b(password|passwd|pwd|secret|token|apikey|api_key|authorization)\b\s*[:=]\s*("[^"]*"|'[^']*'|[^\s,;&]+)"#, "$1=" + mask),
        // HTTP Basic / other base64 auth blobs
        (#"(?i)\b(Proxy-Authorization|Authorization)\s*:\s*\S+"#, "$1: " + mask),
        // SOCKS5 RFC1929 style verbose dumps
        (#"(?i)\b(username|user)\b\s*[:=]\s*("[^"]*"|'[^']*'|[^\s,;&]+)"#, "$1=" + mask),
        // Long hex/base64 blobs that look like keys (>= 32 chars)
        (#"\b[A-Za-z0-9+/]{32,}={0,2}\b"#, mask)
    ]

    private static let compiled: [NSRegularExpression] = rules.compactMap {
        try? NSRegularExpression(pattern: $0.pattern, options: [])
    }

    /// Returns `message` with every credential-like substring replaced.
    ///
    /// This is intentionally belt-and-braces: callers should already avoid
    /// logging secrets, but this guarantees it.
    public static func redact(_ message: String) -> String {
        var result = message
        for (index, rule) in rules.enumerated() {
            guard index < compiled.count else { continue }
            let regex = compiled[index]
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: rule.replacement
            )
        }
        return result
    }
}
