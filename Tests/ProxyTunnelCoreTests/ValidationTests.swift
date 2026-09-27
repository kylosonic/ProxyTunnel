//
//  ValidationTests.swift
//  ProxyTunnelCoreTests
//
//  §21: proxy profile validation, port validation, host validation, protocol
//  selection.
//

import XCTest
@testable import ProxyTunnelCore

final class HostValidatorTests: XCTestCase {

    func testAcceptsIPv4Literal() {
        let result = HostValidator.validate("203.0.113.7")
        XCTAssertTrue(result.isValid, result.issues.map(\.message).joined(separator: "; "))
        XCTAssertEqual(result.sanitized, "203.0.113.7")
        guard case .ipv4 = result.kind else { return XCTFail("expected an IPv4 kind") }
    }

    func testAcceptsIPv6LiteralWithAndWithoutBrackets() {
        for input in ["2001:db8::1", "[2001:db8::1]"] {
            let result = HostValidator.validate(input)
            XCTAssertTrue(result.isValid, "\(input): \(result.issues)")
            XCTAssertEqual(result.sanitized, "2001:db8::1")
            guard case .ipv6 = result.kind else { return XCTFail("expected an IPv6 kind for \(input)") }
        }
    }

    func testAcceptsHostnameAndNormalisesCase() {
        let result = HostValidator.validate("  Proxy.Example.COM  ")
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.sanitized, "proxy.example.com")
        guard case .hostname(let name) = result.kind else { return XCTFail("expected a hostname") }
        XCTAssertEqual(name, "proxy.example.com")
    }

    func testRejectsEmpty() {
        let result = HostValidator.validate("   ")
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.issues.first?.message, "Host is required.")
    }

    func testRejectsEmbeddedCredentials() {
        let result = HostValidator.validate("user:secret@proxy.example.com")
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.issues.contains { $0.message.contains("username and password in their own fields") })
        // The host part must be salvaged so the user only has to fix one thing.
        XCTAssertEqual(result.sanitized, "proxy.example.com")
    }

    func testStripsSchemeWithAWarning() {
        let result = HostValidator.validate("socks5://proxy.example.com")
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.sanitized, "proxy.example.com")
        XCTAssertTrue(result.issues.contains { $0.severity == .warning && $0.message.contains("socks5://") })
    }

    func testStripsPathAndQuery() {
        let result = HostValidator.validate("proxy.example.com/foo?bar=1")
        XCTAssertEqual(result.sanitized, "proxy.example.com")
        XCTAssertTrue(result.issues.contains { $0.message.contains("path") })
    }

    func testRejectsPortInsideTheHostField() {
        let result = HostValidator.validate("proxy.example.com:1080")
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.issues.contains { $0.message.contains("Put 1080 in the Port field") })
        XCTAssertEqual(result.sanitized, "proxy.example.com")
    }

    func testRejectsMalformedIPv4() {
        let result = HostValidator.validate("999.999.999.999")
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.issues.contains { $0.message.contains("not a valid IPv4 address") })
    }

    func testRejectsHyphenAtLabelBoundary() {
        let result = HostValidator.validate("-proxy.example.com")
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.issues.contains { $0.message.contains("hyphen") })
    }

    func testRejectsSpaces() {
        let result = HostValidator.validate("proxy example.com")
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.issues.contains { $0.message.contains("spaces") })
    }

    func testWarnsAboutLoopbackWithoutRejectingIt() {
        let result = HostValidator.validate("127.0.0.1")
        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.issues.contains { $0.severity == .warning && $0.message.contains("loopback") })
    }

    func testWarnsAboutSingleLabelHostname() {
        let result = HostValidator.validate("internalproxy")
        XCTAssertTrue(result.isValid, "a single-label name is legal, just unusual")
        XCTAssertTrue(result.issues.contains { $0.message.contains("Single-label") })
    }

    func testStripsZeroWidthCharacters() {
        // A zero-width space inside the host must not survive: it would render
        // identically while pointing somewhere else.
        let result = HostValidator.validate("proxy\u{200B}.example.com")
        XCTAssertEqual(result.sanitized, "proxy.example.com")
    }

    func testRejectsOverlongHostname() {
        let label = String(repeating: "a", count: 60)
        let host = Array(repeating: label, count: 5).joined(separator: ".")
        let result = HostValidator.validate(host)
        XCTAssertFalse(result.isValid)
    }

    func testRejectsOverlongLabel() {
        let label = String(repeating: "a", count: 64)
        let result = HostValidator.validate("\(label).example.com")
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.issues.contains { $0.message.contains("longer than 63") })
    }
}

