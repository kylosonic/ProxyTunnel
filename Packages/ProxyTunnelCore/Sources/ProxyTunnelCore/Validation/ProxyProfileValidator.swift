//
//  ProxyProfileValidator.swift
//  ProxyTunnelCore
//

import Foundation

/// The raw contents of the "Add / Edit Proxy" form, before validation.
///
/// `port` is a string here on purpose: the user is mid-typing most of the time,
/// and coercing to `Int` in the view model would throw away the text they are
/// still editing.
public struct ProxyProfileDraft: Equatable, Sendable {
    public var id: UUID?
    public var name: String
    public var host: String
    public var portText: String
    public var protocolType: ProxyProtocol
    public var username: String
    public var password: String
    public var notes: String
    public var isMock: Bool

    public init(
        id: UUID? = nil,
        name: String = "",
        host: String = "",
        portText: String = "",
        protocolType: ProxyProtocol = .socks5,
        username: String = "",
        password: String = "",
        notes: String = "",
        isMock: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.portText = portText
        self.protocolType = protocolType
        self.username = username
        self.password = password
        self.notes = notes
        self.isMock = isMock
    }

    /// Seeds the form from an existing profile. The password is *not* filled in
    /// automatically: the caller decides whether to load it from the Keychain,
    /// and an empty password means "keep the stored one".
    public init(profile: ProxyProfile) {
        self.id = profile.id
        self.name = profile.name
        self.host = profile.host
        self.portText = String(profile.port)
        self.protocolType = profile.protocolType
        self.username = profile.username ?? ""
        self.password = ""
        self.notes = profile.notes ?? ""
        self.isMock = profile.isMock
    }
}

/// A draft that has passed validation, normalised into the exact values that
/// will be stored and sent on the wire.
public struct ValidatedProxyInput: Equatable, Sendable {
    public let name: String
    public let host: String
    public let port: Int
    public let protocolType: ProxyProtocol
    public let username: String?
    /// `nil` means "no password supplied"; the caller keeps whatever is already
    /// in the Keychain.
    public let password: String?
    public let notes: String?
    public let isMock: Bool

    public var usesAuthentication: Bool { username != nil }
}

public enum ProxyProfileValidator {

    public static let maxNameLength = 64
    public static let maxUsernameLength = 255
    public static let maxPasswordLength = 255
    public static let maxNotesLength = 500

