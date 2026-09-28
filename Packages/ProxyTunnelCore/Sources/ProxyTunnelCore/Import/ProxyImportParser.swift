//
//  ProxyImportParser.swift
//  ProxyTunnelCore
//
//  Turns pasted text into proxy profiles.
//
//  Providers hand out credentials in whatever shape their control panel happens
//  to use, and they are all different. Rather than making the user reshape their
//  data, this parser accepts every common form and reports what it understood, so
//  a mistake is visible before anything is saved.
//
//  ── Formats accepted ─────────────────────────────────────────────────────────
//
//    socks5://user:pass@host:1080          scheme form (socks5h / socks accepted)
//    http://user:pass@host:8080            http / https map to the CONNECT protocols
//    https://user:pass@host:443
//    user:pass@host:1080                   credentials first
//    host:1080@user:pass                   host first
//    host:1080:user:pass                   colon-separated (very common)
//    user:pass:host:1080                   colon-separated, credentials first
//    host:1080                             no authentication
//    host:1080 user pass                   whitespace / comma / semicolon separated
//    host=1.2.3.4 port=8080 user=u pass=p  key=value or key: value
//    {"host":"1.2.3.4","port":8080,...}    JSON object, an array, or {"proxies":[...]}
//    Frankfurt | socks5://user:pass@host:1080    a label before a "|"
//
//  Blank lines and lines starting with `#`, `//` or `;` are ignored, so a
//  provider's comment header can be pasted along with the list.
//
//  ── Ambiguity ────────────────────────────────────────────────────────────────
//
//  `a:b:c:d` genuinely has two readings. Every plausible reading is scored — an IP
//  literal beats a dotted name, which beats a single label — and the best one wins.
//  Where two readings tie, the host-first reading is chosen because that is what
//  proxy providers overwhelmingly use, and the entry says so.
//
//  ── Secrets ──────────────────────────────────────────────────────────────────
//
//  A pasted line contains a password. Nothing here writes one to a log, and
//  `ProxyImportEntry.redactedSource` is what the UI and the diagnostics show.
//

import Foundation

// MARK: - Results

/// One successfully understood proxy.
public struct ProxyImportCandidate: Equatable, Sendable {

    public var name: String?
    public var host: String
    public var port: Int
    public var protocolType: ProxyProtocol
    public var username: String?
    public var password: String?

    /// Whether the protocol came from the text itself (`socks5://`) rather than
    /// from the picker or a guess about the port.
    public var protocolWasExplicit: Bool

    /// How the text was read, and anything the user should double-check.
    public var notes: [String]

    /// `true` when the reading was ambiguous and the host-first interpretation was
    /// assumed.
    public var isAmbiguous: Bool

    public init(
        name: String? = nil,
        host: String,
        port: Int,
        protocolType: ProxyProtocol,
        username: String? = nil,
        password: String? = nil,
        protocolWasExplicit: Bool = false,
        notes: [String] = [],
        isAmbiguous: Bool = false
    ) {
        self.name = name
        self.host = host
        self.port = port
        self.protocolType = protocolType
        self.username = username
        self.password = password
        self.protocolWasExplicit = protocolWasExplicit
        self.notes = notes
        self.isAmbiguous = isAmbiguous
    }

    public var displayEndpoint: String {
        ProxyProfile.formatEndpoint(host: host, port: port)
    }

    /// A log-safe one-liner. Never contains the password.
    public var redactedDescription: String {
        "\(protocolType.rawValue) \(displayEndpoint) user=\(LogRedactor.maskUsername(username)) hasPassword=\(password != nil)"
    }

    /// Turns the parsed values into the form model, so that the same validator the
    /// manual form uses decides whether the proxy is storable. One source of truth
    /// for what a valid profile is.
    public func asDraft(suggestedName: String? = nil) -> ProxyProfileDraft {
        ProxyProfileDraft(
            name: suggestedName ?? name ?? displayEndpoint,
            host: host,
            portText: String(port),
            protocolType: protocolType,
            username: username ?? "",
            password: password ?? ""
        )
    }
}

