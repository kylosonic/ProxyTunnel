//
//  PortValidator.swift
//  ProxyTunnelCore
//

import Foundation

public struct PortValidation: Equatable, Sendable {
    public let sanitized: String
    public let value: Int?
    public let issues: [ValidationIssue]

    public var isValid: Bool { !issues.contains { $0.severity == .error } }
}

/// Validates the TCP port field.
///
/// A port is an unsigned 16-bit integer, so anything outside 1...65535 is a hard
/// error. Port 0 is rejected too: it is legal in `bind()` but meaningless as a
/// proxy destination.
public enum PortValidator {

    public static let range: ClosedRange<Int> = 1...65535

    public static func validate(_ raw: String, protocolType: ProxyProtocol? = nil) -> PortValidation {
        var issues: [ValidationIssue] = []
        let text = Sanitizer.clean(raw)

        guard !text.isEmpty else {
            return PortValidation(sanitized: "", value: nil, issues: [.error(.port, "Port is required.")])
        }
        guard text.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return PortValidation(
                sanitized: text,
                value: nil,
                issues: [.error(.port, "Port must contain digits only.")]
            )
        }
        guard let value = Int(text) else {
            return PortValidation(
                sanitized: text,
                value: nil,
                issues: [.error(.port, "Port is not a valid number.")]
            )
        }
        guard range.contains(value) else {
            return PortValidation(
                sanitized: text,
                value: nil,
                issues: [.error(.port, "Port must be between \(range.lowerBound) and \(range.upperBound).")]
            )
        }

        let canonical = String(value)

        if value < 1024 {
            issues.append(.warning(
                .port,
                "Ports below 1024 are reserved for well-known services. Make sure \(value) is really your proxy's port."
            ))
        }

        if let protocolType {
            let expected = protocolType.defaultPort
            let mismatched: Bool
            switch protocolType {
            case .socks5:       mismatched = (value == 80 || value == 443 || value == 8080)
            case .httpConnect:  mismatched = (value == 1080 || value == 1081)
            case .httpsConnect: mismatched = (value == 1080 || value == 8080)
            }
            if mismatched {
                issues.append(.warning(
                    .port,
                    "\(value) is unusual for \(protocolType.displayName) (the usual port is \(expected)). Double-check that the protocol and port match what your provider gave you."
                ))
            }
        }

        return PortValidation(sanitized: canonical, value: value, issues: issues)
    }
}
