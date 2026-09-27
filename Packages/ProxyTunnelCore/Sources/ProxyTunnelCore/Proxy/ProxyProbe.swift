//
//  ProxyProbe.swift
//  ProxyTunnelCore
//
//  The app's "Test connection" feature.
//
//  This performs a *real* end-to-end check:
//
//    1. resolve the proxy host
//    2. open a TCP (optionally TLS) connection to the proxy
//    3. complete the protocol handshake, asking the proxy to CONNECT to a
//       well-known plain-HTTP endpoint
//    4. send one HTTP/1.1 GET through that tunnel and read the body
//    5. report the egress IP address the far end saw
//
//  Step 5 is the proof: the body is served by the origin server, so if it comes
//  back through the proxy the proxy really did relay a TCP stream. This works
//  even when the Network Extension itself cannot run, which is why it is the
//  primary way to validate a proxy profile under a free-Apple-ID install.
//
//  No part of this fakes success. If any step fails the report carries the real
//  failure.
//

import Foundation
import Network

public struct ProxyProbeConfiguration: Sendable {

    /// Plain-HTTP host used for the end-to-end check.
    ///
    /// It must be HTTP (not HTTPS): the probe deliberately does not implement
    /// TLS-through-tunnel, so that the tunnel step is exercised with the smallest
    /// possible amount of extra machinery. The response body of this host is the
    /// caller's public IP address.
    public var checkHost: String
    public var checkPort: UInt16
    public var checkPath: String

    /// Give up after this long in total.
    public var timeout: TimeInterval

    /// Skip DNS and use these addresses (the tunnel already resolved them).
    public var resolvedAddresses: [String]?

    /// Maximum bytes of HTTP body to buffer.
    public var maximumBodyBytes: Int

    public init(
        checkHost: String = "api.ipify.org",
        checkPort: UInt16 = 80,
        checkPath: String = "/",
        timeout: TimeInterval = 25,
        resolvedAddresses: [String]? = nil,
        maximumBodyBytes: Int = 16 * 1024
    ) {
        self.checkHost = checkHost
        self.checkPort = checkPort
        self.checkPath = checkPath
        self.timeout = timeout
        self.resolvedAddresses = resolvedAddresses
        self.maximumBodyBytes = maximumBodyBytes
    }

    public static let `default` = ProxyProbeConfiguration()
}

/// A full, honest account of what happened during a probe.
public struct ProxyProbeReport: Sendable {

    public let startedAt: Date
    public let finishedAt: Date

    /// Addresses the proxy host resolved to. Empty when resolution failed.
    public let resolvedAddresses: [String]
    /// The address that was actually dialled.
    public let dialedAddress: String?
    /// How long the TCP (and TLS) dial took.
    public let tcpConnectDuration: TimeInterval?
    /// How long the proxy handshake took.
    public let handshakeDuration: TimeInterval?
    /// What the proxy answered, e.g. "SOCKS5 CONNECT succeeded".
    public let handshakeSummary: String?
    /// HTTP status returned by the origin server through the proxy.
    public let httpStatus: Int?
    /// The public IP the origin server saw. This is the proxy's egress address.
    public let egressIP: String?
    /// Non-nil when something went wrong. Nothing is reported as successful then.
    public let failure: TunnelFailure?

    public var isSuccess: Bool { failure == nil && httpStatus != nil }
    public var totalDuration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }

    /// Lines shown in the UI, in order, each a plain statement of fact.
    public var summaryLines: [String] {
        var lines: [String] = []
        if resolvedAddresses.isEmpty {
            lines.append("Proxy host: not resolved")
        } else {
            lines.append("Proxy host resolved to \(resolvedAddresses.joined(separator: ", "))")
        }
        if let dialedAddress {
            let ms = tcpConnectDuration.map { String(format: "%.0f ms", $0 * 1000) } ?? "?"
            lines.append("TCP connect to \(dialedAddress): OK (\(ms))")
        }
        if let handshakeSummary {
            let ms = handshakeDuration.map { String(format: "%.0f ms", $0 * 1000) } ?? "?"
            lines.append("Proxy handshake: \(handshakeSummary) (\(ms))")
        }
        if let httpStatus {
            lines.append("HTTP request through the proxy: status \(httpStatus)")
        }
        if let egressIP {
            lines.append("Traffic exited via \(egressIP)")
        }
        if let failure {
            lines.append("FAILED — \(failure.title): \(failure.message)")
        }
        return lines
    }
}