/// Why a line could not be turned into a proxy.
public enum ProxyImportFailure: Equatable, Sendable {
    case empty
    case comment
    case unrecognised(String)
    case hostProblem(String)
    case portProblem(String)
    case jsonProblem(String)
    case unsupportedScheme(String)

    public var message: String {
        switch self {
        case .empty:
            return "Nothing on this line."
        case .comment:
            return "Comment."
        case .unrecognised(let detail):
            return "Could not find a host and port here. \(detail)"
        case .hostProblem(let detail):
            return "Host problem: \(detail)"
        case .portProblem(let detail):
            return "Port problem: \(detail)"
        case .jsonProblem(let detail):
            return "Could not read this as JSON: \(detail)"
        case .unsupportedScheme(let scheme):
            return "\"\(scheme)\" proxies are not supported. Use SOCKS5, HTTP CONNECT or HTTPS CONNECT."
        }
    }
}

public struct ProxyImportEntry: Equatable, Sendable, Identifiable {

    /// Line number in the pasted text, 1-based. Stable enough to use as an id.
    public let id: Int
    public let lineNumber: Int
    /// The line as the UI and the log may show it: credentials masked.
    public let redactedSource: String
    public let candidate: ProxyImportCandidate?
    public let failure: ProxyImportFailure?

    public init(
        lineNumber: Int,
        redactedSource: String,
        candidate: ProxyImportCandidate?,
        failure: ProxyImportFailure?
    ) {
        self.id = lineNumber
        self.lineNumber = lineNumber
        self.redactedSource = redactedSource
        self.candidate = candidate
        self.failure = failure
    }

    public var isReady: Bool { candidate != nil }
    public var isIgnorable: Bool { failure == .empty || failure == .comment }
}

public struct ProxyImportReport: Equatable, Sendable {

    public let entries: [ProxyImportEntry]
    /// The protocol the picker was set to, or `nil` for auto-detection.
    public let requestedProtocol: ProxyProtocol?

    public init(entries: [ProxyImportEntry], requestedProtocol: ProxyProtocol? = nil) {
        self.entries = entries
        self.requestedProtocol = requestedProtocol
    }

    public var ready: [ProxyImportEntry] { entries.filter(\.isReady) }
    public var problems: [ProxyImportEntry] { entries.filter { !$0.isReady && !$0.isIgnorable } }
    public var ignored: [ProxyImportEntry] { entries.filter(\.isIgnorable) }

    public var isEmpty: Bool { entries.isEmpty }
    public var hasProblems: Bool { !problems.isEmpty }

