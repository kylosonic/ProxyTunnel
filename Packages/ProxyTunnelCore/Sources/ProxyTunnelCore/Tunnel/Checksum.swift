//
//  Checksum.swift
//  ProxyTunnelCore
//
//  The Internet checksum (RFC 1071) plus the IPv4/IPv6 transport pseudo-headers.
//
//  Every byte of a TCP segment we synthesise has to be checksummed, so this is on
//  the hot path. The implementation is the textbook "sum 16-bit words, fold the
//  carries, complement" one; it is exercised against fixed vectors in the tests.
//

import Foundation

public enum InternetChecksum {

    /// Sums `bytes` as a sequence of big-endian 16-bit words, with a trailing odd
    /// byte padded with zero. The result still has carries in the high half.
    @inline(__always)
    public static func sum(_ bytes: [UInt8]) -> UInt32 {
        var total: UInt32 = 0
        var index = 0
        let count = bytes.count
        while index + 1 < count {
            total &+= (UInt32(bytes[index]) << 8) | UInt32(bytes[index + 1])
            index += 2
        }
        if index < count {
            total &+= UInt32(bytes[index]) << 8
        }
        return total
    }

    @inline(__always)
    public static func sum(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var total: UInt32 = 0
        var index = 0
        let count = bytes.count
        while index + 1 < count {
            total &+= (UInt32(bytes[index]) << 8) | UInt32(bytes[index + 1])
            index += 2
        }
        if index < count {
            total &+= UInt32(bytes[index]) << 8
        }
        return total
    }

    /// Folds the carry bits down into 16 bits.
    @inline(__always)
    public static func fold(_ value: UInt32) -> UInt16 {
        var folded = value
        while (folded >> 16) != 0 {
            folded = (folded & 0xFFFF) &+ (folded >> 16)
        }
        return UInt16(folded & 0xFFFF)
    }

    /// The one's-complement checksum of `bytes`.
    @inline(__always)
    public static func checksum(_ bytes: [UInt8]) -> UInt16 {
        ~fold(sum(bytes)) & 0xFFFF
    }

    /// Checksum over a pseudo-header plus the transport segment.
    ///
    /// IPv4 pseudo-header (RFC 793 §3.1):
    /// ```
    /// +--------+--------+--------+--------+
    /// |           Source Address          |
    /// +--------+--------+--------+--------+
    /// |         Destination Address       |
    /// +--------+--------+--------+--------+
    /// |  zero  |  PTCL  |    TCP Length   |
    /// +--------+--------+--------+--------+
    /// ```
    /// IPv6 pseudo-header (RFC 8200 §8.1):
    /// ```
    /// +--------+--------+--------+--------+
    /// |           Source Address          |  16 bytes
    /// |         Destination Address       |  16 bytes
    /// |      Upper-Layer Packet Length    |   4 bytes
    /// |             zero (3)  NextHdr (1)|   4 bytes
    /// +--------+--------+--------+--------+
    /// ```
    public static func transportChecksum(
        source: IPAddress,
        destination: IPAddress,
        protocolNumber: UInt8,
        segment: [UInt8]
    ) -> UInt16 {
        var material = [UInt8]()
        material.reserveCapacity(40 + segment.count)
        material.append(contentsOf: source.bytes)
        material.append(contentsOf: destination.bytes)

        if source.isIPv4 {
            material.append(0)
            material.append(protocolNumber)
            material.append(UInt8((segment.count >> 8) & 0xFF))
            material.append(UInt8(segment.count & 0xFF))
        } else {
            let length = UInt32(segment.count)
            material.append(UInt8((length >> 24) & 0xFF))
            material.append(UInt8((length >> 16) & 0xFF))
            material.append(UInt8((length >> 8) & 0xFF))
            material.append(UInt8(length & 0xFF))
            material.append(0)
            material.append(0)
            material.append(0)
            material.append(protocolNumber)
        }

        material.append(contentsOf: segment)
        return checksum(material)
    }

    /// Incremental variant that avoids copying the segment: sums the
    /// pseudo-header and the segment separately, then folds once.
    @inline(__always)
    public static func transportChecksum(
        source: IPAddress,
        destination: IPAddress,
        protocolNumber: UInt8,
        segment: UnsafeRawBufferPointer
    ) -> UInt16 {
        var material = [UInt8]()
        material.append(contentsOf: source.bytes)
        material.append(contentsOf: destination.bytes)
        if source.isIPv4 {
            material.append(0)
            material.append(protocolNumber)
            material.append(UInt8((segment.count >> 8) & 0xFF))
            material.append(UInt8(segment.count & 0xFF))
        } else {
            let length = UInt32(segment.count)
            material.append(UInt8((length >> 24) & 0xFF))
            material.append(UInt8((length >> 16) & 0xFF))
            material.append(UInt8((length >> 8) & 0xFF))
            material.append(UInt8(length & 0xFF))
            material.append(0); material.append(0); material.append(0)
            material.append(protocolNumber)
        }
        let total = sum(material) &+ sum(segment)
        return ~fold(total) & 0xFFFF
    }
}

// MARK: - Sequence number arithmetic

/// TCP sequence numbers wrap around at 2^32, so comparisons must be modular
/// (RFC 793 §3.3). These helpers implement the "serial number arithmetic" from
/// RFC 1982 in the form the stack uses.
public enum SequenceNumber {

    /// `true` when `a` is strictly before `b` in sequence space.
    @inline(__always)
    public static func less(_ a: UInt32, _ b: UInt32) -> Bool {
        Int32(bitPattern: a &- b) < 0
    }

    /// `true` when `a` is at or before `b`.
    @inline(__always)
    public static func lessOrEqual(_ a: UInt32, _ b: UInt32) -> Bool {
        Int32(bitPattern: a &- b) <= 0
    }

    /// `true` when `a` is strictly after `b`.
    @inline(__always)
    public static func greater(_ a: UInt32, _ b: UInt32) -> Bool {
        Int32(bitPattern: a &- b) > 0
    }

    /// Distance from `from` to `to`, assuming `to` is ahead of `from`.
    @inline(__always)
    public static func distance(from: UInt32, to: UInt32) -> Int {
        Int(Int32(bitPattern: to &- from))
    }
}
