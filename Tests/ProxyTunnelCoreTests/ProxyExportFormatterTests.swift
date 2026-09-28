//
//  ProxyExportFormatterTests.swift
//  ProxyTunnelCoreTests
//
//  The exporter hands a credential to another app, so two properties matter most:
//  the output must be *consumable*, and the password must be absent when it was
//  asked to be absent.
//
//  The round-trip tests are the interesting ones: they push the exporter's output
//  back through the importer and assert the profile comes out identical, which
//  pins the two halves of the interchange module to each other rather than to my
//  idea of what the formats look like.
//

import XCTest
@testable import ProxyTunnelCore

final class ProxyExportFormatterTests: XCTestCase {

    private func profile(
        protocolType: ProxyProtocol = .socks5,
        host: String = "203.0.113.7",
        port: Int = 1080,
        username: String? = "example-user",
        name: String = "Frankfurt"
    ) -> ProxyProfile {
        ProxyProfile(
            name: name,
            host: host,
            port: port,
            protocolType: protocolType,
            username: username,
            passwordReference: username == nil ? nil : "ref"
        )
    }

    private let credential = ProxyCredential(username: "example-user", password: "example-password")

    // MARK: Share link

    func testShareLinkShape() {
        let link = ProxyExportFormatter.shareLink(
            for: profile(), username: "example-user", password: "example-password", name: "Frankfurt"
        )
        XCTAssertEqual(link, "socks5://example-user:example-password@203.0.113.7:1080#Frankfurt")
    }

    func testShareLinkSchemePerProtocol() {
        let socks = ProxyExportFormatter.shareLink(
            for: profile(protocolType: .socks5), username: "u", password: "p", name: nil
        )
        XCTAssertTrue(socks.hasPrefix("socks5://"), socks)

        let http = ProxyExportFormatter.shareLink(
            for: profile(protocolType: .httpConnect, port: 8080), username: "u", password: "p", name: nil
        )
        XCTAssertTrue(http.hasPrefix("http://"), http)

        let https = ProxyExportFormatter.shareLink(
            for: profile(protocolType: .httpsConnect, port: 443), username: "u", password: "p", name: nil
        )
        XCTAssertTrue(https.hasPrefix("https://"), https)
    }

    func testShareLinkWithoutCredentials() {
        let link = ProxyExportFormatter.shareLink(
            for: profile(username: nil, name: "Open"), username: nil, password: nil, name: "Open"
        )
        XCTAssertEqual(link, "socks5://203.0.113.7:1080#Open")
        XCTAssertFalse(link.contains("@"), "no credentials means no userinfo at all")
    }

    func testShareLinkOmitsThePasswordWhenAsked() {
        let link = ProxyExportFormatter.shareLink(
            for: profile(), username: "example-user", password: nil, name: nil
        )
        XCTAssertEqual(link, "socks5://example-user@203.0.113.7:1080")
        XCTAssertFalse(link.contains("example-password"))
    }

    func testShareLinkPercentEncodesCredentialsAndName() {
        let link = ProxyExportFormatter.shareLink(
            for: profile(host: "proxy.example.com", name: "Germany 1"),
            username: "user@corp",
            password: "p@ss:w/rd?#",
            name: "Germany 1"
        )
        // The raw delimiters must not appear inside the userinfo, or the link would
        // parse as a different proxy entirely.
        let userinfo = link.split(separator: "@").first.map(String.init) ?? ""
        XCTAssertFalse(userinfo.contains("p@ss"), link)
        XCTAssertTrue(link.contains("user%40corp"), link)
        XCTAssertTrue(link.contains("#Germany%201"), link)

        // And what comes back out must be what went in.
        let entry = ProxyImportParser.parseLine(link)
        XCTAssertEqual(entry.candidate?.username, "user@corp")
        XCTAssertEqual(entry.candidate?.password, "p@ss:w/rd?#")
    }