public enum ProxyProbe {

    /// Runs the probe. Always returns a report; failures are described inside it.
    public static func run(
        endpoint: ProxyEndpoint,
        configuration: ProxyProbeConfiguration = .default,
        requiredInterface: NWInterface? = nil,
        log: DiagnosticLog? = nil
    ) async -> ProxyProbeReport {

        let startedAt = Date()
        let queue = DispatchQueue(label: "io.github.kylosonic.proxytunnel.probe", qos: .userInitiated)

        // ---- 0. Local validation, before touching the network ---------------
        let hostValidation = HostValidator.validate(endpoint.host)
        if let error = hostValidation.issues.first(where: { $0.severity == .error }) {
            return failureReport(
                startedAt: startedAt,
                failure: TunnelFailure(
                    kind: .invalidHost,
                    title: "Invalid proxy host",
                    message: error.message,
                    recoverySuggestion: "Edit the proxy and correct the host field."
                )
            )
        }
        if !PortValidator.range.contains(endpoint.port) {
            return failureReport(
                startedAt: startedAt,
                failure: TunnelFailure(
                    kind: .invalidPort,
                    title: "Invalid port",
                    message: "Port \(endpoint.port) is outside 1-65535.",
                    recoverySuggestion: "Edit the proxy and correct the port."
                )
            )
        }
        if endpoint.credential == nil {
            // Not fatal for SOCKS5 (the server may need no auth) but worth saying.
            log?.debug("probe", "no credentials configured; offering \"no authentication\" only")
        }

        // ---- 1. Resolve ----------------------------------------------------
        var resolved: [String] = []
        if let preResolved = configuration.resolvedAddresses, !preResolved.isEmpty {
            resolved = preResolved
        } else {
            do {
                resolved = try await HostResolver.resolveAsync(host: endpoint.host, port: endpoint.port)
            } catch {
                return failureReport(
                    startedAt: startedAt,
                    failure: TunnelFailure(
                        kind: .proxyUnreachable,
                        title: "Proxy host not found",
                        message: "Could not resolve \"\(endpoint.host)\".",
                        recoverySuggestion: "Check the host name and your internet connection.",
                        underlyingDescription: "\(error)",
                        isRetryable: true
                    )
                )
            }
        }
        log?.info("probe", "resolved \(endpoint.host) -> \(resolved.joined(separator: ", "))")

        // ---- 2 & 3. Dial + handshake to the check host ---------------------
        let targets = ProxyConnector.targets(for: endpoint, resolvedAddresses: resolved)
        let destination = ProxyDestination.connect(host: configuration.checkHost, port: configuration.checkPort)

        let connection: ProxyConnection
        do {
            connection = try await connectAsync(
                endpoint: endpoint,
                destination: destination,
                targets: targets,
                queue: queue,
                timeout: configuration.timeout,
                requiredInterface: requiredInterface,
                log: log
            )
        } catch let error as ProxyError {
            return failureReport(
                startedAt: startedAt,
                resolvedAddresses: resolved,
                failure: TunnelFailure.from(proxyError: error, endpoint: endpoint)
            )
        } catch {
            return failureReport(
                startedAt: startedAt,
                resolvedAddresses: resolved,
                failure: TunnelFailure(
                    kind: .internalError,
                    title: "Probe failed",
                    message: "\(error)",
                    isRetryable: true
                )
            )
        }
        defer { connection.close() }

        // ---- 4. One real HTTP request through the tunnel -------------------
        let request = SimpleHTTP.getRequest(host: configuration.checkHost, path: configuration.checkPath)
        do {
            try await writeAsync(connection.stream, request)
        } catch {
            return failureReport(
                startedAt: startedAt,
                resolvedAddresses: resolved,
                dialedAddress: connection.dialedTarget.host,
                handshakeSummary: connection.outcome.responseSummary,
                failure: TunnelFailure(
                    kind: .proxyUnreachable,
                    title: "Proxy closed the tunnel",
                    message: "The proxy accepted CONNECT but the tunnel stopped before the test request could be sent.",
                    isRetryable: true
                )
            )
        }

        // Read until the server closes (the request asks for `Connection: close`),
        // we hit the byte cap, the deadline passes, or a read fails. Partial data
        // is still parsed below, because a small text body is usually complete
        // long before the FIN arrives.
        var responseData = Data()
        let deadline = Date().addingTimeInterval(configuration.timeout)
        readLoop: while Date() < deadline {
            do {
                let chunk = try await readAsync(connection.stream)
                if chunk.isEmpty { break readLoop }                       // clean EOF
                responseData.append(chunk)
                if responseData.count >= configuration.maximumBodyBytes { break readLoop }
                if let parsed = SimpleHTTP.parse(responseData), !parsed.body.isEmpty { break readLoop }
            } catch {
                break readLoop                                            // parse whatever we have
            }
        }

        guard let httpResponse = SimpleHTTP.parse(responseData) else {
            return failureReport(
                startedAt: startedAt,
                resolvedAddresses: resolved,
                dialedAddress: connection.dialedTarget.host,
                handshakeSummary: connection.outcome.responseSummary,
                tcpConnectDuration: connection.tcpConnectDuration,
                handshakeDuration: connection.handshakeDuration,
                failure: TunnelFailure(
                    kind: .proxyUnreachable,
                    title: "Unreadable response",
                    message: "The proxy relayed data, but it was not a valid HTTP response (\(responseData.count) bytes received).",
                    recoverySuggestion: "Some proxies inject their own error pages or block port 80. The tunnel itself still works if the handshake above succeeded.",
                    isRetryable: true
                )
            )
        }

        let egress = extractIP(from: httpResponse.bodyText)
        let finishedAt = Date()
        log?.info("probe", "probe succeeded: HTTP \(httpResponse.statusCode), egress \(egress ?? "unknown")")

        return ProxyProbeReport(
            startedAt: startedAt,
            finishedAt: finishedAt,
            resolvedAddresses: resolved,
            dialedAddress: connection.dialedTarget.host,
            tcpConnectDuration: connection.tcpConnectDuration,
            handshakeDuration: connection.handshakeDuration,
            handshakeSummary: connection.outcome.responseSummary,
            httpStatus: httpResponse.statusCode,
            egressIP: egress,
            failure: nil
        )
    }

