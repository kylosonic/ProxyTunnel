//
//  HostResolver.swift
//  ProxyTunnelCore
//
//  Thin wrapper over `getaddrinfo` / `getnameinfo`.
//
//  Two callers need this:
//    * the app, *before* the tunnel starts, so it can hand the extension the
//      proxy's IP addresses and the extension never has to resolve anything
//      inside the tunnel (which would be a chicken-and-egg problem);
//    * the connectivity probe.
//

import Foundation

#if canImport(Darwin)
import Darwin
#endif

public enum HostResolverError: Error, Equatable, CustomStringConvertible {
    case resolutionFailed(host: String, code: Int32, message: String)
    case noAddresses(host: String)

    public var description: String {
        switch self {
        case .resolutionFailed(let host, let code, let message):
            return "Could not resolve \(host): getaddrinfo failed with \(code) (\(message))."
        case .noAddresses(let host):
            return "Could not resolve \(host): no addresses returned."
        }
    }
}

public enum HostResolver {

    /// Resolves `host` to numeric address strings.
    ///
    /// Ordering: IPv4 addresses are returned before IPv6 ones. Many commercial
    /// proxy endpoints are IPv4-only, and on an IPv6-capable mobile network a
    /// system-ordered list frequently puts AAAA first, which then fails at the
    /// TCP layer instead of falling back. Sorting is a pragmatic mitigation; the
    /// connector still tries every candidate in order.
    ///
    /// - Note: blocking. Call it off the main thread.
    public static func resolve(host: String, port: Int) throws -> [String] {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HostResolverError.resolutionFailed(host: host, code: EAI_NONAME, message: "empty host")
        }

        // Already an IP literal? No lookup needed. This is also the path used
        // inside the tunnel, where performing DNS would be circular.
        if let literal = IPAddress(presentationName: trimmed) {
            return [literal.description]
        }

        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(trimmed, String(port), &hints, &result)
        guard status == 0, let first = result else {
            let message = String(cString: gai_strerror(status))
            throw HostResolverError.resolutionFailed(host: trimmed, code: status, message: message)
        }
        defer { freeaddrinfo(result) }

        var ipv4: [String] = []
        var ipv6: [String] = []
        var seen = Set<String>()

        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let nameStatus = getnameinfo(
                info.pointee.ai_addr,
                info.pointee.ai_addrlen,
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if nameStatus == 0 {
                let text = String(cString: hostBuffer)
                if !text.isEmpty, seen.insert(text).inserted {
                    if info.pointee.ai_family == AF_INET {
                        ipv4.append(text)
                    } else if info.pointee.ai_family == AF_INET6 {
                        ipv6.append(text)
                    }
                }
            }
            cursor = info.pointee.ai_next
        }

        let all = ipv4 + ipv6
        guard !all.isEmpty else { throw HostResolverError.noAddresses(host: trimmed) }
        return all
    }

    /// Async wrapper so callers can `await` without blocking a thread pool.
    public static func resolveAsync(host: String, port: Int) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try resolve(host: host, port: port))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
