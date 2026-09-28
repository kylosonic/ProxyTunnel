//
//  ProxyImportParserTests.swift
//  ProxyTunnelCoreTests
//
//  Table-driven coverage of every format the importer claims to accept.
//
//  The claim in the parser's header comment is a promise to the user, so each
//  line of that list has a test here. Two properties matter beyond the happy
//  paths:
//
//    * a successful parse always has a usable host and an in-range port, and
//    * a password never survives into `redactedSource`.
//

import XCTest
@testable import ProxyTunnelCore

final class ProxyImportParserTests: XCTestCase {

    // MARK: Helpers

    private func parseOne(
        _ line: String,
        defaultProtocol: ProxyProtocol? = nil,
        file: StaticString = #filePath,
        line sourceLine: UInt = #line
    ) -> ProxyImportCandidate? {
        let entry = ProxyImportParser.parseLine(line, defaultProtocol: defaultProtocol)
        if let failure = entry.failure {
            XCTFail("expected \(line.debugDescription) to parse, got: \(failure.message)", file: file, line: sourceLine)
            return nil
        }
        return entry.candidate
    }

    private func assertParses(
        _ line: String,
        host: String,
        port: Int,
        protocolType: ProxyProtocol? = nil,
        username: String?,
        password: String?,
        defaultProtocol: ProxyProtocol? = nil,
        file: StaticString = #filePath,
        line sourceLine: UInt = #line
    ) {
        guard let candidate = parseOne(line, defaultProtocol: defaultProtocol, file: file, line: sourceLine) else { return }
        XCTAssertEqual(candidate.host, host, "host for \(line.debugDescription)", file: file, line: sourceLine)
        XCTAssertEqual(candidate.port, port, "port for \(line.debugDescription)", file: file, line: sourceLine)
        XCTAssertEqual(candidate.username, username, "username for \(line.debugDescription)", file: file, line: sourceLine)
        XCTAssertEqual(candidate.password, password, "password for \(line.debugDescription)", file: file, line: sourceLine)
        if let protocolType {
            XCTAssertEqual(candidate.protocolType, protocolType, "protocol for \(line.debugDescription)", file: file, line: sourceLine)
        }
    }

    private func assertFails(
        _ line: String,
        file: StaticString = #filePath,
        line sourceLine: UInt = #line
    ) {
        let entry = ProxyImportParser.parseLine(line, defaultProtocol: nil)
        XCTAssertNil(entry.candidate, "expected \(line.debugDescription) NOT to parse", file: file, line: sourceLine)
        XCTAssertNotNil(entry.failure, file: file, line: sourceLine)
    }

    // MARK: Scheme forms

    func testFullSocks5URL() {
        assertParses(
            "socks5://example-user:example-password@203.0.113.7:1080",
            host: "203.0.113.7", port: 1080, protocolType: .socks5,
            username: "example-user", password: "example-password"
        )
    }

    func testSchemeVariantsMapToSocks5() {
        for scheme in ["socks5", "socks5h", "socks"] {
            assertParses(
                "\(scheme)://user:pw@proxy.example.com:1080",
                host: "proxy.example.com", port: 1080, protocolType: .socks5,
                username: "user", password: "pw"
            )
        }
    }

    func testHTTPAndHTTPSMapToTheConnectProtocols() {
        assertParses("http://user:pw@proxy.example.com:8080",
                     host: "proxy.example.com", port: 8080, protocolType: .httpConnect,
                     username: "user", password: "pw")
        assertParses("https://user:pw@proxy.example.com:443",
                     host: "proxy.example.com", port: 443, protocolType: .httpsConnect,
                     username: "user", password: "pw")
    }

    func testURLWithoutCredentials() {
        assertParses("socks5://203.0.113.7:1080",
                     host: "203.0.113.7", port: 1080, protocolType: .socks5,
                     username: nil, password: nil)
    }

    func testURLWithoutAPortUsesTheProtocolDefaultAndSaysSo() throws {
        let candidate = try XCTUnwrap(parseOne("socks5://proxy.example.com"))
        XCTAssertEqual(candidate.port, 1080)
        XCTAssertTrue(candidate.notes.contains { $0.contains("No port given") }, candidate.notes.joined(separator: "; "))
    }