    // MARK: Helpers

    /// Extracts a plausible IP address from a tiny text body. Returns the trimmed
    /// body (capped) if nothing IP-shaped is found, so the UI can still show what
    /// came back.
    static func extractIP(from body: String) -> String? {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let candidate = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? text
        if IPAddress(presentationName: candidate) != nil {
            return candidate
        }
        return String(text.prefix(80))
    }

    private static func failureReport(
        startedAt: Date,
        resolvedAddresses: [String] = [],
        dialedAddress: String? = nil,
        handshakeSummary: String? = nil,
        tcpConnectDuration: TimeInterval? = nil,
        handshakeDuration: TimeInterval? = nil,
        failure: TunnelFailure
    ) -> ProxyProbeReport {
        ProxyProbeReport(
            startedAt: startedAt,
            finishedAt: Date(),
            resolvedAddresses: resolvedAddresses,
            dialedAddress: dialedAddress,
            tcpConnectDuration: tcpConnectDuration,
            handshakeDuration: handshakeDuration,
            handshakeSummary: handshakeSummary,
            httpStatus: nil,
            egressIP: nil,
            failure: failure
        )
    }

    private static func connectAsync(
        endpoint: ProxyEndpoint,
        destination: ProxyDestination,
        targets: [TransportTarget],
        queue: DispatchQueue,
        timeout: TimeInterval,
        requiredInterface: NWInterface?,
        log: DiagnosticLog?
    ) async throws -> ProxyConnection {
        try await withCheckedThrowingContinuation { continuation in
            ProxyConnector.connect(
                endpoint: endpoint,
                destination: destination,
                targets: targets,
                queue: queue,
                connectTimeout: timeout,
                handshakeTimeout: timeout,
                requiredInterface: requiredInterface,
                log: log
            ) { result in
                continuation.resume(with: result)
            }
        }
    }

    private static func writeAsync(_ stream: DuplexByteStream, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.write(data) { result in
                continuation.resume(with: result)
            }
        }
    }

    private static func readAsync(_ stream: DuplexByteStream) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            stream.read { result in
                continuation.resume(with: result)
            }
        }
    }
}
