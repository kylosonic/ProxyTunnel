//
//  IPPacket.swift
//  ProxyTunnelCore
//
//  Parsing and construction of IPv4 and IPv6 packets.
//
//  The stack only has to deal with the subset a packet tunnel actually sees:
//  unicast TCP and UDP with no IP options and no fragmentation. Anything else is
//  dropped, counted and (once) logged, rather than silently mishandled.
//

import Foundation

public enum IPProtocolNumber {
    public static let icmp: UInt8 = 1
    public static let igmp: UInt8 = 2
    public static let tcp: UInt8 = 6
    public static let udp: UInt8 = 17
    public static let ipv6Routing: UInt8 = 43
    public static let ipv6Fragment: UInt8 = 44
    public static let ipv6ICMP: UInt8 = 58
    public static let ipv6NoNextHeader: UInt8 = 59
    public static let ipv6DestinationOptions: UInt8 = 60
    public static let ipv6HopByHop: UInt8 = 0
}

public enum IPVersion: Equatable, Sendable {
    case v4
    case v6
}

public enum IPPacketError: Error, Equatable, CustomStringConvertible {
    case truncated(needed: Int, available: Int)
    case unsupportedVersion(UInt8)
    case unsupportedHeaderLength(Int)
    case fragmented
    case unsupportedExtensionHeader(UInt8)
    case empty

    public var description: String {
        switch self {
        case .truncated(let needed, let available):   return "truncated: needed \(needed), have \(available)"
        case .unsupportedVersion(let v):              return "unsupported IP version \(v)"
        case .unsupportedHeaderLength(let n):         return "unsupported IPv4 header length \(n) words"
        case .fragmented:                             return "fragmented packet (reassembly is not implemented)"
        case .unsupportedExtensionHeader(let type):   return "unsupported IPv6 extension header \(type)"
        case .empty:                                  return "empty packet"
        }
    }
}

/// A parsed IP packet: header fields we care about plus the transport payload.
public struct ParsedIPPacket: Equatable, Sendable {

    public let version: IPVersion
    public let source: IPAddress
    public let destination: IPAddress
    /// The transport protocol, after walking any IPv6 extension headers.
    public let protocolNumber: UInt8
    /// Transport-layer payload (TCP segment, UDP datagram, ICMP message…).
    public let payload: Data

    public let trafficClass: UInt8
    public let hopLimit: UInt8
    public let flowLabel: UInt32
    /// IPv4 identification field (0 for IPv6).
    public let identification: UInt16

    public var isTCP: Bool { protocolNumber == IPProtocolNumber.tcp }
    public var isUDP: Bool { protocolNumber == IPProtocolNumber.udp }

    // MARK: Parsing

    public static func parse(_ data: Data) throws -> ParsedIPPacket {
        guard let first = data.first else { throw IPPacketError.empty }
        switch first >> 4 {
        case 4:  return try parseIPv4(data)
        case 6:  return try parseIPv6(data)
        default: throw IPPacketError.unsupportedVersion(first >> 4)
        }
    }

    static func parseIPv4(_ data: Data) throws -> ParsedIPPacket {
        var reader = ByteReader(data)
        guard reader.remaining >= 20 else { throw IPPacketError.truncated(needed: 20, available: reader.remaining) }

        let versionAndIHL = try reader.readUInt8()
        let ihl = Int(versionAndIHL & 0x0F)          // header length in 32-bit words
        let trafficClass = try reader.readUInt8()
        let totalLength = Int(try reader.readUInt16())
        let identification = try reader.readUInt16()
        let flagsAndOffset = try reader.readUInt16()
        let hopLimit = try reader.readUInt8()
        let protocolNumber = try reader.readUInt8()
        _ = try reader.readUInt16()                  // header checksum (verified below)
        let sourceBytes = try reader.readBytes(4)
        let destinationBytes = try reader.readBytes(4)

        guard ihl >= 5 else { throw IPPacketError.unsupportedHeaderLength(ihl) }
        let headerLength = ihl * 4
        guard data.count >= headerLength else {
            throw IPPacketError.truncated(needed: headerLength, available: data.count)
        }

        let moreFragments = (flagsAndOffset & 0x2000) != 0
        let fragmentOffset = flagsAndOffset & 0x1FFF
        // We do not reassemble. Almost every fragmented packet on a phone is a
        // large UDP datagram; dropping it is the honest behaviour and it is
        // counted in the tunnel statistics.
        if moreFragments || fragmentOffset != 0 { throw IPPacketError.fragmented }

        guard let source = IPAddress(bytes: sourceBytes), let destination = IPAddress(bytes: destinationBytes) else {
            throw IPPacketError.empty
        }

        // `totalLength` may be 0 or bogus on some tunnel interfaces; clamp it to
        // what we actually received rather than trusting it blindly.
        let effectiveLength = (totalLength >= headerLength && totalLength <= data.count) ? totalLength : data.count
        let payload = Data(data[data.startIndex + headerLength ..< data.startIndex + effectiveLength])

        return ParsedIPPacket(
            version: .v4,
            source: source,
            destination: destination,
            protocolNumber: protocolNumber,
            payload: payload,
            trafficClass: trafficClass,
            hopLimit: hopLimit,
            flowLabel: 0,
            identification: identification
        )
    }

