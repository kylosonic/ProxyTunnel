//
//  ModelTests.swift
//  ProxyTunnelCoreTests
//
//  §21: configuration encoding/decoding, connection state handling, credential
//  redaction.
//

import XCTest
@testable import ProxyTunnelCore

final class ProxyProfileCodingTests: XCTestCase {

    func testRoundTripsThroughJSON() throws {
        let profile = ProxyProfile(
            name: "My Proxy",
            host: "example.proxy.com",
            port: 12345,
            protocolType: .socks5,
            username: "example-user",
            passwordReference: "proxy-password-abc",
            notes: "a note"
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ProxyProfile.self, from: data)
        XCTAssertEqual(decoded, profile)
    }

    func testEncodesProtocolUnderTheReadableKey() throws {
        let profile = ProxyProfile(name: "p", host: "h", port: 1080, protocolType: .httpConnect)
        let data = try JSONEncoder().encode(profile)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"protocol\":\"http-connect\""), json)
    }

    func testThereIsNoPasswordPropertyToLeak() throws {
        let profile = ProxyProfile(
            name: "p",
            host: "example.proxy.com",
            port: 1080,
            protocolType: .socks5,
            username: "user",
            passwordReference: "ref"
        )
        let json = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
        XCTAssertFalse(json.lowercased().contains("password\""), "the profile must never carry a password field")
        XCTAssertFalse(json.contains("hunter2"))
    }

    func testDecodesAProfileWrittenWithoutNewerFields() throws {
        // A file written by an older build that had no `isMock` or `notes`.
        let json = """
        {"id":"\(UUID().uuidString)","name":"old","host":"h.example.com","port":1080,"protocol":"socks5"}
        """
        let profile = try JSONDecoder().decode(ProxyProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.name, "old")
        XCTAssertTrue(profile.isEnabled)
        XCTAssertFalse(profile.isMock)
        XCTAssertNil(profile.notes)
    }

    func testBracketsIPv6InTheDisplayEndpoint() {
        let profile = ProxyProfile(name: "p", host: "2001:db8::1", port: 1080, protocolType: .socks5)
        XCTAssertEqual(profile.displayEndpoint, "[2001:db8::1]:1080")
    }

    func testRedactedSummaryHidesTheUsernameAndNeverMentionsAPassword() {
        let profile = ProxyProfile(
            name: "p",
            host: "example.proxy.com",
            port: 1080,
            protocolType: .socks5,
            username: "example-user",
            passwordReference: "ref"
        )
        let summary = profile.redactedSummary
        XCTAssertFalse(summary.contains("example-user"))
        XCTAssertTrue(summary.contains("hasPassword: true"))
    }

    func testDescriptionIsRedacted() {
        let profile = ProxyProfile(
            name: "p", host: "h.example.com", port: 1, protocolType: .socks5,
            username: "example-user", passwordReference: "ref"
        )
        XCTAssertFalse("\(profile)".contains("example-user"))
        XCTAssertFalse("\(profile)".contains("ref"))
    }
}

final class TunnelConfigurationTests: XCTestCase {

    private func makeConfiguration(
        delivery: TunnelConfiguration.CredentialDelivery = .sharedContainer
    ) -> TunnelConfiguration {
        TunnelConfiguration(
            profileID: UUID().uuidString,
            profileName: "My Proxy",
            host: "example.proxy.com",
            port: 12345,
            protocolType: .socks5,
            username: "example-user",
            inlinePassword: delivery == .inlineProviderConfiguration ? "example-password" : nil,
            resolvedProxyAddresses: ["203.0.113.7", "2001:db8::7"],
            credentialDelivery: delivery
        )
    }

    func testRoundTripsThroughProviderConfiguration() throws {
        let configuration = makeConfiguration()
        let encoded = try configuration.providerConfiguration()
        let decoded = try TunnelConfiguration.decode(providerConfiguration: encoded)
        XCTAssertEqual(decoded, configuration)
    }

    func testProviderConfigurationIsPlistSafe() throws {
        let encoded = try makeConfiguration().providerConfiguration()
        XCTAssertNoThrow(try PropertyListSerialization.data(fromPropertyList: encoded, format: .binary, options: 0))
    }

