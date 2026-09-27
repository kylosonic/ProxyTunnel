//
//  UDPDatagram.swift
//  ProxyTunnelCore
//
//  UDP header parse / build (RFC 768).
//

import Foundation

public enum UDPDatagramError: Error, Equatable, CustomStringConvertible {
    case truncated(needed: Int, available: Int)

    public var description: String {
        switch self {
        case .truncated(let needed, let available): return "truncated: needed \(needed), have \(available)"
        }
    }
}

public struct UDPDatagram: Equatable, Sendable {

    public var sourcePort: UInt16
    public var destinationPort: UInt16
    public var payload: Data

    public init(sourcePort: UInt16, destinationPort: UInt16, payload: Data) {
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.payload = payload
    }

    public static func parse(_ data: Data) throws -> UDPDatagram {
        var reader = ByteReader(data)
        guard reader.remaining >= 8 else {
            throw UDPDatagramError.truncated(needed: 8, available: reader.remaining)
        }
        let sourcePort = try reader.readUInt16()
        let destinationPort = try reader.readUInt16()
        let length = Int(try reader.readUInt16())
        _ = try reader.readUInt16()   // checksum; we do not verify inbound UDP

        // `length` covers the header. Some senders get it wrong, so clamp.
        let effective = (length >= 8 && length - 8 <= reader.remaining) ? length - 8 : reader.remaining
        let payload = Data(try reader.readBytes(effective))
        return UDPDatagram(sourcePort: sourcePort, destinationPort: destinationPort, payload: payload)
    }

    /// Serialises the datagram with a valid checksum.
    ///
    /// For IPv6 the UDP checksum is mandatory (RFC 8200 §8.1). For IPv4 a zero
    /// checksum means "not computed", which some middleboxes dislike, so we always
    /// compute it. A computed value of zero is transmitted as 0xFFFF, because
    /// all-zeros is reserved for "no checksum".
    public func serialized(source: IPAddress, destination: IPAddress) -> Data {
        var datagram = [UInt8]()
        datagram.reserveCapacity(8 + payload.count)
        let length = 8 + payload.count
        datagram.append(UInt8((sourcePort >> 8) & 0xFF))
        datagram.append(UInt8(sourcePort & 0xFF))
        datagram.append(UInt8((destinationPort >> 8) & 0xFF))
        datagram.append(UInt8(destinationPort & 0xFF))
        datagram.append(UInt8((length >> 8) & 0xFF))
        datagram.append(UInt8(length & 0xFF))
        datagram.append(0)   // checksum placeholder
        datagram.append(0)
        datagram.append(contentsOf: payload)

        var checksum = InternetChecksum.transportChecksum(
            source: source,
            destination: destination,
            protocolNumber: IPProtocolNumber.udp,
            segment: datagram
        )
        if checksum == 0 { checksum = 0xFFFF }
        datagram[6] = UInt8((checksum >> 8) & 0xFF)
        datagram[7] = UInt8(checksum & 0xFF)

        return Data(datagram)
    }

    public func traceDescription(source: IPAddress?, destination: IPAddress?) -> String {
        "UDP \(source?.description ?? "?"):\(sourcePort) -> \(destination?.description ?? "?"):\(destinationPort) len=\(payload.count)"
    }
}
