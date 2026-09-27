//
//  ByteBuffer.swift
//  ProxyTunnelCore
//
//  Minimal big-endian reader/writer used by every protocol codec and by the
//  TCP/IP packet parser. Having one implementation means there is exactly one
//  place where bounds checking happens.
//

import Foundation

public enum ByteBufferError: Error, Equatable, CustomStringConvertible {
    case outOfBounds(needed: Int, available: Int)
    case notEnoughBytes

    public var description: String {
        switch self {
        case .outOfBounds(let needed, let available):
            return "Not enough bytes: needed \(needed), have \(available)."
        case .notEnoughBytes:
            return "Not enough bytes."
        }
    }
}

/// A forward-only cursor over a byte array.
public struct ByteReader {

    private let bytes: [UInt8]
    private var index: Int

    public init(_ data: Data) {
        self.bytes = [UInt8](data)
        self.index = 0
    }

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.index = 0
    }

    public var offset: Int { index }
    public var count: Int { bytes.count }
    public var remaining: Int { bytes.count - index }
    public var isAtEnd: Bool { index >= bytes.count }

    public func peekByte(at offsetFromCurrent: Int = 0) -> UInt8? {
        let i = index + offsetFromCurrent
        guard i >= 0 && i < bytes.count else { return nil }
        return bytes[i]
    }

    public mutating func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else { throw ByteBufferError.outOfBounds(needed: 1, available: remaining) }
        defer { index += 1 }
        return bytes[index]
    }

    public mutating func readUInt16() throws -> UInt16 {
        guard remaining >= 2 else { throw ByteBufferError.outOfBounds(needed: 2, available: remaining) }
        defer { index += 2 }
        return UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
    }

    public mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else { throw ByteBufferError.outOfBounds(needed: 4, available: remaining) }
        defer { index += 4 }
        return UInt32(bytes[index]) << 24
            | UInt32(bytes[index + 1]) << 16
            | UInt32(bytes[index + 2]) << 8
            | UInt32(bytes[index + 3])
    }

    public mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0 else { throw ByteBufferError.outOfBounds(needed: count, available: remaining) }
        guard remaining >= count else { throw ByteBufferError.outOfBounds(needed: count, available: remaining) }
        defer { index += count }
        return Array(bytes[index..<(index + count)])
    }

    public mutating func readData(_ count: Int) throws -> Data {
        Data(try readBytes(count))
    }

    public mutating func readRest() -> [UInt8] {
        defer { index = bytes.count }
        return Array(bytes[index...])
    }

    public mutating func skip(_ count: Int) throws {
        guard remaining >= count else { throw ByteBufferError.outOfBounds(needed: count, available: remaining) }
        index += count
    }
}

// MARK: - Writing

extension Data {

    /// Appends a 16-bit value in network byte order.
    public mutating func appendUInt16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    /// Appends a 32-bit value in network byte order.
    public mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    /// Appends the bytes of an IP literal, or throws if `text` is not one.
    public mutating func appendAddressLiteral(_ text: String) throws -> Bool {
        guard let address = IPAddress(presentationName: text) else { return false }
        append(contentsOf: address.bytes)
        return true
    }

    /// A hex dump suitable for logs. Never used on payload bytes that could
    /// contain credentials.
    public func hexDump(limit: Int = 64) -> String {
        let slice = prefix(limit)
        let hex = slice.map { String(format: "%02x", $0) }.joined(separator: " ")
        return count > limit ? hex + " … (\(count) bytes)" : hex + " (\(count) bytes)"
    }
}
