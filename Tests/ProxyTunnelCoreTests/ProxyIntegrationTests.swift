//
//  ProxyIntegrationTests.swift
//  ProxyTunnelCoreTests
//
//  Real sockets, real handshakes, real bytes.
//
//  Every test here starts a proxy on loopback and a target server behind it, then
//  drives the production client (`ProxyConnector` / `ProxySession` /
//  `ProxyProbe`) against them over TCP. Nothing is stubbed, so a passing run
//  means the wire format is actually right.
//
//  These run on the iOS Simulator and therefore also on GitHub's macOS runners.
//  What they do NOT prove is that the packet tunnel can start on a device — that
//  needs the Network Extension entitlement. `docs/TESTING.md` is explicit about
//  the difference.
//

import XCTest
import Network
@testable import ProxyTunnelCore

final class ProxyIntegrationTests: XCTestCase {

    private var echoServer: LocalEchoServer!
    private var socksServer: LocalSOCKS5Server!
    private var httpServer: LocalHTTPConnectServer!
    private var echoPort: UInt16 = 0
    private var socksPort: UInt16 = 0
    private var httpPort: UInt16 = 0

    private let queue = DispatchQueue(label: "proxy.integration.test")

    override func setUpWithError() throws {
        try super.setUpWithError()
        echoServer = try LocalEchoServer()
        echoPort = try echoServer.start()

        socksServer = try LocalSOCKS5Server()
        socksPort = try socksServer.start()

        httpServer = try LocalHTTPConnectServer()
        httpPort = try httpServer.start()

        // These tests are only meaningful if the process can actually accept an
        // inbound loopback connection *and* the production transport can reach it.
        // Skip — loudly, with the reason — rather than fail with connection
        // timeouts that say nothing about the code.
        let echoReachable = LoopbackRequirement.isReachable(port: echoPort)
        let socksReachable = LoopbackRequirement.isReachable(port: socksPort)
        let socksViaProductionTransport = LoopbackRequirement.canOpenProxyTransport(port: socksPort)
        print("""
        [ProxyTunnelTests] ports: echo=\(echoPort) (pinned: \(echoServer.isPinnedToLoopback)) \
        socks5=\(socksPort) (pinned: \(socksServer.isPinnedToLoopback)) \
        http=\(httpPort) (pinned: \(httpServer.isPinnedToLoopback)) | \
        plain-probe reachable: echo=\(echoReachable) socks=\(socksReachable) | \
        production-transport reachable: socks=\(socksViaProductionTransport)
        """)

        try LoopbackRequirement.require(port: echoPort)
        try LoopbackRequirement.requireProxyTransport(port: socksPort)
    }

    override func tearDownWithError() throws {
        socksServer?.stop()
        httpServer?.stop()
        echoServer?.stop()
        try super.tearDownWithError()
    }

    // MARK: Helpers

    private func socksEndpoint(credential: ProxyCredential? = nil) -> ProxyEndpoint {
        ProxyEndpoint(host: "127.0.0.1", port: Int(socksPort), protocolType: .socks5, credential: credential)
    }

    private func httpEndpoint(credential: ProxyCredential? = nil) -> ProxyEndpoint {
        ProxyEndpoint(host: "127.0.0.1", port: Int(httpPort), protocolType: .httpConnect, credential: credential)
    }

    private func targets(for endpoint: ProxyEndpoint) -> [TransportTarget] {
        [TransportTarget(host: "127.0.0.1", port: endpoint.portValue)]
    }