    func testURLWithATrailingPath() {
        assertParses("socks5://user:pw@proxy.example.com:1080/some/path?x=1",
                     host: "proxy.example.com", port: 1080, protocolType: .socks5,
                     username: "user", password: "pw")
    }

    func testPercentEncodedCredentialsAreDecoded() {
        assertParses("socks5://ex%40mple:p%40ss%3Aword@proxy.example.com:1080",
                     host: "proxy.example.com", port: 1080, protocolType: .socks5,
                     username: "ex@mple", password: "p@ss:word")
    }

    func testBracketedIPv6URL() {
        assertParses("socks5://user:pw@[2001:db8::1]:1080",
                     host: "2001:db8::1", port: 1080, protocolType: .socks5,
                     username: "user", password: "pw")
    }

    func testPasswordContainingAtSignInAURL() {
        // The last "@" is the separator, because a host cannot contain one.
        assertParses("socks5://user:pa@ss@proxy.example.com:1080",
                     host: "proxy.example.com", port: 1080, protocolType: .socks5,
                     username: "user", password: "pa@ss")
    }

    func testUnknownSchemeFallsBackWithANote() throws {
        let candidate = try XCTUnwrap(parseOne("weird://user:pw@proxy.example.com:1080"))
        XCTAssertEqual(candidate.host, "proxy.example.com")
        XCTAssertEqual(candidate.port, 1080)
        XCTAssertTrue(candidate.notes.contains { $0.contains("Unrecognised scheme") }, candidate.notes.joined(separator: "; "))
    }

    func testSocks4IsRejectedWithAnExplanation() {
        let entry = ProxyImportParser.parseLine("socks4://user:pw@proxy.example.com:1080")
        XCTAssertNil(entry.candidate)
        guard case .unsupportedScheme(let scheme)? = entry.failure else {
            return XCTFail("expected unsupportedScheme, got \(String(describing: entry.failure))")
        }
        XCTAssertEqual(scheme, "socks4")
    }

    // MARK: Colon-separated forms

    func testHostPortUserPass() {
        assertParses("203.0.113.7:1080:example-user:example-password",
                     host: "203.0.113.7", port: 1080,
                     username: "example-user", password: "example-password")
    }

    func testUserPassHostPort() {
        assertParses("example-user:example-password:203.0.113.7:1080",
                     host: "203.0.113.7", port: 1080,
                     username: "example-user", password: "example-password")
    }

    func testBareHostAndPort() throws {
        let candidate = try XCTUnwrap(parseOne("203.0.113.7:1080"))
        XCTAssertEqual(candidate.host, "203.0.113.7")
        XCTAssertEqual(candidate.port, 1080)
        XCTAssertNil(candidate.username)
        XCTAssertNil(candidate.password)
        XCTAssertTrue(candidate.notes.contains { $0.contains("No credentials") })
    }

    /// The case that makes the scoring worth having: both readings are
    /// syntactically possible, and only one of them is right.
    func testNumericPasswordDoesNotGetMistakenForAHostFirstLine() throws {
        // user:pass:host:port where the password happens to be numeric.
        let userFirst = try XCTUnwrap(parseOne("john:12345:203.0.113.7:8080"))
        XCTAssertEqual(userFirst.host, "203.0.113.7", "an IP literal beats a single label")
        XCTAssertEqual(userFirst.port, 8080)
        XCTAssertEqual(userFirst.username, "john")
        XCTAssertEqual(userFirst.password, "12345")

        // host:port:user:pass where the username happens to be numeric.
        let hostFirst = try XCTUnwrap(parseOne("203.0.113.7:8080:12345:john"))
        XCTAssertEqual(hostFirst.host, "203.0.113.7")
        XCTAssertEqual(hostFirst.port, 8080)
        XCTAssertEqual(hostFirst.username, "12345")
        XCTAssertEqual(hostFirst.password, "john")
    }

    func testGenuinelyTiedLineIsFlaggedAsAmbiguous() throws {
        // Two IPs and two numeric fields: nothing distinguishes the readings, so
        // the host-first assumption is made and disclosed.
        let candidate = try XCTUnwrap(parseOne("203.0.113.7:8080:198.51.100.9:9090"))
        XCTAssertEqual(candidate.host, "203.0.113.7")
        XCTAssertTrue(candidate.isAmbiguous, "the tie should be disclosed")
        XCTAssertTrue(candidate.notes.contains { $0.contains("either way round") }, candidate.notes.joined(separator: "; "))
    }