    static func parseIPv6(_ data: Data) throws -> ParsedIPPacket {
        var reader = ByteReader(data)
        guard reader.remaining >= 40 else { throw IPPacketError.truncated(needed: 40, available: reader.remaining) }

        let firstWord = try reader.readUInt32()
        let trafficClass = UInt8((firstWord >> 20) & 0xFF)
        let flowLabel = firstWord & 0x000F_FFFF
        let payloadLength = Int(try reader.readUInt16())
        var nextHeader = try reader.readUInt8()
        let hopLimit = try reader.readUInt8()
        let sourceBytes = try reader.readBytes(16)
        let destinationBytes = try reader.readBytes(16)

        guard let source = IPAddress(bytes: sourceBytes), let destination = IPAddress(bytes: destinationBytes) else {
            throw IPPacketError.empty
        }

        let effectivePayloadLength = (payloadLength > 0 && 40 + payloadLength <= data.count)
            ? payloadLength
            : data.count - 40
        var offset = 40
        let end = min(data.count, 40 + effectivePayloadLength)

        // Walk the extension-header chain. A phone's traffic normally has none,
        // but "hop-by-hop" appears on some networks and dropping the whole packet
        // would break that traffic for no reason.
        var hops = 0
        while hops < 8 {
            hops += 1
            switch nextHeader {
            case IPProtocolNumber.tcp, IPProtocolNumber.udp, IPProtocolNumber.ipv6ICMP:
                let payload = Data(data[data.startIndex + offset ..< data.startIndex + end])
                return ParsedIPPacket(
                    version: .v6,
                    source: source,
                    destination: destination,
                    protocolNumber: nextHeader,
                    payload: payload,
                    trafficClass: trafficClass,
                    hopLimit: hopLimit,
                    flowLabel: flowLabel,
                    identification: 0
                )
            case IPProtocolNumber.ipv6Fragment:
                throw IPPacketError.fragmented
            case IPProtocolNumber.ipv6HopByHop,
                 IPProtocolNumber.ipv6Routing,
                 IPProtocolNumber.ipv6DestinationOptions:
                // These headers are: NextHeader(1) | HdrExtLen(1) | ... padded to
                // 8-byte units, where HdrExtLen counts 8-byte units *after* the
                // first 8 bytes.
                guard offset + 2 <= end else { throw IPPacketError.truncated(needed: offset + 2, available: end) }
                let headerNext = data[data.startIndex + offset]
                let headerLength = (Int(data[data.startIndex + offset + 1]) + 1) * 8
                guard offset + headerLength <= end else {
                    throw IPPacketError.truncated(needed: offset + headerLength, available: end)
                }
                offset += headerLength
                nextHeader = headerNext
            case IPProtocolNumber.ipv6NoNextHeader:
                throw IPPacketError.empty
            default:
                throw IPPacketError.unsupportedExtensionHeader(nextHeader)
            }
        }
        throw IPPacketError.unsupportedExtensionHeader(nextHeader)
    }

