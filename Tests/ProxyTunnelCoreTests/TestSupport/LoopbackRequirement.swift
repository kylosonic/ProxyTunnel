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
}