final class PortValidatorTests: XCTestCase {

    func testAcceptsValidPort() {
        let result = PortValidator.validate("1080")
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.value, 1080)
        XCTAssertEqual(result.sanitized, "1080")
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(PortValidator.validate("  443 ").value, 443)
    }

    func testRejectsEmpty() {
        let result = PortValidator.validate("")
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.issues.first?.message, "Port is required.")
    }

    func testRejectsNonNumeric() {
        XCTAssertFalse(PortValidator.validate("80a").isValid)
        XCTAssertFalse(PortValidator.validate("8 0").isValid)
    }

    func testRejectsZeroAndOutOfRange() {
        XCTAssertFalse(PortValidator.validate("0").isValid)
        XCTAssertFalse(PortValidator.validate("65536").isValid)
        XCTAssertTrue(PortValidator.validate("65535").isValid)
        XCTAssertTrue(PortValidator.validate("1").isValid)
    }

    func testWarnsAboutPrivilegedPorts() {
        let result = PortValidator.validate("80")
        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.issues.contains { $0.message.contains("reserved") })
    }

    func testWarnsAboutProtocolPortMismatch() {
        let result = PortValidator.validate("443", protocolType: .socks5)
        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.issues.contains { $0.message.contains("unusual for SOCKS5") })

        let matching = PortValidator.validate("1080", protocolType: .socks5)
        XCTAssertFalse(matching.issues.contains { $0.message.contains("unusual") })
    }
}

final class ProxyProfileValidatorTests: XCTestCase {

    private func validDraft() -> ProxyProfileDraft {
        ProxyProfileDraft(
            name: "My Proxy",
            host: "example.proxy.com",
            portText: "12345",
            protocolType: .socks5,
            username: "example-user",
            password: "example-password"
        )
    }

    func testAcceptsACompleteDraft() {
        let (report, input) = ProxyProfileValidator.validate(validDraft())
        XCTAssertTrue(report.isValid, report.summary)
        XCTAssertEqual(input?.name, "My Proxy")
        XCTAssertEqual(input?.host, "example.proxy.com")
        XCTAssertEqual(input?.port, 12345)
        XCTAssertEqual(input?.protocolType, .socks5)
        XCTAssertEqual(input?.username, "example-user")
        XCTAssertEqual(input?.password, "example-password")
    }

    func testAcceptsAProfileWithNoAuthentication() {
        var draft = validDraft()
        draft.username = ""
        draft.password = ""
        let (report, input) = ProxyProfileValidator.validate(draft)
        XCTAssertTrue(report.isValid, report.summary)
        XCTAssertNil(input?.username)
        XCTAssertNil(input?.password)
    }

    func testRejectsPasswordWithoutUsername() {
        var draft = validDraft()
        draft.username = ""
        let (report, input) = ProxyProfileValidator.validate(draft)
        XCTAssertFalse(report.isValid)
        XCTAssertNil(input)
        XCTAssertTrue(report.errors.contains { $0.field == .username })
    }