    func testPasswordContainingTheSeparatorIsKeptWhole() {
        assertParses("203.0.113.7:1080:user:pa:ss:word",
                     host: "203.0.113.7", port: 1080,
                     username: "user", password: "pa:ss:word")
    }

    func testBracketedIPv6InAColonSeparatedLine() {
        assertParses("[2001:db8::1]:1080:user:pw",
                     host: "2001:db8::1", port: 1080,
                     username: "user", password: "pw")
    }

    // MARK: @ forms

    func testCredentialsAtHost() {
        assertParses("example-user:example-password@203.0.113.7:1080",
                     host: "203.0.113.7", port: 1080,
                     username: "example-user", password: "example-password")
    }

    func testHostAtCredentials() {
        assertParses("203.0.113.7:1080@example-user:example-password",
                     host: "203.0.113.7", port: 1080,
                     username: "example-user", password: "example-password")
    }

    func testHostFirstWithAnAtSignInThePassword() throws {
        let candidate = try XCTUnwrap(parseOne("203.0.113.7:1080@user:pa@ss"))
        XCTAssertEqual(candidate.host, "203.0.113.7")
        XCTAssertEqual(candidate.username, "user")
        XCTAssertEqual(candidate.password, "pa@ss")
    }

    // MARK: Separated forms

    func testWhitespaceSeparated() {
        assertParses("203.0.113.7 1080 example-user example-password",
                     host: "203.0.113.7", port: 1080,
                     username: "example-user", password: "example-password")
    }

    func testTabSeparated() {
        assertParses("203.0.113.7\t1080\tuser\tpw",
                     host: "203.0.113.7", port: 1080, username: "user", password: "pw")
    }

    func testCommaSeparated() {
        assertParses("203.0.113.7,1080,user,pw",
                     host: "203.0.113.7", port: 1080, username: "user", password: "pw")
    }

    func testSemicolonSeparated() {
        assertParses("203.0.113.7;1080;user;pw",
                     host: "203.0.113.7", port: 1080, username: "user", password: "pw")
    }

    // MARK: Key = value

    func testKeyValuePairs() {
        assertParses("host=203.0.113.7 port=1080 user=example-user pass=example-password",
                     host: "203.0.113.7", port: 1080,
                     username: "example-user", password: "example-password")
    }

    func testKeyValueWithColonsAndAlternativeNames() {
        assertParses("server:203.0.113.7:port:1080:username:example-user:password:example-password",
                     host: "203.0.113.7", port: 1080,
                     username: "example-user", password: "example-password")
    }

    func testKeyValueWithAnExplicitProtocol() {
        assertParses("ip=203.0.113.7 port=8080 protocol=http user=u pass=p",
                     host: "203.0.113.7", port: 8080, protocolType: .httpConnect,
                     username: "u", password: "p")
    }

    // MARK: JSON

    func testJSONObject() {
        let line = #"{"host":"203.0.113.7","port":1080,"username":"u","password":"p","protocol":"socks5"}"#
        assertParses(line, host: "203.0.113.7", port: 1080, protocolType: .socks5, username: "u", password: "p")
    }

    func testJSONArray() {
        let text = """
        [
          {"host":"203.0.113.7","port":1080,"username":"u1","password":"p1"},
          {"host":"198.51.100.9","port":8080,"username":"u2","password":"p2","protocol":"http"}
        ]
        """
        let report = ProxyImportParser.parse(text)
        XCTAssertEqual(report.ready.count, 2)
        XCTAssertTrue(report.problems.isEmpty, report.problems.map(\.redactedSource).joined(separator: ", "))
        XCTAssertEqual(report.ready[0].candidate?.host, "203.0.113.7")
        XCTAssertEqual(report.ready[1].candidate?.protocolType, .httpConnect)
    }

