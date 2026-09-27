//
//  TCPSegment.swift
//  ProxyTunnelCore
//
//  TCP header parse / build (RFC 9293).
//

import Foundation

public struct TCPFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let fin = TCPFlags(rawValue: 0x01)
    public static let syn = TCPFlags(rawValue: 0x02)
    public static let rst = TCPFlags(rawValue: 0x04)
    public static let psh = TCPFlags(rawValue: 0x08)
    public static let ack = TCPFlags(rawValue: 0x10)
    public static let urg = TCPFlags(rawValue: 0x20)
    public static let ece = TCPFlags(rawValue: 0x40)
    public static let cwr = TCPFlags(rawValue: 0x80)

    /// "SYN,ACK" style description for logs.
    public var names: String {
        var parts: [String] = []
        if contains(.syn) { parts.append("SYN") }
        if contains(.ack) { parts.append("ACK") }
        if contains(.fin) { parts.append("FIN") }
        if contains(.rst) { parts.append("RST") }
        if contains(.psh) { parts.append("PSH") }
        if contains(.urg) { parts.append("URG") }
        if contains(.ece) { parts.append("ECE") }
        if contains(.cwr) { parts.append("CWR") }
        return parts.isEmpty ? "none" : parts.joined(separator: ",")
    }
}

public enum TCPSegmentError: Error, Equatable, CustomStringConvertible {
    case truncated(needed: Int, available: Int)
    case badDataOffset(Int)
    case badOption(String)

    public var description: String {
        switch self {
        case .truncated(let needed, let available): return "truncated: needed \(needed), have \(available)"
        case .badDataOffset(let offset):           return "bad data offset \(offset)"
        case .badOption(let detail):               return "bad TCP option: \(detail)"
        }
    }
}

public struct TCPSegment: Equatable, Sendable {

    public var sourcePort: UInt16
    public var destinationPort: UInt16
    public var sequenceNumber: UInt32
    public var acknowledgmentNumber: UInt32
    public var flags: TCPFlags
    public var windowSize: UInt16
    public var urgentPointer: UInt16
    /// Raw option bytes, excluding padding.
    public var options: [UInt8]
    public var payload: Data

    public init(
        sourcePort: UInt16,
        destinationPort: UInt16,
        sequenceNumber: UInt32,
        acknowledgmentNumber: UInt32,
        flags: TCPFlags,
        windowSize: UInt16,
        urgentPointer: UInt16 = 0,
        options: [UInt8] = [],
        payload: Data = Data()
    ) {
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.sequenceNumber = sequenceNumber
        self.acknowledgmentNumber = acknowledgmentNumber
        self.flags = flags
        self.windowSize = windowSize
        self.urgentPointer = urgentPointer
        self.options = options
        self.payload = payload
    }

    // MARK: Flag conveniences

    public var hasSYN: Bool { flags.contains(.syn) }
    public var hasACK: Bool { flags.contains(.ack) }
    public var hasFIN: Bool { flags.contains(.fin) }
    public var hasRST: Bool { flags.contains(.rst) }
    public var hasPSH: Bool { flags.contains(.psh) }

    /// Sequence number of the first payload byte.
    public var payloadSequenceNumber: UInt32 {
        hasSYN ? sequenceNumber &+ 1 : sequenceNumber
    }

    /// Sequence number of the byte *after* this segment (payload plus SYN/FIN).
    public var sequenceNumberAfterPayload: UInt32 {
        var advance = UInt32(payload.count)
        if hasSYN { advance &+= 1 }
        if hasFIN { advance &+= 1 }
        return sequenceNumber &+ advance
    }

    /// The peer's advertised MSS, if it sent one.
    public var maximumSegmentSize: Int? {
        var reader = ByteReader(options)
        while reader.remaining >= 1 {
            guard let kind = try? reader.readUInt8() else { return nil }
            if kind == 0 { break }                     // End of option list
            if kind == 1 { continue }                  // No-op
            guard let length = try? reader.readUInt8(), length >= 2, reader.remaining >= Int(length) - 2 else {
                return nil
            }
            let body = (try? reader.readBytes(Int(length) - 2)) ?? []
            if kind == 2, body.count == 2 {
                return Int(body[0]) << 8 | Int(body[1])
            }
        }
        return nil
    }

    /// The peer's window-scale shift count, if it sent one.
    public var windowScale: Int? {
        var reader = ByteReader(options)
        while reader.remaining >= 1 {
            guard let kind = try? reader.readUInt8() else { return nil }
            if kind == 0 { break }
            if kind == 1 { continue }
            guard let length = try? reader.readUInt8(), length >= 2, reader.remaining >= Int(length) - 2 else {
                return nil
            }
            let body = (try? reader.readBytes(Int(length) - 2)) ?? []
            if kind == 3, body.count == 1 {
                return Int(body[0])
            }
        }
        return nil
    }

    // MARK: Parsing