    /// Connects, sends `request`, and returns everything read back until EOF.
    private func roundTrip(
        endpoint: ProxyEndpoint,
        destination: ProxyDestination,
        request: Data,
        timeout: TimeInterval = 10
    ) throws -> Data {
        let connected = expectation(description: "connected")
        var outcome: Result<ProxyConnection, ProxyError>?
        ProxyConnector.connect(
            endpoint: endpoint,
            destination: destination,
            targets: targets(for: endpoint),
            queue: queue,
            connectTimeout: timeout,
            handshakeTimeout: timeout,
            log: nil
        ) { result in
            outcome = result
            connected.fulfill()
        }
        wait(for: [connected], timeout: timeout + 5)

        let connection = try XCTUnwrap(try outcome?.get(), "proxy connection failed: \(String(describing: outcome))")
        defer { connection.close() }

        let wrote = expectation(description: "wrote")
        connection.stream.write(request) { _ in wrote.fulfill() }
        wait(for: [wrote], timeout: timeout)

        var received = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let read = expectation(description: "read")
            var chunk: Data?
            connection.stream.read { result in
                chunk = try? result.get()
                read.fulfill()
            }
            wait(for: [read], timeout: timeout)
            guard let chunk, !chunk.isEmpty else { break }
            received.append(chunk)
            // The echo server replies per read, so one round trip is enough.
            if received.count >= request.count { break }
        }
        return received
    }

    // MARK: SOCKS5

    func testSOCKS5RelaysBytesEndToEnd() throws {
        let payload = Data("hello through socks5".utf8)
        let received = try roundTrip(
            endpoint: socksEndpoint(),
            destination: .connect(host: "127.0.0.1", port: echoPort),
            request: payload
        )
        XCTAssertEqual(received, payload)
        XCTAssertEqual(socksServer.handshakesCompleted, 1)
        XCTAssertEqual(socksServer.requestedDestinations.first, "127.0.0.1:\(echoPort)")
    }

    func testSOCKS5WithUsernamePasswordAuthentication() throws {
        socksServer.credentials = .init(username: "example-user", password: "example-password")
        let payload = Data("authenticated".utf8)
        let received = try roundTrip(
            endpoint: socksEndpoint(credential: ProxyCredential(username: "example-user", password: "example-password")),
            destination: .connect(host: "127.0.0.1", port: echoPort),
            request: payload
        )
        XCTAssertEqual(received, payload)
        XCTAssertEqual(socksServer.authenticationFailures, 0)
    }

    func testSOCKS5WrongPasswordIsReportedAsAuthenticationRejected() {
        socksServer.credentials = .init(username: "example-user", password: "example-password")
        let error = connectExpectingFailure(
            endpoint: socksEndpoint(credential: ProxyCredential(username: "example-user", password: "wrong"))
        )
        XCTAssertEqual(error, .authenticationRejected)
        XCTAssertEqual(socksServer.authenticationFailures, 1)
    }

    func testSOCKS5WithNoCredentialsAgainstAnAuthenticatingProxy() {
        socksServer.credentials = .init(username: "example-user", password: "example-password")
        let error = connectExpectingFailure(endpoint: socksEndpoint(credential: nil))
        XCTAssertEqual(error, .authenticationRequired)
    }

    func testSOCKS5ProxyRefusingTheTargetIsReported() {
        socksServer.forcedReplyCode = 0x05   // connection refused
        let error = connectExpectingFailure(endpoint: socksEndpoint())
        XCTAssertEqual(error, .proxyRefusedConnection("connection refused"))
    }

    func testSOCKS5ServerOfferingOnlyGSSAPI() {
        socksServer.offerOnlyGSSAPI = true
        let error = connectExpectingFailure(
            endpoint: socksEndpoint(credential: ProxyCredential(username: "u", password: "p"))
        )
        XCTAssertEqual(error, .unsupportedAuthMethod(SOCKS5.AuthMethod.gssapi.rawValue))
    }

    // MARK: HTTP CONNECT

    func testHTTPConnectRelaysBytesEndToEnd() throws {
        let payload = Data("hello through http connect".utf8)
        let received = try roundTrip(
            endpoint: httpEndpoint(),
            destination: .connect(host: "127.0.0.1", port: echoPort),
            request: payload
        )
        XCTAssertEqual(received, payload)
        XCTAssertEqual(httpServer.handshakesCompleted, 1)
        XCTAssertEqual(httpServer.requestedAuthorities.first, "127.0.0.1:\(echoPort)")
    }

    func testHTTPConnectSendsCredentialsPreemptively() throws {
        httpServer.credentials = .init(username: "example-user", password: "example-password")
        let payload = Data("proxied".utf8)
        _ = try roundTrip(
            endpoint: httpEndpoint(credential: ProxyCredential(username: "example-user", password: "example-password")),
            destination: .connect(host: "127.0.0.1", port: echoPort),
            request: payload
        )
        let expected = Data("example-user:example-password".utf8).base64EncodedString()
        XCTAssertEqual(httpServer.lastProxyAuthorizationHeader, "Basic \(expected)")
    }

    func testHTTPConnectMissingCredentialsIsReportedAsRequired() {
        httpServer.credentials = .init(username: "example-user", password: "example-password")
        let error = connectExpectingFailure(endpoint: httpEndpoint(credential: nil))
        XCTAssertEqual(error, .authenticationRequired)
    }

    func testHTTPConnectWrongCredentialsIsReportedAsRejected() {
        httpServer.credentials = .init(username: "example-user", password: "example-password")
        let error = connectExpectingFailure(endpoint: httpEndpoint(credential: ProxyCredential(username: "u", password: "p")))
        XCTAssertEqual(error, .authenticationRejected)
    }

    func testHTTPConnectNonSuccessStatusIsReported() {
        httpServer.responseStatusLine = "HTTP/1.1 502 Bad Gateway"
        let error = connectExpectingFailure(endpoint: httpEndpoint())
        if case .proxyRefusedConnection(let summary) = error {
            XCTAssertTrue(summary.contains("502"), summary)
        } else {
            XCTFail("expected proxyRefusedConnection, got \(error)")
        }
    }

    // MARK: Failure modes

    func testConnectionRefusedIsReportedNotHung() {
        // Port 1 on loopback has nothing listening.
        let endpoint = ProxyEndpoint(host: "127.0.0.1", port: 1, protocolType: .socks5)
        let error = connectExpectingFailure(endpoint: endpoint, targets: [TransportTarget(host: "127.0.0.1", port: 1)])
        switch error {
        case .connectionFailed(let detail):
            XCTAssertTrue(detail.contains("refused") || detail.contains("POSIX"), detail)
        case .connectionTimeout:
            break // acceptable; some sandboxes time out instead of refusing
        default:
            XCTFail("unexpected error \(error)")
        }
    }

    func testSpeakingTheWrongProtocolIsReportedClearly() {
        // A server that answers the SOCKS5 greeting with something that is not a
        // SOCKS5 reply. The client must report a protocol mismatch, not hang and
        // not pretend to be connected.
        echoServer.response = Data("NOT A PROXY\r\n\r\n".utf8)

        let endpoint = ProxyEndpoint(host: "127.0.0.1", port: Int(echoPort), protocolType: .socks5)
        let error = connectExpectingFailure(
            endpoint: endpoint,
            targets: [TransportTarget(host: "127.0.0.1", port: echoPort)],
            timeout: 5
        )
        guard case .badServerResponse(let detail) = error else {
            return XCTFail("expected badServerResponse, got \(error.diagnosticDescription)")
        }
        XCTAssertTrue(detail.contains("SOCKS version"), detail)
    }

    func testGarbageAnsweringAnHTTPConnectClientIsReportedClearly() {
        echoServer.response = Data("NOT HTTP AT ALL\r\n\r\n".utf8)

        let endpoint = ProxyEndpoint(host: "127.0.0.1", port: Int(echoPort), protocolType: .httpConnect)
        let error = connectExpectingFailure(
            endpoint: endpoint,
            targets: [TransportTarget(host: "127.0.0.1", port: echoPort)],
            timeout: 5
        )
        guard case .badServerResponse = error else {
            return XCTFail("expected badServerResponse, got \(error.diagnosticDescription)")
        }
    }

    func testUDPAssociateIsRefusedByAnHTTPProxyWithoutTouchingTheNetwork() {
        let settled = expectation(description: "refused")
        var outcome: Result<ProxyConnection, ProxyError>?
        ProxyConnector.connect(
            endpoint: httpEndpoint(),
            destination: .udpAssociate(host: "0.0.0.0", port: 0),
            targets: targets(for: httpEndpoint()),
            queue: queue,
            log: nil
        ) { result in
            outcome = result
            settled.fulfill()
        }
        wait(for: [settled], timeout: 12)

        guard case .failure(let error) = outcome else {
            return XCTFail("an HTTP proxy must never accept UDP ASSOCIATE")
        }
        XCTAssertEqual(error, .addressFamilyUnsupported)
    }

    // MARK: Probe

    func testProbeReportsTheEgressAddress() async throws {
        // The "origin server" returns a complete HTTP response whose body is the
        // caller's public IP, exactly like api.ipify.org does.
        echoServer.response = Data(
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 11\r\nConnection: close\r\n\r\n203.0.113.9".utf8
        )
        socksServer.redirectAllConnectionsTo = (host: "127.0.0.1", port: echoPort)

        var configuration = ProxyProbeConfiguration.default
        configuration.checkHost = "198.51.100.10"
        configuration.checkPort = 80
        configuration.resolvedAddresses = ["127.0.0.1"]
        configuration.timeout = 10

        let report = await ProxyProbe.run(
            endpoint: socksEndpoint(),
            configuration: configuration,
            log: nil
        )

        XCTAssertNil(report.failure, report.failure?.diagnosticLine ?? "")
        XCTAssertEqual(report.httpStatus, 200)
        XCTAssertEqual(report.egressIP, "203.0.113.9")
        XCTAssertTrue(report.isSuccess)
        XCTAssertEqual(report.dialedAddress, "127.0.0.1")
        XCTAssertNotNil(report.tcpConnectDuration)
        XCTAssertNotNil(report.handshakeDuration)
        XCTAssertTrue(report.summaryLines.contains { $0.contains("Traffic exited via 203.0.113.9") })
    }

    func testProbeReportsAFailureWhenNothingIsListening() async {
        let endpoint = ProxyEndpoint(host: "127.0.0.1", port: 1, protocolType: .socks5)
        var configuration = ProxyProbeConfiguration.default
        configuration.resolvedAddresses = ["127.0.0.1"]
        configuration.timeout = 5

        let report = await ProxyProbe.run(endpoint: endpoint, configuration: configuration, log: nil)
        XCTAssertFalse(report.isSuccess)
        XCTAssertNotNil(report.failure)
        XCTAssertNil(report.httpStatus)
        XCTAssertNil(report.egressIP, "a failed probe must not invent an egress address")
    }

    func testProbeRejectsAnInvalidHostWithoutTouchingTheNetwork() async {
        let endpoint = ProxyEndpoint(host: "not a host", port: 1080, protocolType: .socks5)
        let report = await ProxyProbe.run(endpoint: endpoint, configuration: .default, log: nil)
        XCTAssertEqual(report.failure?.kind, .invalidHost)
    }

    // MARK: Host resolution

    func testResolverReturnsTheLiteralUnchanged() throws {
        XCTAssertEqual(try HostResolver.resolve(host: "203.0.113.7", port: 1080), ["203.0.113.7"])
        XCTAssertEqual(try HostResolver.resolve(host: "2001:db8::1", port: 1080), ["2001:db8::1"])
    }

    func testResolverResolvesLocalhost() throws {
        let addresses = try HostResolver.resolve(host: "localhost", port: 80)
        XCTAssertFalse(addresses.isEmpty)
        XCTAssertTrue(addresses.contains { $0 == "127.0.0.1" || $0 == "::1" })
        // IPv4 must come first: many proxy endpoints are IPv4-only.
        XCTAssertEqual(addresses.first, "127.0.0.1")
    }

    func testResolverFailsCleanlyForAnInvalidName() {
        XCTAssertThrowsError(try HostResolver.resolve(host: "this-name-does-not-exist.invalid", port: 80))
    }

    // MARK: Helpers

    private func connectExpectingFailure(
        endpoint: ProxyEndpoint,
        targets: [TransportTarget]? = nil,
        timeout: TimeInterval = 10
    ) -> ProxyError {
        let settled = expectation(description: "settled")
        var outcome: Result<ProxyConnection, ProxyError>?
        ProxyConnector.connect(
            endpoint: endpoint,
            destination: .connect(host: "127.0.0.1", port: echoPort),
            targets: targets ?? self.targets(for: endpoint),
            queue: queue,
            connectTimeout: timeout,
            handshakeTimeout: timeout,
            log: nil
        ) { result in
            outcome = result
            settled.fulfill()
        }
        wait(for: [settled], timeout: timeout + 8)

        switch outcome {
        case .failure(let error):
            return error
        case .success(let connection):
            connection.close()
            XCTFail("expected a failure, got a working connection")
            return .cancelled
        case .none:
            XCTFail("the connector never completed")
            return .cancelled
        }
    }
}
