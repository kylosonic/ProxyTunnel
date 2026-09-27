//
//  IPAddress.swift
//  ProxyTunnelCore
//
//  A tiny, dependency-free IPv4/IPv6 address value type built on inet_pton /
//  inet_ntop. The TCP/IP stack needs the raw bytes for checksum pseudo-headers,
//  and the UI needs a canonical text form, so both live here.
//

import Foundation

#if canImport(Darwin)
import Darwin
#endif

public struct IPAddress: Hashable, Sendable, CustomStringConvertible {

    /// 4 bytes for IPv4, 16 bytes for IPv6.
    public let bytes: [UInt8]

    public var isIPv6: Bool { bytes.count == 16 }
    public var isIPv4: Bool { bytes.count == 4 }

    public init?(bytes: [UInt8]) {
        guard bytes.count == 4 || bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    public init?(presentationName raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip an IPv6 zone identifier ("fe80::1%en0"): irrelevant for a proxy
        // endpoint and not understood by inet_pton.
        if let percent = text.firstIndex(of: "%") {
            text = String(text[text.startIndex..<percent])
        }
        // Accept bracketed literals such as "[2001:db8::1]".
        if text.hasPrefix("[") && text.hasSuffix("]") && text.count > 2 {
            text = String(text.dropFirst().dropLast())
        }
        guard !text.isEmpty else { return nil }

        if text.contains(":") {
            guard let parsed = IPAddress.parseIPv6(text) else { return nil }
            self = parsed
        } else {
            guard let parsed = IPAddress.parseIPv4(text) else { return nil }
            self = parsed
        }
    }

    public static func parseIPv4(_ text: String) -> IPAddress? {
        var addr = in_addr()
        guard text.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }
        // inet_pton writes network byte order straight into the struct, so the
        // raw memory layout *is* the 4-byte address.
        let raw = withUnsafeBytes(of: addr) { Array($0) }
        return IPAddress(bytes: raw)
    }

    public static func parseIPv6(_ text: String) -> IPAddress? {
        var addr = in6_addr()
        guard text.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }
        // Same trick, but 16 bytes. Using the raw layout avoids depending on the
        // names of the members of the __u6_addr union, which differ between SDKs.
        let raw = withUnsafeBytes(of: addr) { Array($0) }
        return IPAddress(bytes: raw)
    }

    /// Canonical textual form (RFC 5952 style, as produced by inet_ntop).
    public var description: String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN) + 1)
        let family = isIPv6 ? AF_INET6 : AF_INET
        let result: UnsafePointer<CChar>? = bytes.withUnsafeBufferPointer { bp in
            bp.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bp.count) { ptr in
                inet_ntop(family, ptr, &buffer, socklen_t(buffer.count))
            }
        }
        guard result != nil else { return "<invalid>" }
        return String(cString: buffer)
    }

    /// `host:port` with IPv6 bracketed, e.g. `[2001:db8::1]:1080`.
    public func authority(port: UInt16) -> String {
        isIPv6 ? "[\(description)]:\(port)" : "\(description):\(port)"
    }

    // MARK: Classification helpers

    public var isUnspecified: Bool {
        bytes.allSatisfy { $0 == 0 }
    }

    public var isLoopback: Bool {
        if isIPv4 { return bytes[0] == 127 }
        return bytes.dropLast().allSatisfy { $0 == 0 } && bytes[15] == 1
    }

    public var isMulticast: Bool {
        if isIPv4 { return (bytes[0] & 0xF0) == 0xE0 }
        return bytes[0] == 0xFF
    }

    public var isLinkLocal: Bool {
        if isIPv4 { return bytes[0] == 169 && bytes[1] == 254 }
        return bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80
    }

    /// IPv4-mapped IPv6 address (`::ffff:a.b.c.d`).
    public var ipv4Mapped: IPAddress? {
        guard isIPv6 else { return nil }
        let prefix = Array(bytes[0..<10])
        guard prefix.allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF else { return nil }
        return IPAddress(bytes: Array(bytes[12..<16]))
    }
}

// MARK: - CIDR

/// A minimal CIDR block. Only used to build `NEIPv4Route` / `NEIPv6Route`
/// values for the tunnel's included and excluded routes.
public struct IPNetwork: Hashable, Sendable {

    public let address: IPAddress
    public let prefixLength: Int

    public init?(address: IPAddress, prefixLength: Int) {
        let maxPrefix = address.isIPv4 ? 32 : 128
        guard prefixLength >= 0, prefixLength <= maxPrefix else { return nil }
        self.address = address
        self.prefixLength = prefixLength
    }

    /// Parses "0.0.0.0/0", "10.7.0.0/24", "2001:db8::/32" or a bare address
    /// (treated as a host route).
    public init?(cidr: String) {
        let parts = cidr.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let address = IPAddress(presentationName: String(parts[0])) else { return nil }
        let prefix: Int
        if parts.count == 2 {
            guard let parsed = Int(parts[1]) else { return nil }
            prefix = parsed
        } else {
            prefix = address.isIPv4 ? 32 : 128
        }
        self.init(address: address, prefixLength: prefix)
    }

    public var cidr: String { "\(address.description)/\(prefixLength)" }

    public static let ipv4Default = IPNetwork(address: IPAddress(bytes: [0, 0, 0, 0])!, prefixLength: 0)!
    public static let ipv6Default = IPNetwork(
        address: IPAddress(bytes: [UInt8](repeating: 0, count: 16))!,
        prefixLength: 0
    )!

    /// A host route, i.e. /32 or /128. Used to punch the proxy's own address out
    /// of the tunnel so the tunnel's transport does not loop back inside itself.
    public static func hostRoute(_ address: IPAddress) -> IPNetwork {
        IPNetwork(address: address, prefixLength: address.isIPv4 ? 32 : 128)!
    }
}

extension IPNetwork: CustomStringConvertible {
    public var description: String { cidr }
}