    /// Verifies the IPv4 header checksum. Used by diagnostics to prove the tun
    /// interface is handing us well-formed packets.
    public static func isValidIPv4HeaderChecksum(_ data: Data) -> Bool {
        guard data.count >= 20 else { return false }
        let headerLength = Int(data[data.startIndex] & 0x0F) * 4
        guard headerLength >= 20, data.count >= headerLength else { return false }
        let header = [UInt8](data[data.startIndex ..< data.startIndex + headerLength])
        return InternetChecksum.fold(InternetChecksum.sum(header)) == 0xFFFF
    }

    // MARK: Construction

    /// Builds an IPv4 packet with a 20-byte header and a freshly computed header
    /// checksum.
    public static func buildIPv4(
        source: IPAddress,
        destination: IPAddress,
        protocolNumber: UInt8,
        payload: [UInt8],
        identification: UInt16,
        hopLimit: UInt8 = 64,
        trafficClass: UInt8 = 0
    ) -> Data {
        precondition(source.isIPv4 && destination.isIPv4, "buildIPv4 needs IPv4 addresses")

        let totalLength = 20 + payload.count
        var header = [UInt8]()
        header.reserveCapacity(20)
        header.append(0x45)                                   // version 4, IHL 5
        header.append(trafficClass)
        header.append(UInt8((totalLength >> 8) & 0xFF))
        header.append(UInt8(totalLength & 0xFF))
        header.append(UInt8((identification >> 8) & 0xFF))
        header.append(UInt8(identification & 0xFF))
        header.append(0x40)                                   // Don't Fragment
        header.append(0x00)
        header.append(hopLimit)
        header.append(protocolNumber)
        header.append(0)                                      // checksum placeholder
        header.append(0)
        header.append(contentsOf: source.bytes)
        header.append(contentsOf: destination.bytes)

        let checksum = InternetChecksum.checksum(header)
        header[10] = UInt8((checksum >> 8) & 0xFF)
        header[11] = UInt8(checksum & 0xFF)

        var packet = Data(header)
        packet.append(contentsOf: payload)
        return packet
    }

    /// Builds an IPv6 packet with a 40-byte header (no extension headers).
    public static func buildIPv6(
        source: IPAddress,
        destination: IPAddress,
        protocolNumber: UInt8,
        payload: [UInt8],
        hopLimit: UInt8 = 64,
        trafficClass: UInt8 = 0,
        flowLabel: UInt32 = 0
    ) -> Data {
        precondition(source.isIPv6 && destination.isIPv6, "buildIPv6 needs IPv6 addresses")

        let payloadLength = UInt16(clamping: payload.count)
        var header = [UInt8]()
        header.reserveCapacity(40)
        let firstWord: UInt32 = (6 << 28) | (UInt32(trafficClass) << 20) | (flowLabel & 0x000F_FFFF)
        header.append(UInt8((firstWord >> 24) & 0xFF))
        header.append(UInt8((firstWord >> 16) & 0xFF))
        header.append(UInt8((firstWord >> 8) & 0xFF))
        header.append(UInt8(firstWord & 0xFF))
        header.append(UInt8((payloadLength >> 8) & 0xFF))
        header.append(UInt8(payloadLength & 0xFF))
        header.append(protocolNumber)
        header.append(hopLimit)
        header.append(contentsOf: source.bytes)
        header.append(contentsOf: destination.bytes)

        var packet = Data(header)
        packet.append(contentsOf: payload)
        return packet
    }

    /// Builds a packet in whichever family the addresses belong to.
    public static func build(
        source: IPAddress,
        destination: IPAddress,
        protocolNumber: UInt8,
        payload: [UInt8],
        identification: UInt16,
        hopLimit: UInt8 = 64,
        trafficClass: UInt8 = 0,
        flowLabel: UInt32 = 0
    ) -> Data {
        if source.isIPv4 {
            return buildIPv4(
                source: source,
                destination: destination,
                protocolNumber: protocolNumber,
                payload: payload,
                identification: identification,
                hopLimit: hopLimit,
                trafficClass: trafficClass
            )
        }
        return buildIPv6(
            source: source,
            destination: destination,
            protocolNumber: protocolNumber,
            payload: payload,
            hopLimit: hopLimit,
            trafficClass: trafficClass,
            flowLabel: flowLabel
        )
    }
}