    public static func parse(_ data: Data) throws -> TCPSegment {
        var reader = ByteReader(data)
        guard reader.remaining >= 20 else {
            throw TCPSegmentError.truncated(needed: 20, available: reader.remaining)
        }

        let sourcePort = try reader.readUInt16()
        let destinationPort = try reader.readUInt16()
        let sequenceNumber = try reader.readUInt32()
        let acknowledgmentNumber = try reader.readUInt32()
        let offsetAndFlags = try reader.readUInt16()
        let dataOffset = Int((offsetAndFlags >> 12) & 0x0F)
        let flags = TCPFlags(rawValue: UInt8(offsetAndFlags & 0x00FF))
        let windowSize = try reader.readUInt16()
        let urgentPointer = try reader.readUInt16()

        guard dataOffset >= 5 else { throw TCPSegmentError.badDataOffset(dataOffset) }
        let headerLength = dataOffset * 4
        guard data.count >= headerLength else {
            throw TCPSegmentError.truncated(needed: headerLength, available: data.count)
        }

        let optionLength = headerLength - 20
        let options = optionLength > 0 ? try reader.readBytes(optionLength) : []
        let payload = Data(data[data.startIndex + headerLength...])

        return TCPSegment(
            sourcePort: sourcePort,
            destinationPort: destinationPort,
            sequenceNumber: sequenceNumber,
            acknowledgmentNumber: acknowledgmentNumber,
            flags: flags,
            windowSize: windowSize,
            urgentPointer: urgentPointer,
            options: options,
            payload: payload
        )
    }

    // MARK: Serialisation

    /// Serialises the segment, computing the TCP checksum.
    ///
    /// `options` is padded to a 4-byte boundary with End-of-Option-List bytes, as
    /// the data offset is expressed in 32-bit words.
    public func serialized(source: IPAddress, destination: IPAddress) -> Data {
        var paddedOptions = options
        let remainder = paddedOptions.count % 4
        if remainder != 0 {
            for _ in 0..<(4 - remainder) { paddedOptions.append(0) }
        }
        let dataOffsetWords = UInt8(5 + paddedOptions.count / 4)

        var segment = [UInt8]()
        segment.reserveCapacity(20 + paddedOptions.count + payload.count)

        segment.append(UInt8((sourcePort >> 8) & 0xFF))
        segment.append(UInt8(sourcePort & 0xFF))
        segment.append(UInt8((destinationPort >> 8) & 0xFF))
        segment.append(UInt8(destinationPort & 0xFF))
        segment.append(UInt8((sequenceNumber >> 24) & 0xFF))
        segment.append(UInt8((sequenceNumber >> 16) & 0xFF))
        segment.append(UInt8((sequenceNumber >> 8) & 0xFF))
        segment.append(UInt8(sequenceNumber & 0xFF))
        segment.append(UInt8((acknowledgmentNumber >> 24) & 0xFF))
        segment.append(UInt8((acknowledgmentNumber >> 16) & 0xFF))
        segment.append(UInt8((acknowledgmentNumber >> 8) & 0xFF))
        segment.append(UInt8(acknowledgmentNumber & 0xFF))
        // Byte 12 = DataOffset(4) | Reserved(3) | NS(1); byte 13 = the classic
        // CWR ECE URG ACK PSH RST SYN FIN flags, which is exactly the bit order
        // used by `TCPFlags.rawValue`.
        segment.append((dataOffsetWords << 4) | 0x00)
        segment.append(flags.rawValue)
        segment.append(UInt8((windowSize >> 8) & 0xFF))
        segment.append(UInt8(windowSize & 0xFF))
        segment.append(UInt8((urgentPointer >> 8) & 0xFF))
        segment.append(UInt8(urgentPointer & 0xFF))
        segment.append(contentsOf: paddedOptions)
        segment.append(contentsOf: payload)

        // The checksum field is bytes 16-17; it is zero at this point because we
        // never wrote anything there, which is what the checksum definition wants.
        let checksum = InternetChecksum.transportChecksum(
            source: source,
            destination: destination,
            protocolNumber: IPProtocolNumber.tcp,
            segment: segment
        )
        segment[16] = UInt8((checksum >> 8) & 0xFF)
        segment[17] = UInt8(checksum & 0xFF)

        return Data(segment)
    }

    /// A human-readable one-liner for the packet trace log. No payload content.
    public func traceDescription(source: IPAddress?, destination: IPAddress?) -> String {
        let endpoints = "\(source?.description ?? "?"):\(sourcePort) -> \(destination?.description ?? "?"):\(destinationPort)"
        var text = "TCP \(endpoints) [\(flags.names)] seq=\(sequenceNumber) ack=\(acknowledgmentNumber) win=\(windowSize) len=\(payload.count)"
        if let mss = maximumSegmentSize { text += " mss=\(mss)" }
        if let scale = windowScale { text += " ws=\(scale)" }
        return text
    }
}
