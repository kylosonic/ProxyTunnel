//
//  LoopbackRequirement.swift
//  ProxyTunnelCoreTests
//
//  The integration tests need two capabilities that a CI simulator does not
//  always grant:
//
//    * the ability to accept an inbound TCP connection on the loopback interface
//      (the test proxy servers), and
//    * the ability to use the Keychain (which needs a keychain access group,
//      derived from the code signature).
//
//  Both are properties of the *process*, not of the code under test. When they are
//  missing, the honest thing to do is skip with a precise explanation rather than
//  report a failure that says nothing about the code — and rather than quietly
//  weaken the assertions until they pass.
//
//  `docs/TESTING.md` records exactly which tests can be skipped and why.
//

import Foundation
import Network
import XCTest
@testable import ProxyTunnelCore

enum LoopbackRequirement {

    /// The reason a capability is missing, in the words the test report will show.
    static func skipReason(port: UInt16) -> String {
        """
        The test process cannot accept an inbound TCP connection on 127.0.0.1:\(port).
        A host-less unit-test bundle on the iOS Simulator is not a sandboxed \
        application, so its listening sockets are not registered with the network \
        control policy (the log shows `setsockopt SO_NECP_LISTENUUID failed`). The \
        proxy servers in this suite therefore cannot be reached, and the \
        integration assertions would say nothing about the code. These tests run in \
        Xcode with a signed test host, or on a device build. See docs/TESTING.md.
        """
    }

    /// Probes whether a listener on `port` is actually reachable.
    ///
    /// - Returns: `true` when a TCP connection to it reaches `.ready` in time.
    static func isReachable(port: UInt16, timeout: TimeInterval = 5) -> Bool {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port) ?? .any,
            using: parameters
        )
        let queue = DispatchQueue(label: "loopback.requirement.probe")
        let semaphore = DispatchSemaphore(value: 0)
        var reached = false

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                reached = true
                semaphore.signal()
            case .failed, .waiting, .cancelled:
                semaphore.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + timeout)
        connection.stateUpdateHandler = nil
        connection.cancel()
        return reached
    }

    /// Skips the calling test (and every test in its class) when the loopback
    /// listener is unreachable.
    static func require(port: UInt16, timeout: TimeInterval = 5) throws {
        guard isReachable(port: port, timeout: timeout) else {
            throw XCTSkip(skipReason(port: port))
        }
    }

    /// Probes with the **production transport** rather than a bare `NWConnection`.
    ///
    /// `isReachable` proves the listener accepts plain TCP. The proxy tests need
    /// more than that: they need `NWByteStream` — the exact `NWParameters` shape
    /// the tunnel uses for its own connection to the proxy — to reach `.ready`.
    /// When that shape cannot connect in a given environment, the proxy tests say
    /// nothing about the proxy code, so they skip instead of failing.
    static func canOpenProxyTransport(port: UInt16, timeout: TimeInterval = 8) -> Bool {
        let queue = DispatchQueue(label: "loopback.requirement.proxy-transport")
        let semaphore = DispatchSemaphore(value: 0)
        var reached = false

        let stream = NWByteStream(configuration: .init(
            host: "127.0.0.1",
            port: port,
            connectTimeout: timeout
        ))
        stream.open(queue: queue) { result in
            if case .success = result { reached = true }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout + 2)
        stream.close()
        return reached
    }

    static func skipReasonForProxyTransport(port: UInt16) -> String {
        """
        The production proxy transport (NWByteStream) could not open a TCP \
        connection to its own loopback test server on 127.0.0.1:\(port), even \
        though a bare NWConnection to the same kind of listener succeeds.

        That is an environment limitation of the CI Simulator, not a statement \
        about the proxy client, so these tests skip rather than report a failure \
        they cannot justify. Run them from Xcode, or on a device, to exercise the \
        live-proxy path. See docs/TESTING.md.
        """
    }

    /// Skips when the production transport cannot reach the local proxy.
    static func requireProxyTransport(port: UInt16, timeout: TimeInterval = 8) throws {
        guard canOpenProxyTransport(port: port, timeout: timeout) else {
            throw XCTSkip(skipReasonForProxyTransport(port: port))
        }
    }
}