    func testRefusesAConfigurationFromTheFuture() throws {
        var encoded = try makeConfiguration().providerConfiguration()
        encoded["ProxyTunnelSchemaVersion"] = TunnelConfiguration.currentSchemaVersion + 1
        XCTAssertThrowsError(try TunnelConfiguration.decode(providerConfiguration: encoded)) { error in
            guard case TunnelConfiguration.CodingError.unsupportedSchemaVersion = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testRejectsAMissingPayload() {
        XCTAssertThrowsError(try TunnelConfiguration.decode(providerConfiguration: [:]))
    }

    func testRedactedSummaryNeverContainsThePassword() {
        let summary = makeConfiguration(delivery: .inlineProviderConfiguration).redactedSummary
        XCTAssertFalse(summary.contains("example-password"))
        XCTAssertFalse(summary.contains("example-user"))
        XCTAssertTrue(summary.contains("credential=inlineProviderConfiguration"))
    }

    func testCredentialIsBuiltOnlyWhenBothHalvesExist() {
        XCTAssertNotNil(makeConfiguration(delivery: .inlineProviderConfiguration).credential)

        var noPassword = makeConfiguration()
        noPassword.username = "example-user"
        noPassword.inlinePassword = nil
        XCTAssertNil(noPassword.credential)

        var noUsername = makeConfiguration()
        noUsername.username = nil
        noUsername.inlinePassword = "x"
        XCTAssertNil(noUsername.credential)
    }

    func testDefaultAddressesAreValidAndDoNotCollide() {
        XCTAssertNotNil(IPAddress(presentationName: TunnelNetworkDefaults.ipv4Address))
        XCTAssertNotNil(IPAddress(presentationName: TunnelNetworkDefaults.ipv6Address))
        XCTAssertTrue(IPAddress(presentationName: TunnelNetworkDefaults.ipv4Address)!.isIPv4)
        XCTAssertTrue(IPAddress(presentationName: TunnelNetworkDefaults.ipv6Address)!.isIPv6)
    }
}

final class TunnelConnectionStateTests: XCTestCase {

    func testDisconnectedWhenNothingIsHappening() {
        let state = TunnelConnectionState.from(
            vpnStatus: .disconnected,
            profileName: nil,
            connectedSince: nil,
            lastFailure: nil,
            mockActive: false
        )
        XCTAssertEqual(state, .disconnected)
    }

    func testCarriesTheFailureIntoTheFailedState() {
        let failure = TunnelFailure(kind: .authenticationFailed, title: "Authentication failed", message: "nope")
        let state = TunnelConnectionState.from(
            vpnStatus: .disconnected,
            profileName: nil,
            connectedSince: nil,
            lastFailure: failure,
            mockActive: false
        )
        XCTAssertEqual(state, .failed(failure))
        XCTAssertEqual(state.title, "Connection Failed")
    }

    func testMockModeNeverLooksLikeARealConnection() {
        // The controller renders a mock session through the same enum, which is
        // why the *label* is overridden in the view. This test pins down the one
        // thing the enum itself must never do: report `.connected` from a status
        // that is not connected.
        let state = TunnelConnectionState.from(
            vpnStatus: .disconnected,
            profileName: nil,
            connectedSince: nil,
            lastFailure: nil,
            mockActive: true
        )
        XCTAssertEqual(state, .disconnected)
    }

    func testConnectedReportsTheSessionStart() {
        let since = Date(timeIntervalSince1970: 1_000_000)
        let state = TunnelConnectionState.from(
            vpnStatus: .connected,
            profileName: "p",
            connectedSince: since,
            lastFailure: nil,
            mockActive: false
        )
        XCTAssertTrue(state.isConnected)
        XCTAssertEqual(state.sessionStart, since)
        XCTAssertEqual(state.title, "Connected")
    }

    func testReassertingIsTreatedAsConnecting() {
        let state = TunnelConnectionState.from(
            vpnStatus: .reasserting,
            profileName: nil,
            connectedSince: nil,
            lastFailure: nil,
            mockActive: false
        )
        if case .connecting = state {} else { XCTFail("expected connecting, got \(state)") }
        XCTAssertTrue(state.isBusy)
    }

    func testBusyFlags() {
        XCTAssertTrue(TunnelConnectionState.connecting(startedAt: Date()).isBusy)
        XCTAssertTrue(TunnelConnectionState.disconnecting.isBusy)
        XCTAssertFalse(TunnelConnectionState.disconnected.isBusy)
        XCTAssertFalse(TunnelConnectionState.connected(since: Date(), profileName: nil).isBusy)
    }
}

final class LogRedactorTests: XCTestCase {

    func testMasksUserInfoInAURL() {
        let redacted = LogRedactor.redact("socks5://example-user:example-password@proxy.example.com:1080")
        XCTAssertFalse(redacted.contains("example-password"))
        XCTAssertFalse(redacted.contains("example-user"))
        XCTAssertTrue(redacted.contains("proxy.example.com"))
    }

    func testMasksKeyValueSecrets() {
        for input in ["password=hunter2", "passwd: hunter2", "token=abcdef", "secret = hunter2", "api_key=hunter2"] {
            let redacted = LogRedactor.redact(input)
            XCTAssertFalse(redacted.contains("hunter2") || redacted.contains("abcdef"), "leaked in \(input) -> \(redacted)")
        }
    }

    func testMasksProxyAuthorizationHeader() {
        let redacted = LogRedactor.redact("Proxy-Authorization: Basic dXNlcjpwYXNz")
        XCTAssertFalse(redacted.contains("dXNlcjpwYXNz"))
    }

    func testMasksLongBase64LikeBlobs() {
        let blob = "QWxsIHdvcmsgYW5kIG5vIHBsYXkgbWFrZXMgSmFjayBhIGR1bGwgYm95"
        XCTAssertFalse(LogRedactor.redact("value \(blob) end").contains(blob))
    }

    func testLeavesOrdinaryTextAlone() {
        let text = "SOCKS5 CONNECT succeeded to 93.184.216.34:443"
        XCTAssertEqual(LogRedactor.redact(text), text)
    }

    func testMasksUsernameButKeepsItCorrelatable() {
        XCTAssertEqual(LogRedactor.maskUsername("example-user"), "e•••r")
        XCTAssertEqual(LogRedactor.maskUsername("ab"), "••")
        XCTAssertEqual(LogRedactor.maskUsername(nil), "<none>")
        XCTAssertEqual(LogRedactor.maskUsername(""), "<none>")
    }

    func testCredentialDescriptionIsRedacted() {
        let credential = ProxyCredential(username: "example-user", password: "example-password")
        XCTAssertEqual("\(credential)", "ProxyCredential(e•••r:••••••)")
        XCTAssertFalse(credential.debugDescription.contains("example-password"))
    }

    func testTunnelFailureRedactsItsOwnInput() {
        let failure = TunnelFailure(
            kind: .invalidCredentials,
            title: "Rejected",
            message: "password=example-password was rejected",
            underlyingDescription: "user:example-password@host"
        )
        XCTAssertFalse(failure.message.contains("example-password"))
        XCTAssertFalse(failure.underlyingDescription?.contains("example-password") ?? false)
        XCTAssertFalse(failure.diagnosticLine.contains("example-password"))
    }
}

final class ProxyEndpointTests: XCTestCase {

    func testConnectAuthorityBracketsIPv6() {
        let endpoint = ProxyEndpoint(host: "2001:db8::1", port: 443, protocolType: .httpsConnect)
        XCTAssertEqual(endpoint.connectAuthority, "[2001:db8::1]:443")
    }

    func testConnectAuthorityLeavesHostnamesAlone() {
        let endpoint = ProxyEndpoint(host: "example.proxy.com", port: 1080, protocolType: .socks5)
        XCTAssertEqual(endpoint.connectAuthority, "example.proxy.com:1080")
    }

    func testDescriptionNeverContainsThePassword() {
        let endpoint = ProxyEndpoint(
            host: "h.example.com",
            port: 1080,
            protocolType: .socks5,
            credential: ProxyCredential(username: "example-user", password: "example-password")
        )
        XCTAssertFalse("\(endpoint)".contains("example-password"))
        XCTAssertFalse("\(endpoint)".contains("example-user"))
    }

    func testProtocolCapabilitiesMatchTheImplementation() {
        XCTAssertTrue(ProxyProtocol.socks5.supportsUDP)
        XCTAssertFalse(ProxyProtocol.httpConnect.supportsUDP)
        XCTAssertFalse(ProxyProtocol.httpsConnect.supportsUDP)
        XCTAssertTrue(ProxyProtocol.httpsConnect.usesTLS)
        XCTAssertFalse(ProxyProtocol.httpConnect.usesTLS)
        XCTAssertTrue(ProxyProtocol.allCases.allSatisfy(\.supportsTCP))
    }
}