    public var summary: String {
        if entries.isEmpty { return "Nothing to import yet." }
        var parts: [String] = []
        parts.append("\(ready.count) ready")
        if !problems.isEmpty { parts.append("\(problems.count) need attention") }
        if !ignored.isEmpty { parts.append("\(ignored.count) ignored") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Parser

public enum ProxyImportParser {

    /// Parses a pasted blob, one proxy per line.
    ///
    /// - Parameter defaultProtocol: the protocol to use when a line does not carry
    ///   one. Pass `nil` to infer it from the port.
    public static func parse(_ text: String, defaultProtocol: ProxyProtocol? = nil) -> ProxyImportReport {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // A paste that is a single JSON document does not map onto "one proxy per
        // line", so it is handled first.
        if trimmedText.hasPrefix("{") || trimmedText.hasPrefix("[") {
            if let document = parseJSONDocument(trimmedText, defaultProtocol: defaultProtocol), !document.isEmpty {
                return ProxyImportReport(entries: document, requestedProtocol: defaultProtocol)
            }
        }

        let lines = trimmedText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var entries: [ProxyImportEntry] = []
        for (index, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            entries.append(parseLine(trimmed, lineNumber: index + 1, defaultProtocol: defaultProtocol))
        }

        return ProxyImportReport(entries: entries, requestedProtocol: defaultProtocol)
    }

    /// Parses one line.
    public static func parseLine(
        _ rawLine: String,
        lineNumber: Int = 1,
        defaultProtocol: ProxyProtocol? = nil
    ) -> ProxyImportEntry {

        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

        func failure(_ reason: ProxyImportFailure, source: String? = nil) -> ProxyImportEntry {
            ProxyImportEntry(
                lineNumber: lineNumber,
                redactedSource: source ?? LogRedactor.redact(trimmed),
                candidate: nil,
                failure: reason
            )
        }

        if trimmed.isEmpty { return failure(.empty, source: "") }

        // Comments: providers often include a header block.
        if trimmed.hasPrefix("#") || trimmed.hasPrefix("//") || trimmed.hasPrefix(";") {
            return failure(.comment, source: trimmed)
        }

        // A JSON object on its own line.
        if trimmed.hasPrefix("{") {
            if let candidate = parseJSONObject(trimmed, defaultProtocol: defaultProtocol) {
                return ProxyImportEntry(
                    lineNumber: lineNumber,
                    redactedSource: "JSON object",
                    candidate: candidate,
                    failure: nil
                )
            }
            return failure(.jsonProblem("the line starts with { but is not a recognisable proxy object"))
        }

        // `Label | spec`
        var label: String?
        var body = trimmed
        if let pipe = trimmed.firstIndex(of: "|") {
            let before = String(trimmed[trimmed.startIndex..<pipe]).trimmingCharacters(in: .whitespaces)
            let after = String(trimmed[trimmed.index(after: pipe)...]).trimmingCharacters(in: .whitespaces)
            if !after.isEmpty, !before.isEmpty {
                label = before
                body = after
            }
        }

        switch interpret(body, defaultProtocol: defaultProtocol) {
        case .success(let interpretation):
            var candidate = interpretation.asCandidate()
            if let label { candidate.name = label }
            return ProxyImportEntry(
                lineNumber: lineNumber,
                redactedSource: redactLine(trimmed, password: candidate.password),
                candidate: candidate,
                failure: nil
            )
        case .failure(let reason):
            return failure(reason)
        }
    }

    /// Masks the credential portion of a line for display.
    ///
    /// The recognisable parts (host, port, protocol, username) stay readable,
    /// because being able to see what was understood is the whole point of the
    /// preview. Anything that was read as a password becomes `••••••`, and the
    /// redactor's own rules are applied on top for the URL forms.
    static func redactLine(_ line: String, password: String?) -> String {
        var output = line
        if let password, !password.isEmpty {
            if output.contains(password) {
                output = output.replacingOccurrences(of: password, with: LogRedactor.mask)
            }
            if let encoded = password.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
               output.contains(encoded) {
                output = output.replacingOccurrences(of: encoded, with: LogRedactor.mask)
            }
        }
        return LogRedactor.redact(output)
    }
}

// MARK: - Interpretation

extension ProxyImportParser {

    struct Interpretation {
        var host: String
        var port: Int
        var username: String?
        var password: String?
        var protocolType: ProxyProtocol
        var protocolWasExplicit: Bool
        var notes: [String]
        var shape: String
        /// Tie-break preference: host-first readings win.
        var prefersHostFirst: Bool
        var isAmbiguous: Bool = false

        /// An IP literal is a much stronger signal than a single label, which is
        /// what resolves `a:b:c:d` in practice.
        var score: Int {
            hostStrength(host) * 10 + (prefersHostFirst ? 1 : 0)
        }

        func asCandidate() -> ProxyImportCandidate {
            ProxyImportCandidate(
                name: nil,
                host: host,
                port: port,
                protocolType: protocolType,
                username: username,
                password: password,
                protocolWasExplicit: protocolWasExplicit,
                notes: notes,
                isAmbiguous: isAmbiguous
            )
        }
    }

    enum Outcome {
        case success(Interpretation)
        case failure(ProxyImportFailure)
    }

    /// How much the text looks like a host; 0 when it does not.
    static func hostStrength(_ text: String) -> Int {
        let result = HostValidator.validate(text)
        guard result.isValid, let kind = result.kind else { return 0 }
        switch kind {
        case .ipv4, .ipv6: return 3
        case .hostname(let name): return name.contains(".") ? 2 : 1
        }
    }

    /// Canonicalises a host so that a pasted `[2001:db8::1]` or `Example.COM` is
    /// stored exactly as the manual form would store it. The manual form runs the
    /// same validator, so the two entry points cannot drift apart.
    static func normalisedHost(_ raw: String) -> String {
        let validation = HostValidator.validate(raw)
        return validation.isValid ? validation.sanitized : raw
    }

    static func interpret(_ raw: String, defaultProtocol: ProxyProtocol?) -> Outcome {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tolerate surrounding quotes and backticks from chat messages and docs.
        while let first = text.first, "\"'`“”‘’".contains(first) { text.removeFirst() }
        while let last = text.last, "\"'`“”‘’".contains(last) { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }

        // 1. An explicit scheme: the least ambiguous case, so try it first.
        if let result = interpretWithScheme(text, defaultProtocol: defaultProtocol) {
            return result
        }

        // 2. Key=value / key: value pairs.
        if let interpretation = interpretKeyValue(text, defaultProtocol: defaultProtocol) {
            return .success(interpretation)
        }

        // 3. Everything else: collect every plausible reading and pick the best.
        var interpretations: [Interpretation] = []
        interpretations.append(contentsOf: interpretAtForms(text, defaultProtocol: defaultProtocol))
        interpretations.append(contentsOf: interpretSeparatedForms(text, defaultProtocol: defaultProtocol))

        guard let best = interpretations.max(by: { $0.score < $1.score }) else {
            return .failure(.unrecognised(
                "Expected something like socks5://user:pass@host:1080, host:1080:user:pass, or host:1080."
            ))
        }

        // Surface the ambiguity rather than hiding it: the entry says what was
        // assumed, so a wrong guess is visible before anything is saved.
        let tied = interpretations.filter { $0.score == best.score && $0.shape != best.shape }
        var chosen = best
        if !tied.isEmpty {
            chosen.isAmbiguous = true
            chosen.notes.append(
                "This line could be read either way round; \(best.shape) was assumed. Check the host after adding."
            )
        }

        // A successful parse always has a usable host and an in-range port. This is
        // what makes the contract explicit rather than emergent from the scoring.
        let hostValidation = HostValidator.validate(chosen.host)
        if let error = hostValidation.issues.first(where: { $0.severity == .error }) {
            return .failure(.hostProblem(error.message))
        }
        guard PortValidator.range.contains(chosen.port) else {
            return .failure(.portProblem("\(chosen.port) is outside 1-65535"))
        }

        return .success(chosen)
    }

    // MARK: Scheme form

    static func interpretWithScheme(_ text: String, defaultProtocol: ProxyProtocol?) -> Outcome? {
        guard let separator = text.range(of: "://") else { return nil }
        let scheme = String(text[text.startIndex..<separator.lowerBound]).lowercased()
        var rest = String(text[separator.upperBound...])

        // Strip a path or query if one was pasted along with the URL.
        if let cut = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            rest = String(rest[rest.startIndex..<cut])
        }
        rest = rest.trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else {
            return .failure(.unrecognised("there is a scheme but no host after it"))
        }

        let schemeProtocol: ProxyProtocol?
        switch scheme {
        case "socks5", "socks5h", "socks":
            // `socks5h` means "resolve names at the proxy", which is what this
            // client always does for a name, so the two behave identically here.
            schemeProtocol = .socks5
        case "http", "http-connect", "httpconnect", "connect":
            schemeProtocol = .httpConnect
        case "https", "https-connect", "httpsconnect":
            schemeProtocol = .httpsConnect
        case "socks4", "socks4a":
            return .failure(.unsupportedScheme(scheme))
        default:
            schemeProtocol = nil
        }

        // Split credentials from the authority at the LAST "@": a password may
        // contain one, a host may not.
        var userInfo: String?
        var authority = rest
        if let at = rest.lastIndex(of: "@") {
            userInfo = String(rest[rest.startIndex..<at])
            authority = String(rest[rest.index(after: at)...])
        }

        let protocolType = schemeProtocol ?? defaultProtocol ?? .socks5
        var notes: [String] = []
        if schemeProtocol == nil {
            notes.append("Unrecognised scheme \"\(scheme)\"; \(protocolType.displayName) was used instead.")
        }

        guard let endpoint = splitHostPort(authority) else {
            return .failure(.unrecognised("\"\(authority)\" is not a host with a port"))
        }

        let port: Int
        if let parsed = endpoint.port {
            port = parsed
        } else {
            port = protocolType.defaultPort
            notes.append("No port given, so \(port) was used — the usual port for \(protocolType.displayName).")
        }

        var username: String?
        var password: String?
        if let userInfo, !userInfo.isEmpty {
            let parts = userInfo.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            username = decode(String(parts[0]))
            if parts.count > 1 { password = decode(String(parts[1])) }
        }

        notes.append(contentsOf: hostNotes(endpoint.host))

        return .success(Interpretation(
            host: endpoint.host,
            port: port,
            username: username,
            password: password,
            protocolType: protocolType,
            protocolWasExplicit: schemeProtocol != nil,
            notes: notes,
            shape: "\(scheme):// link",
            prefersHostFirst: true
        ))
    }

    // MARK: Key = value

    /// Keys that make a line "keyed" rather than positional. Used both to decide
    /// whether to attempt this strategy at all and to recognise the
    /// `key:value:key:value` layout.
    static let knownKeys: Set<String> = [
        "host", "hostname", "server", "ip", "address",
        "port", "username", "user", "userid", "login",
        "password", "pass", "passwd", "pwd",
        "protocol", "proto", "type", "scheme"
    ]

    static func isKnownKey(_ text: String) -> Bool {
        knownKeys.contains(text.trimmingCharacters(in: .whitespaces).lowercased())
    }

    static func interpretKeyValue(_ text: String, defaultProtocol: ProxyProtocol?) -> Interpretation? {
        // No early "does it look keyed" guard: the decision is made by whether a
        // *host key* falls out of the extraction below. A substring test would be
        // wrong — `myproxyhost:1080` contains "host:" — and this is cheap enough to
        // run on every line.
        var fields: [String: String] = [:]

        // Layout A: `server:1.2.3.4:port:1080:username:u:password:p`, which some
        // provider panels emit. It is only read this way when the first token is a
        // key we recognise, so an ordinary host:port:user:pass line is untouched.
        let colonTokens = splitRespectingBrackets(text, separator: ":")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if colonTokens.count >= 4, colonTokens.count % 2 == 0, isKnownKey(colonTokens[0]) {
            var index = 0
            while index + 1 < colonTokens.count {
                fields[colonTokens[index].lowercased()] = colonTokens[index + 1]
                index += 2
            }
        }

        // Layout B: `host=1.2.3.4 port=1080 user=u pass=p`.
        if fields.isEmpty {
            for token in text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," || $0 == ";" || $0 == "&" }) {
                let piece = String(token)
                guard let separatorIndex = piece.firstIndex(where: { $0 == "=" || $0 == ":" }) else { continue }
                let key = piece[piece.startIndex..<separatorIndex].trimmingCharacters(in: .whitespaces).lowercased()
                let value = piece[piece.index(after: separatorIndex)...].trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, !value.isEmpty else { continue }
                fields[key] = value
            }
        }

        func first(_ keys: [String]) -> String? {
            for key in keys {
                if let value = fields[key], !value.isEmpty { return value }
            }
            return nil
        }

        guard let rawHost = first(["host", "hostname", "server", "ip", "address"]) else { return nil }
        let host = normalisedHost(rawHost)

        let portText = first(["port"])
        let protocolText = first(["protocol", "proto", "type", "scheme"])
        let protocolType = protocolText.flatMap(protocolFromName) ?? defaultProtocol ?? .socks5

        let port: Int
        if let portText {
            guard let parsed = Int(portText), PortValidator.range.contains(parsed) else { return nil }
            port = parsed
        } else {
            port = protocolType.defaultPort
        }

        var notes: [String] = ["Read as key=value pairs."]
        if portText == nil {
            notes.append("No port given, so \(port) was used.")
        }
        notes.append(contentsOf: hostNotes(host))

        return Interpretation(
            host: host,
            port: port,
            username: first(["username", "user", "login", "userid"]),
            password: first(["password", "pass", "pwd", "passwd"]),
            protocolType: protocolType,
            protocolWasExplicit: protocolText != nil,
            notes: notes,
            shape: "key=value pairs",
            prefersHostFirst: true
        )
    }

    static func protocolFromName(_ text: String) -> ProxyProtocol? {
        switch text.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "socks5", "socks", "socks5h": return .socks5
        case "http", "http-connect", "connect", "httpconnect": return .httpConnect
        case "https", "https-connect", "tls", "httpsconnect": return .httpsConnect
        default: return nil
        }
    }