    func testWarnsWhenUsernameHasNoPassword() {
        var draft = validDraft()
        draft.password = ""
        let (report, input) = ProxyProfileValidator.validate(draft)
        XCTAssertTrue(report.isValid, "an empty password is unusual but not impossible")
        XCTAssertTrue(report.warnings.contains { $0.field == .password })
        XCTAssertNil(input?.password)
    }

    func testDerivesANameWhenMissing() {
        var draft = validDraft()
        draft.name = ""
        let (report, input) = ProxyProfileValidator.validate(draft)
        XCTAssertTrue(report.isValid)
        XCTAssertEqual(input?.name, "example.proxy.com:12345")
        XCTAssertTrue(report.warnings.contains { $0.field == .name })
    }

    func testRejectsTooLongUsername() {
        var draft = validDraft()
        draft.username = String(repeating: "u", count: 256)
        let (report, _) = ProxyProfileValidator.validate(draft)
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.errors.contains { $0.field == .username })
    }

    func testRejectsTooLongSocks5PasswordButOnlyWarnsForHTTP() {
        var socks = validDraft()
        socks.password = String(repeating: "p", count: 300)
        XCTAssertFalse(ProxyProfileValidator.validate(socks).report.isValid)

        var http = validDraft()
        http.protocolType = .httpConnect
        http.password = String(repeating: "p", count: 300)
        let httpReport = ProxyProfileValidator.validate(http).report
        XCTAssertTrue(httpReport.isValid)
        XCTAssertTrue(httpReport.warnings.contains { $0.field == .password })
    }

    func testWarnsWhenNotesLookLikeTheyContainASecret() {
        var draft = validDraft()
        draft.notes = "password=hunter2"
        let (report, _) = ProxyProfileValidator.validate(draft)
        XCTAssertTrue(report.isValid)
        XCTAssertTrue(report.warnings.contains { $0.field == .notes })
    }

    func testReportsEveryProblemAtOnce() {
        let draft = ProxyProfileDraft(name: "", host: "bad host", portText: "0", protocolType: .socks5)
        let (report, _) = ProxyProfileValidator.validate(draft)
        XCTAssertFalse(report.isValid)
        XCTAssertGreaterThanOrEqual(report.errors.count, 2, "the form should not walk the user through one error at a time")
    }

    func testMockProfileIsFlagged() {
        var draft = validDraft()
        draft.isMock = true
        let (report, input) = ProxyProfileValidator.validate(draft)
        XCTAssertTrue(report.isValid)
        XCTAssertEqual(input?.isMock, true)
        XCTAssertTrue(report.warnings.contains { $0.message.contains("mock") })
    }

    func testValidateStoredProfileDoesNotNeedThePassword() {
        let profile = ProxyProfile(
            name: "p",
            host: "example.proxy.com",
            port: 1080,
            protocolType: .socks5,
            username: "user",
            passwordReference: "proxy-password-x"
        )
        XCTAssertTrue(ProxyProfileValidator.validate(profile: profile).isValid)
    }
}

final class DNSSettingsValidatorTests: XCTestCase {

    func testAcceptsAndDeduplicates() {
        let result = DNSSettingsValidator.validate(["1.1.1.1", "1.1.1.1", "8.8.8.8"])
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.servers, ["1.1.1.1", "8.8.8.8"])
    }

    func testRejectsNames() {
        let result = DNSSettingsValidator.validate(["dns.google"])
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.issues.contains { $0.message.contains("not an IP address") })
    }

    func testWarnsWhenEmpty() {
        let result = DNSSettingsValidator.validate([])
        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.issues.contains { $0.severity == .warning })
    }

    func testSplitsCommasNewlinesAndSpaces() {
        XCTAssertEqual(
            DNSSettingsValidator.split("1.1.1.1, 8.8.8.8\n9.9.9.9"),
            ["1.1.1.1", "8.8.8.8", "9.9.9.9"]
        )
    }

    func testRejectsMulticastResolver() {
        XCTAssertFalse(DNSSettingsValidator.validate(["224.0.0.251"]).isValid)
    }
}