    func testJSONWrappedInAProxiesKey() {
        let text = #"{"proxies":[{"host":"203.0.113.7","port":1080}]}"#
        let report = ProxyImportParser.parse(text)
        XCTAssertEqual(report.ready.count, 1)
        XCTAssertEqual(report.ready.first?.candidate?.host, "203.0.113.7")
    }

    func testJSONArrayEntryWithoutAHostIsReportedNotSilentlyDropped() {
        let text = #"[{"port":1080},{"host":"203.0.113.7","port":1080}]"#
        let report = ProxyImportParser.parse(text)
        XCTAssertEqual(report.ready.count, 1)
        XCTAssertEqual(report.problems.count, 1)
    }

    // MARK: Labels, comments, noise

    func testLabelBeforeAPipe() throws {
        let candidate = try XCTUnwrap(parseOne("Frankfurt | socks5://user:pw@203.0.113.7:1080"))
        XCTAssertEqual(candidate.name, "Frankfurt")
        XCTAssertEqual(candidate.host, "203.0.113.7")
        XCTAssertEqual(candidate.port, 1080)
    }

    func testCommentsAndBlankLinesAreIgnored() {
        let text = """
        # ProxyCheap — Germany
        // generated 2026-01-01

        203.0.113.7:1080:user:pw

        """
        let report = ProxyImportParser.parse(text)
        XCTAssertEqual(report.ready.count, 1)
        XCTAssertTrue(report.problems.isEmpty, "comments must not be reported as problems")
        // Two comments; the blank lines are skipped entirely rather than listed.
        XCTAssertEqual(report.ignored.count, 2)
    }

    func testCRLFAndSurroundingQuotes() {
        assertParses("\"203.0.113.7:1080:user:pw\"\r",
                     host: "203.0.113.7", port: 1080, username: "user", password: "pw")
    }

    // MARK: Protocol selection

    func testExplicitProtocolPickerWinsWhenTheLineHasNone() {
        assertParses("203.0.113.7:1080:user:pw",
                     host: "203.0.113.7", port: 1080, protocolType: .httpsConnect,
                     username: "user", password: "pw",
                     defaultProtocol: .httpsConnect)
    }

    func testSchemeInTheTextBeatsThePicker() {
        assertParses("socks5://user:pw@203.0.113.7:1080",
                     host: "203.0.113.7", port: 1080, protocolType: .socks5,
                     username: "user", password: "pw",
                     defaultProtocol: .httpConnect)
    }

    func testPortInferenceIsConservativeAndDisclosed() throws {
        let http = try XCTUnwrap(parseOne("203.0.113.7:8080"))
        XCTAssertEqual(http.protocolType, .httpConnect)
        XCTAssertTrue(http.notes.contains { $0.contains("guessed from port") }, http.notes.joined(separator: "; "))

        let socks = try XCTUnwrap(parseOne("203.0.113.7:1080"))
        XCTAssertEqual(socks.protocolType, .socks5)

        // 443 is used by SOCKS5 providers as often as by TLS proxies, so it must
        // not be guessed as HTTPS.
        let ambiguousPort = try XCTUnwrap(parseOne("203.0.113.7:443"))
        XCTAssertEqual(ambiguousPort.protocolType, .socks5)
    }

    // MARK: Rejections

    func testGarbageLinesAreRejectedWithAUsefulMessage() {
        assertFails("hello world")
        assertFails("this is not a proxy at all")
        assertFails("203.0.113.7")            // no port, and a bare host is not enough
        assertFails("203.0.113.7:0")          // port out of range
        assertFails("203.0.113.7:99999")
        assertFails("203.0.113.7:notaport")
    }

    func testRejectionMessagesAreActionable() throws {
        let entry = ProxyImportParser.parseLine("hello world")
        let message = try XCTUnwrap(entry.failure?.message)
        XCTAssertTrue(message.contains("socks5://") || message.contains("host:1080"), message)
    }

    // MARK: Redaction