    // MARK: @ forms

    static func interpretAtForms(_ text: String, defaultProtocol: ProxyProtocol?) -> [Interpretation] {
        var results: [Interpretation] = []
        let atIndices = text.indices.filter { text[$0] == "@" }
        guard !atIndices.isEmpty else { return results }

        for at in atIndices {
            let left = String(text[text.startIndex..<at])
            let right = String(text[text.index(after: at)...])
            guard !left.isEmpty, !right.isEmpty else { continue }

            // host:port@username:password
            if let endpoint = splitHostPort(left), let port = endpoint.port, hostStrength(endpoint.host) > 0 {
                let credentialParts = right.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                let username = decode(String(credentialParts[0]))
                let password = credentialParts.count > 1 ? decode(String(credentialParts[1])) : nil
                if !username.isEmpty {
                    let resolved = resolveProtocol(port: port, defaultProtocol: defaultProtocol)
                    results.append(Interpretation(
                        host: endpoint.host,
                        port: port,
                        username: username,
                        password: password,
                        protocolType: resolved.protocolType,
                        protocolWasExplicit: defaultProtocol != nil,
                        notes: ["Read as host:port@username:password."] + resolved.notes + hostNotes(endpoint.host),
                        shape: "host:port@user:pass",
                        prefersHostFirst: true
                    ))
                }
            }

            // username:password@host:port
            if let endpoint = splitHostPort(right), let port = endpoint.port, hostStrength(endpoint.host) > 0 {
                let credentialParts = left.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                let username = decode(String(credentialParts[0]))
                let password = credentialParts.count > 1 ? decode(String(credentialParts[1])) : nil
                if !username.isEmpty {
                    let resolved = resolveProtocol(port: port, defaultProtocol: defaultProtocol)
                    results.append(Interpretation(
                        host: endpoint.host,
                        port: port,
                        username: username,
                        password: password,
                        protocolType: resolved.protocolType,
                        protocolWasExplicit: defaultProtocol != nil,
                        notes: ["Read as username:password@host:port."] + resolved.notes + hostNotes(endpoint.host),
                        shape: "user:pass@host:port",
                        prefersHostFirst: false
                    ))
                }
            }
        }
        return results
    }