    /// Validates a draft and, when there are no errors, returns the sanitised
    /// values ready to be persisted.
    ///
    /// The returned report always contains every issue found (including
    /// warnings) even when validation fails, so the form can show all problems
    /// at once instead of one at a time.
    public static func validate(_ draft: ProxyProfileDraft) -> (report: ValidationReport, input: ValidatedProxyInput?) {
        var issues: [ValidationIssue] = []

        // ---- name --------------------------------------------------------
        var name = Sanitizer.clean(draft.name)
        if name.isEmpty {
            name = suggestedName(host: draft.host, port: draft.portText, protocolType: draft.protocolType)
            issues.append(.warning(.name, "No name given, so \"\(name)\" will be used."))
        }
        if name.count > maxNameLength {
            issues.append(.error(.name, "Name must be \(maxNameLength) characters or fewer."))
            name = String(name.prefix(maxNameLength))
        }
        if Sanitizer.containsControlCharacters(draft.name) {
            issues.append(.error(.name, "Name contains control characters."))
        }

        // ---- protocol ----------------------------------------------------
        // `ProxyProtocol` is non-optional in the draft, so it is always
        // "selected". Guard against a decoded-but-unknown value arriving here.
        let protocolType = draft.protocolType

        // ---- host --------------------------------------------------------
        let hostResult = HostValidator.validate(draft.host)
        issues.append(contentsOf: hostResult.issues)

        // ---- port --------------------------------------------------------
        let portResult = PortValidator.validate(draft.portText, protocolType: protocolType)
        issues.append(contentsOf: portResult.issues)

        // ---- credentials -------------------------------------------------
        let username = Sanitizer.clean(draft.username)
        let password = draft.password
        var storedUsername: String?

        if !username.isEmpty {
            if username.count > maxUsernameLength {
                issues.append(.error(.username, "Username must be \(maxUsernameLength) characters or fewer (RFC 1929 limit)."))
            }
            if Sanitizer.containsControlCharacters(username) {
                issues.append(.error(.username, "Username contains control characters."))
            }
            storedUsername = username
        }

        if password.count > maxPasswordLength {
            let severity: ValidationIssue.Severity = (protocolType == .socks5) ? .error : .warning
            issues.append(ValidationIssue(
                field: .password,
                severity: severity,
                message: "Password is longer than \(maxPasswordLength) characters. SOCKS5 username/password authentication (RFC 1929) cannot carry more than 255 bytes."
            ))
        }
        if Sanitizer.containsControlCharacters(password) {
            issues.append(.error(.password, "Password contains control characters."))
        }
        if !password.isEmpty && username.isEmpty {
            issues.append(.error(
                .username,
                "A password was entered but the username is empty. \(protocolType.displayName) authentication needs both."
            ))
        }
        if username.isEmpty && password.isEmpty && !protocolType.supportsAuthentication {
            issues.append(.error(.general, "\(protocolType.displayName) requires a username and password."))
        }
        if !username.isEmpty && password.isEmpty {
            issues.append(.warning(
                .password,
                "No password entered. If this proxy needs no authentication, clear the username too; otherwise the proxy will reject the connection."
            ))
        }
        if username.isEmpty && draft.password.isEmpty {
            storedUsername = nil
        }

        // ---- notes -------------------------------------------------------
        var notes = Sanitizer.clean(draft.notes)
        if notes.count > maxNotesLength {
            issues.append(.error(.notes, "Notes must be \(maxNotesLength) characters or fewer."))
            notes = String(notes.prefix(maxNotesLength))
        }
        if !notes.isEmpty && LogRedactor.redact(notes) != notes {
            issues.append(.warning(
                .notes,
                "The notes look like they contain a password or token. Notes are stored in plain text on the device — remove anything secret from them."
            ))
        }

        // ---- mock sanity -------------------------------------------------
        if draft.isMock {
            issues.append(.warning(.general, "This is a development/mock profile. It never routes real traffic."))
        }

        let report = ValidationReport(issues: issues)
        guard report.isValid else { return (report, nil) }
        // Any field that failed to normalise means we must not build an input.
        guard let kind = hostResult.kind, let port = portResult.value else {
            return (report, nil)
        }

        let input = ValidatedProxyInput(
            name: name,
            host: hostResult.sanitized.isEmpty ? kind.wireValue : hostResult.sanitized,
            port: port,
            protocolType: protocolType,
            username: storedUsername,
            password: password.isEmpty ? nil : password,
            notes: notes.isEmpty ? nil : notes,
            isMock: draft.isMock
        )
        return (report, input)
    }

    /// Validates a stored profile without touching the Keychain. Used by the
    /// diagnostics screen to flag profiles that would fail at connect time.
    public static func validate(profile: ProxyProfile) -> ValidationReport {
        var draft = ProxyProfileDraft(profile: profile)
        draft.password = profile.passwordReference == nil ? "" : "placeholder-not-a-real-secret"
        if draft.password == "placeholder-not-a-real-secret" {
            // Avoid the "password without username" error when we are only
            // checking the non-secret fields.
            draft.username = profile.username ?? "user"
        }
        return validate(draft).report
    }

    static func suggestedName(host: String, port: String, protocolType: ProxyProtocol) -> String {
        let cleanedHost = Sanitizer.clean(host)
        let cleanedPort = Sanitizer.clean(port)
        if cleanedHost.isEmpty {
            return protocolType.displayName
        }
        let base = cleanedHost.count > 40 ? String(cleanedHost.prefix(40)) : cleanedHost
        return cleanedPort.isEmpty ? base : "\(base):\(cleanedPort)"
    }
}