    func testShareLinkBracketsIPv6() {
        let link = ProxyExportFormatter.shareLink(
            for: profile(host: "2001:db8::1"), username: "u", password: "p", name: nil
        )
        XCTAssertEqual(link, "socks5://u:p@[2001:db8::1]:1080")
    }

    func testShareLinkWithoutANameHasNoFragment() {
        let link = ProxyExportFormatter.shareLink(
            for: profile(), username: "u", password: "p", name: ""
        )
        XCTAssertFalse(link.contains("#"), link)
    }

    // MARK: Round trip

    func testShareLinkRoundTripsThroughTheImporter() {
        // This is the property that matters: a link the app produces is a link the
        // app (and anything shaped like it) can read back.
        let cases: [(ProxyProtocol, String, Int, String?, String?)] = [
            (.socks5, "203.0.113.7", 1080, "example-user", "example-password"),
            (.socks5, "proxy.example.com", 1080, "user", "p@ss:w/rd"),
            (.httpConnect, "198.51.100.9", 8080, "user", "pa ss"),
            (.httpsConnect, "proxy.example.com", 443, "user", "p"),
            (.socks5, "2001:db8::1", 1080, "user", "p"),
            (.socks5, "203.0.113.7", 1080, nil, nil)
        ]

        for (protocolType, host, port, username, password) in cases {
            let source = profile(protocolType: protocolType, host: host, port: port, username: username, name: "Node A")
            let exportCredential = username.map { ProxyCredential(username: $0, password: password ?? "") }

            let link = ProxyExportFormatter.text(
                for: source,
                credential: exportCredential,
                format: .shareLink
            )

            let entry = ProxyImportParser.parseLine(link)
            guard let parsed = entry.candidate else {
                XCTFail("exported link did not parse back: \(link) — \(entry.failure?.message ?? "")")
                continue
            }

            let normalisedHost = HostValidator.validate(host).sanitized
            XCTAssertEqual(parsed.host, normalisedHost, "host for \(link)")
            XCTAssertEqual(parsed.port, port, "port for \(link)")
            XCTAssertEqual(parsed.protocolType, protocolType, "protocol for \(link)")
            XCTAssertEqual(parsed.username, username, "username for \(link)")
            if let username {
                XCTAssertEqual(parsed.password, password, "password for \(link)")
            }
            XCTAssertEqual(parsed.name, "Node A", "name should survive in the fragment: \(link)")
        }
    }

    // MARK: sing-box outbound

    private func outboundJSON(
        _ protocolType: ProxyProtocol = .socks5,
        includePassword: Bool = true
    ) throws -> [String: Any] {
        let text = ProxyExportFormatter.text(
            for: profile(protocolType: protocolType),
            credential: credential,
            format: .singBoxOutbound,
            options: ProxyExportOptions(includePassword: includePassword)
        )
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testSingBoxOutboundIsValidJSONWithTheExpectedKeys() throws {
        let object = try outboundJSON()
        XCTAssertEqual(object["type"] as? String, "socks")
        XCTAssertEqual(object["server"] as? String, "203.0.113.7")
        XCTAssertEqual(object["server_port"] as? Int, 1080)
        XCTAssertEqual(object["username"] as? String, "example-user")
        XCTAssertEqual(object["password"] as? String, "example-password")
        XCTAssertEqual(object["version"] as? String, "5")
        XCTAssertEqual(object["tag"] as? String, "Frankfurt")
    }

    func testSingBoxOutboundUsesHTTPTypeForConnectProtocols() throws {
        XCTAssertEqual(try outboundJSON(.httpConnect)["type"] as? String, "http")
        XCTAssertEqual(try outboundJSON(.httpsConnect)["type"] as? String, "http")
    }

    func testSingBoxOutboundMarksTLSForAnHTTPSProxy() throws {
        let object = try outboundJSON(.httpsConnect)
        let tls = try XCTUnwrap(object["tls"] as? [String: Any])
        XCTAssertEqual(tls["enabled"] as? Bool, true)
        XCTAssertEqual(tls["server_name"] as? String, "203.0.113.7")
    }

    func testSingBoxOutboundHasNoTLSForPlainProtocols() throws {
        XCTAssertNil(try outboundJSON(.socks5)["tls"])
        XCTAssertNil(try outboundJSON(.httpConnect)["tls"])
    }

    func testSingBoxOutboundOmitsThePasswordWhenAsked() throws {
        let object = try outboundJSON(includePassword: false)
        XCTAssertNil(object["password"])
        XCTAssertEqual(object["username"] as? String, "example-user")
    }

    func testSingBoxOutboundOmitsCredentialsEntirelyForAnOpenProxy() throws {
        let text = ProxyExportFormatter.text(
            for: profile(username: nil),
            credential: nil,
            format: .singBoxOutbound
        )
        let data = try XCTUnwrap(text.data(using: .utf8))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["username"])
        XCTAssertNil(object["password"])
    }