    // MARK: Separated forms

    static func interpretSeparatedForms(_ text: String, defaultProtocol: ProxyProtocol?) -> [Interpretation] {
        var results: [Interpretation] = []

        // Every plausible separator, including whitespace runs (which covers tab
        // and column-aligned output from provider panels).
        let whitespaceTokens = text
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)

        let tokenSets: [(separator: String, tokens: [String])] = [
            (":", splitRespectingBrackets(text, separator: ":")),
            (" ", whitespaceTokens),
            (",", splitRespectingBrackets(text, separator: ",")),
            (";", splitRespectingBrackets(text, separator: ";"))
        ]

        for (separator, rawTokens) in tokenSets {
            let tokens = rawTokens
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            guard tokens.count >= 2 else { continue }

            // host + port, no authentication.
            if tokens.count == 2, let port = Int(tokens[1]), PortValidator.range.contains(port),
               hostStrength(tokens[0]) > 0 {
                let resolved = resolveProtocol(port: port, defaultProtocol: defaultProtocol)
                results.append(Interpretation(
                    host: normalisedHost(tokens[0]),
                    port: port,
                    username: nil,
                    password: nil,
                    protocolType: resolved.protocolType,
                    protocolWasExplicit: defaultProtocol != nil,
                    notes: ["No credentials on this line."] + resolved.notes + hostNotes(tokens[0]),
                    shape: "host:port",
                    prefersHostFirst: true
                ))
                continue
            }

            guard tokens.count >= 4 else { continue }

            // host:port:username:password — a password containing the separator
            // keeps the remainder joined back together, which is why the last field
            // is a join rather than a single token.
            if let port = Int(tokens[1]), PortValidator.range.contains(port), hostStrength(tokens[0]) > 0 {
                let resolved = resolveProtocol(port: port, defaultProtocol: defaultProtocol)
                results.append(Interpretation(
                    host: normalisedHost(tokens[0]),
                    port: port,
                    username: tokens[2].isEmpty ? nil : tokens[2],
                    password: tokens.count > 3 ? tokens[3...].joined(separator: separator) : nil,
                    protocolType: resolved.protocolType,
                    protocolWasExplicit: defaultProtocol != nil,
                    notes: ["Read as host:port:username:password."] + resolved.notes + hostNotes(tokens[0]),
                    shape: "host:port:user:pass",
                    prefersHostFirst: true
                ))
            }

            // username:password:host:port
            if let port = Int(tokens[3]), PortValidator.range.contains(port), hostStrength(tokens[2]) > 0 {
                let resolved = resolveProtocol(port: port, defaultProtocol: defaultProtocol)
                results.append(Interpretation(
                    host: normalisedHost(tokens[2]),
                    port: port,
                    username: tokens[0].isEmpty ? nil : tokens[0],
                    password: tokens[1].isEmpty ? nil : tokens[1],
                    protocolType: resolved.protocolType,
                    protocolWasExplicit: defaultProtocol != nil,
                    notes: ["Read as username:password:host:port."] + resolved.notes + hostNotes(tokens[2]),
                    shape: "user:pass:host:port",
                    prefersHostFirst: false
                ))
            }
        }
        return results
    }

    // MARK: Helpers

    struct ResolvedProtocol {
        let protocolType: ProxyProtocol
        let notes: [String]
    }

    /// Chooses the protocol for a line that did not carry one, and says so when it
    /// had to guess.
    ///
    /// The port inference is deliberately conservative: 443 is used by SOCKS5
    /// providers as often as by TLS proxies, so guessing there would do more harm
    /// than good.
    static func resolveProtocol(port: Int, defaultProtocol: ProxyProtocol?) -> ResolvedProtocol {
        if let defaultProtocol {
            return ResolvedProtocol(protocolType: defaultProtocol, notes: [])
        }
        let inferred: ProxyProtocol
        switch port {
        case 1080, 1081: inferred = .socks5
        case 3128, 8080, 8888: inferred = .httpConnect
        default: inferred = .socks5
        }
        return ResolvedProtocol(
            protocolType: inferred,
            notes: ["Protocol guessed from port \(port): \(inferred.displayName). Choose a protocol explicitly if that is wrong."]
        )
    }

    static func decode(_ text: String) -> String {
        text.removingPercentEncoding ?? text
    }

    /// Splits `host:port`, `[v6]:port`, or a bare host. The host comes back
    /// canonicalised.
    static func splitHostPort(_ text: String) -> (host: String, port: Int?)? {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }

        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return nil }
            let host = String(value[value.index(after: value.startIndex)..<close])
            let remainder = String(value[value.index(after: close)...])
            guard host.contains(":") else { return nil }
            if remainder.isEmpty { return (normalisedHost(host), nil) }
            guard remainder.hasPrefix(":") else { return nil }
            let portText = String(remainder.dropFirst())
            guard let port = Int(portText), PortValidator.range.contains(port) else { return (normalisedHost(host), nil) }
            return (normalisedHost(host), port)
        }

        // An unbracketed IPv6 literal has no port.
        if value.filter({ $0 == ":" }).count > 1 {
            return (normalisedHost(value), nil)
        }

        if let colon = value.lastIndex(of: ":") {
            let host = String(value[value.startIndex..<colon])
            let portText = String(value[value.index(after: colon)...])
            guard !host.isEmpty else { return nil }
            guard let port = Int(portText), PortValidator.range.contains(port) else { return nil }
            return (normalisedHost(host), port)
        }

        // A bare host, with the port defaulted by the caller.
        guard hostStrength(value) > 0 else { return nil }
        return (normalisedHost(value), nil)
    }

    /// Splits on `separator` without breaking a bracketed IPv6 literal apart.
    static func splitRespectingBrackets(_ text: String, separator: Character) -> [String] {
        var tokens: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            if character == "[" {
                depth += 1
                current.append(character)
                continue
            }
            if character == "]" {
                depth = max(0, depth - 1)
                current.append(character)
                continue
            }
            if character == separator && depth == 0 {
                tokens.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        tokens.append(current)
        return tokens
    }

    /// Warnings worth surfacing about a host that is technically valid.
    static func hostNotes(_ host: String) -> [String] {
        HostValidator.validate(host).issues
            .filter { $0.severity == .warning }
            .map(\.message)
    }
}

