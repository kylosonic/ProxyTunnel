//
//  Validation.swift
//  ProxyTunnelCore
//

import Foundation

/// One problem found while validating user input.
public struct ValidationIssue: Equatable, Sendable, Identifiable {

    public enum Field: String, Sendable, CaseIterable {
        case name
        case host
        case port
        case protocolType
        case username
        case password
        case notes
        case general
    }

    public enum Severity: String, Sendable {
        /// Blocks saving.
        case error
        /// Shown as a hint; saving is still allowed.
        case warning
    }

    public let field: Field
    public let severity: Severity
    public let message: String

    public var id: String { "\(field.rawValue).\(severity.rawValue).\(message)" }

    public init(field: Field, severity: Severity, message: String) {
        self.field = field
        self.severity = severity
        self.message = message
    }

    public static func error(_ field: Field, _ message: String) -> ValidationIssue {
        ValidationIssue(field: field, severity: .error, message: message)
    }

    public static func warning(_ field: Field, _ message: String) -> ValidationIssue {
        ValidationIssue(field: field, severity: .warning, message: message)
    }
}

/// The result of validating one proxy form submission.
public struct ValidationReport: Equatable, Sendable {

    public let issues: [ValidationIssue]

    public init(issues: [ValidationIssue] = []) {
        self.issues = issues
    }

    public var errors: [ValidationIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [ValidationIssue] { issues.filter { $0.severity == .warning } }

    /// `true` when nothing blocks saving.
    public var isValid: Bool { errors.isEmpty }

    public func issues(for field: ValidationIssue.Field) -> [ValidationIssue] {
        issues.filter { $0.field == field }
    }

    public func firstError(for field: ValidationIssue.Field) -> ValidationIssue? {
        issues.first { $0.field == field && $0.severity == .error }
    }

    public func firstMessage(for field: ValidationIssue.Field) -> String? {
        issues.first { $0.field == field }?.message
    }

    /// Human-readable summary, used by `ProxyProbe` results and diagnostics.
    public var summary: String {
        if issues.isEmpty { return "OK" }
        return issues.map { "\($0.severity.rawValue): \($0.field.rawValue): \($0.message)" }
            .joined(separator: "; ")
    }

    public static let valid = ValidationReport()
}

// MARK: - Sanitisation

/// Text helpers shared by the field validators.
///
/// "Sanitise" here means: normalise into the exact form we will store and send
/// on the wire, or reject. We never silently keep control characters, embedded
/// credentials or URL decorations.
enum Sanitizer {

    /// Trims whitespace and newlines, and removes zero-width / bidi control
    /// characters that could be used to spoof a host name in the UI.
    static func clean(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x206F, 0xFEFF:
                continue // zero-width and bidi controls
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the string contains a C0/C1 control character.
    static func containsControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (scalar.value < 0x20) || (0x7F...0x9F).contains(scalar.value)
        }
    }
}