    func testSingBoxOutboundFallsBackToATagWhenTheNameIsEmpty() throws {
        let text = ProxyExportFormatter.text(
            for: profile(name: ""),
            credential: credential,
            format: .singBoxOutbound
        )
        let data = try XCTUnwrap(text.data(using: .utf8))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["tag"] as? String, "proxy")
    }

    // MARK: Plain fields

    func testPlainFieldsListsEverything() {
        let text = ProxyExportFormatter.text(
            for: profile(),
            credential: credential,
            format: .plainFields
        )
        XCTAssertTrue(text.contains("Name:     Frankfurt"), text)
        XCTAssertTrue(text.contains("Protocol: SOCKS5"), text)
        XCTAssertTrue(text.contains("Server:   203.0.113.7"), text)
        XCTAssertTrue(text.contains("Port:     1080"), text)
        XCTAssertTrue(text.contains("Username: example-user"), text)
        XCTAssertTrue(text.contains("Password: example-password"), text)
    }

    func testPlainFieldsSaysWhenThePasswordIsNotIncluded() {
        let text = ProxyExportFormatter.text(
            for: profile(),
            credential: credential,
            format: .plainFields,
            options: ProxyExportOptions(includePassword: false)
        )
        XCTAssertTrue(text.contains("Password: (not included)"), text)
        XCTAssertFalse(text.contains("example-password"), text)
    }

    // MARK: The secret guarantee

    func testNoFormatLeaksThePasswordWhenItWasExcluded() {
        for format in ProxyExportFormat.allCases {
            let text = ProxyExportFormatter.text(
                for: profile(),
                credential: credential,
                format: format,
                options: ProxyExportOptions(includePassword: false)
            )
            XCTAssertFalse(
                text.contains("example-password"),
                "\(format.rawValue) leaked the password: \(text)"
            )
        }
    }

    func testEveryFormatIncludesThePasswordByDefault() {
        // The default has to be useful, since an export without the password does
        // not work — the UI is what warns about it, not the formatter.
        for format in ProxyExportFormat.allCases {
            let text = ProxyExportFormatter.text(for: profile(), credential: credential, format: format)
            XCTAssertTrue(
                text.contains("example-password"),
                "\(format.rawValue) omitted the password by default: \(text)"
            )
        }
    }

    func testEveryFormatHandlesAProfileWithNoCredentials() {
        for format in ProxyExportFormat.allCases {
            let text = ProxyExportFormatter.text(
                for: profile(username: nil),
                credential: nil,
                format: format
            )
            XCTAssertFalse(text.isEmpty, "\(format.rawValue) produced nothing")
            XCTAssertFalse(text.contains("nil"), "\(format.rawValue) interpolated an optional: \(text)")
        }
    }

    func testFormatsAdvertiseThemselvesCompletely() {
        for format in ProxyExportFormat.allCases {
            XCTAssertFalse(format.title.isEmpty)
            XCTAssertFalse(format.subtitle.isEmpty)
            XCTAssertTrue(["txt", "json"].contains(format.fileExtension))
        }
    }
}