    func testPasswordNeverSurvivesIntoTheDisplayedLine() {
        let lines = [
            "socks5://example-user:example-password@203.0.113.7:1080",
            "203.0.113.7:1080:example-user:example-password",
            "example-user:example-password@203.0.113.7:1080",
            "203.0.113.7:1080@example-user:example-password",
            "host=203.0.113.7 port=1080 user=example-user password=example-password",
            "Frankfurt | socks5://example-user:example-password@203.0.113.7:1080",
            #"{"host":"203.0.113.7","port":1080,"username":"example-user","password":"example-password"}"#
        ]
        for line in lines {
            let entry = ProxyImportParser.parseLine(line)
            XCTAssertNotNil(entry.candidate, "\(line) should parse")
            XCTAssertFalse(
                entry.redactedSource.contains("example-password"),
                "the password leaked into redactedSource for \(line.debugDescription): \(entry.redactedSource)"
            )
            XCTAssertEqual(entry.candidate?.password, "example-password",
                           "the parsed value must still be intact for \(line.debugDescription)")
        }
    }

    func testRedactedSourceOfAFailedLineIsStillMasked() {
        // A line we cannot read may still contain a credential; the copy shown to
        // the user and written to any log must not.
        let entry = ProxyImportParser.parseLine("garbage user:example-password@nowhere")
        XCTAssertNotNil(entry.failure)
        XCTAssertFalse(entry.redactedSource.contains("example-password"), entry.redactedSource)
    }

    func testCandidateDescriptionIsLogSafe() {
        let candidate = ProxyImportCandidate(
            host: "203.0.113.7", port: 1080, protocolType: .socks5,
            username: "example-user", password: "example-password"
        )
        XCTAssertFalse(candidate.redactedDescription.contains("example-password"))
        XCTAssertFalse(candidate.redactedDescription.contains("example-user"))
    }

    // MARK: Bulk report

    func testMixedBulkPaste() {
        let text = """
        # three good ones, one broken
        socks5://u1:p1@203.0.113.7:1080
        198.51.100.9:8080:u2:p2
        https://u3:p3@[2001:db8::1]:443
        this line is not a proxy
        """
        let report = ProxyImportParser.parse(text)
        XCTAssertEqual(report.ready.count, 3)
        XCTAssertEqual(report.problems.count, 1)
        XCTAssertEqual(report.ignored.count, 1)
        XCTAssertTrue(report.hasProblems)
        XCTAssertEqual(report.ready[2].candidate?.host, "2001:db8::1")
    }

    func testEmptyInput() {
        let report = ProxyImportParser.parse("   \n\n  ")
        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(report.summary, "Nothing to import yet.")
    }

    func testSummaryCounts() {
        let report = ProxyImportParser.parse("203.0.113.7:1080\nnonsense\n# note")
        XCTAssertEqual(report.summary, "1 ready · 1 need attention · 1 ignored")
    }

    // MARK: Integration with validation

    func testEveryAcceptedLineSurvivesTheProfileValidator() {
        // The parser's contract is that a successful parse is storable. The manual
        // form's validator is the authority on that, so a parsed candidate must
        // pass it unchanged.
        let lines = [
            "socks5://example-user:example-password@203.0.113.7:1080",
            "203.0.113.7:1080:example-user:example-password",
            "example-user:example-password:203.0.113.7:1080",
            "example-user:example-password@203.0.113.7:1080",
            "203.0.113.7:1080@example-user:example-password",
            "203.0.113.7:1080",
            "203.0.113.7 1080 example-user example-password",
            "host=203.0.113.7 port=1080 user=example-user pass=example-password",
            "socks5://user:pw@[2001:db8::1]:1080",
            "Frankfurt | socks5://user:pw@proxy.example.com:1080"
        ]
        for line in lines {
            guard let candidate = parseOne(line) else { continue }
            let (report, input) = ProxyProfileValidator.validate(candidate.asDraft())
            XCTAssertTrue(report.isValid, "\(line) parsed but does not validate: \(report.summary)")
            XCTAssertEqual(input?.host, candidate.host, line)
            XCTAssertEqual(input?.port, candidate.port, line)
            XCTAssertEqual(input?.username, candidate.username, line)
            XCTAssertEqual(input?.password, candidate.password, line)
        }
    }

    func testNameFallsBackToTheEndpoint() {
        let candidate = ProxyImportCandidate(host: "203.0.113.7", port: 1080, protocolType: .socks5)
        XCTAssertEqual(candidate.asDraft().name, "203.0.113.7:1080")
        XCTAssertEqual(candidate.asDraft(suggestedName: "Germany").name, "Germany")
    }
}