// MARK: - JSON

extension ProxyImportParser {

    /// Parses a paste that is one JSON object, an array of them, or `{"proxies":[…]}`.
    static func parseJSONDocument(_ text: String, defaultProtocol: ProxyProtocol?) -> [ProxyImportEntry]? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return nil
        }

        func entries(from objects: [[String: Any]], label: String) -> [ProxyImportEntry] {
            objects.enumerated().map { index, object in
                guard let candidate = candidateFromJSON(object, defaultProtocol: defaultProtocol) else {
                    return ProxyImportEntry(
                        lineNumber: index + 1,
                        redactedSource: "\(label) \(index + 1)",
                        candidate: nil,
                        failure: .jsonProblem("object \(index + 1) has no usable host and port")
                    )
                }
                return ProxyImportEntry(
                    lineNumber: index + 1,
                    redactedSource: "\(label) \(index + 1)",
                    candidate: candidate,
                    failure: nil
                )
            }
        }

        if let array = root as? [[String: Any]] {
            return entries(from: array, label: "JSON object")
        }

        if let object = root as? [String: Any] {
            if let nested = object["proxies"] as? [[String: Any]] {
                return entries(from: nested, label: "JSON object")
            }
            if let candidate = candidateFromJSON(object, defaultProtocol: defaultProtocol) {
                return [ProxyImportEntry(lineNumber: 1, redactedSource: "JSON object", candidate: candidate, failure: nil)]
            }
        }

        return nil
    }

    static func parseJSONObject(_ line: String, defaultProtocol: ProxyProtocol?) -> ProxyImportCandidate? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return nil
        }
        return candidateFromJSON(object, defaultProtocol: defaultProtocol)
    }

    static func candidateFromJSON(_ object: [String: Any], defaultProtocol: ProxyProtocol?) -> ProxyImportCandidate? {
        func string(_ keys: [String]) -> String? {
            for key in keys {
                if let value = object[key] as? String, !value.isEmpty { return value }
                if let value = object[key] as? Int { return String(value) }
            }
            return nil
        }

        guard let rawHost = string(["host", "hostname", "server", "ip", "address"]) else { return nil }
        let host = normalisedHost(rawHost)

        let protocolText = string(["protocol", "proto", "type", "scheme"])
        let protocolType = protocolText.flatMap(protocolFromName) ?? defaultProtocol ?? .socks5

        let portText = string(["port"])
        let port: Int
        if let portText, let parsed = Int(portText), PortValidator.range.contains(parsed) {
            port = parsed
        } else {
            port = protocolType.defaultPort
        }

        var notes = ["Read from JSON."]
        if portText == nil { notes.append("No port in the object, so \(port) was used.") }
        notes.append(contentsOf: hostNotes(host))

        return ProxyImportCandidate(
            name: string(["name", "label", "title"]),
            host: host,
            port: port,
            protocolType: protocolType,
            username: string(["username", "user", "login", "userid"]),
            password: string(["password", "pass", "pwd", "passwd"]),
            protocolWasExplicit: protocolText != nil,
            notes: notes,
            isAmbiguous: false
        )
    }
}
