//
//  SOCKS5Protocol.swift
//  ProxyTunnelCore
//
//  Pure, synchronous codec for SOCKS5.
//
//  RFC 1928  - SOCKS Protocol Version 5
//  RFC 1929  - Username/Password Authentication for SOCKS V5
//
//  Splitting the byte-level encoding out from the I/O means every branch below
//  is unit-testable without a socket, which is the only realistic way to get
//  confidence in a protocol implementation.
//

import Foundation

public enum SOCKS5Error: Error, Equatable, CustomStringConvertible {
    /// The message so far is well-formed but truncated; read more and retry.
    case incomplete(needed: Int)
    case malformed(String)
    case unsupportedAddress(String)
    case fieldTooLong(String)

    public var description: String {
        switch self {
        case .incomplete(let needed):   return "incomplete (need \(needed) more bytes)"
        case .malformed(let detail):    return "malformed: \(detail)"
        case .unsupportedAddress(let h):return "unsupported address: \(h)"
        case .fieldTooLong(let f):      return "field too long: \(f)"
        }
    }
}

public enum SOCKS5 {

    public static let version: UInt8 = 0x05
    public static let authSubnegotiationVersion: UInt8 = 0x01
    public static let reserved: UInt8 = 0x00

    // MARK: Enumerations

    public enum AuthMethod: UInt8, Equatable, Sendable {
        case none = 0x00
        case gssapi = 0x01
        case userPassword = 0x02
        case noAcceptable = 0xFF

        public var name: String {
            switch self {
            case .none:         return "no authentication"
            case .gssapi:       return "GSSAPI"
            case .userPassword: return "username/password (RFC 1929)"
            case .noAcceptable: return "no acceptable methods"
            }
        }
    }

    public enum AddressType: UInt8, Equatable, Sendable {
        case ipv4 = 0x01
        case domainName = 0x03
        case ipv6 = 0x04
    }

    public enum Command: UInt8, Equatable, Sendable {
        case connect = 0x01
        case bind = 0x02
        case udpAssociate = 0x03

        public var name: String {
            switch self {
            case .connect:      return "CONNECT"
            case .bind:         return "BIND"
            case .udpAssociate: return "UDP ASSOCIATE"
            }
        }
    }

    public enum Reply: UInt8, Equatable, Sendable {
        case succeeded = 0x00
        case generalFailure = 0x01
        case connectionNotAllowed = 0x02
        case networkUnreachable = 0x03
        case hostUnreachable = 0x04
        case connectionRefused = 0x05
        case ttlExpired = 0x06
        case commandNotSupported = 0x07
        case addressTypeNotSupported = 0x08

        public var name: String {
            switch self {
            case .succeeded:               return "succeeded"
            case .generalFailure:          return "general SOCKS server failure"
            case .connectionNotAllowed:    return "connection not allowed by ruleset"
            case .networkUnreachable:      return "network unreachable"
            case .hostUnreachable:         return "host unreachable"
            case .connectionRefused:       return "connection refused"
            case .ttlExpired:              return "TTL expired"
            case .commandNotSupported:     return "command not supported"
            case .addressTypeNotSupported: return "address type not supported"
            }
        }
    }

    // MARK: - Client greeting (RFC 1928 §3)

    /// `VER | NMETHODS | METHODS...`
    public static func greeting(methods: [AuthMethod]) -> Data {
        var out = Data()
        out.append(version)
        out.append(UInt8(clamping: methods.count))
        for method in methods { out.append(method.rawValue) }
        return out
    }

    /// The method list a client should offer.
    ///
    /// We advertise `userPassword` first when credentials exist so that a server
    /// which supports both picks the authenticated path, and we always include
    /// `none` so that a proxy which requires no authentication still works when
    /// the user has left the fields blank.
    public static func defaultMethods(hasCredential: Bool) -> [AuthMethod] {
        hasCredential ? [.userPassword, .none] : [.none]
    }

    /// `VER | METHOD` — exactly 2 bytes.
    ///
    /// `.noAcceptable` (0xFF) is returned rather than thrown: whether that is a
    /// fatal error or simply "this proxy wants credentials you did not supply"
    /// depends on what the client offered, which only the caller knows.
    public static func parseMethodSelection(_ data: Data) throws -> AuthMethod {
        var reader = ByteReader(data)
        guard reader.remaining >= 2 else { throw SOCKS5Error.incomplete(needed: 2 - reader.remaining) }
        let ver = try reader.readUInt8()
        guard ver == version else {
            throw SOCKS5Error.malformed("server replied with SOCKS version \(ver), expected 5")
        }
        let methodRaw = try reader.readUInt8()
        guard let method = AuthMethod(rawValue: methodRaw) else {
            throw SOCKS5Error.malformed("unknown authentication method 0x\(String(format: "%02x", methodRaw))")
        }
        return method
    }

    // MARK: - Username/password sub-negotiation (RFC 1929)

    /// `VER(1) | ULEN | UNAME | PLEN | PASSWD`
    public static func userPasswordRequest(username: String, password: String) throws -> Data {
        let userBytes = Array(username.utf8)
        let passBytes = Array(password.utf8)
        guard userBytes.count <= 255 else { throw SOCKS5Error.fieldTooLong("username (\(userBytes.count) bytes)") }
        guard passBytes.count <= 255 else { throw SOCKS5Error.fieldTooLong("password (\(passBytes.count) bytes)") }

        var out = Data()
        out.append(authSubnegotiationVersion)
        out.append(UInt8(userBytes.count))
        out.append(contentsOf: userBytes)
        out.append(UInt8(passBytes.count))
        out.append(contentsOf: passBytes)
        return out
    }

    /// `VER(1) | STATUS`. STATUS 0 means success.
    ///
    /// Note: the error deliberately does not echo the credentials or anything
    /// derived from them.
    public static func parseUserPasswordResponse(_ data: Data) throws {
        var reader = ByteReader(data)
        guard reader.remaining >= 2 else { throw SOCKS5Error.incomplete(needed: 2 - reader.remaining) }
        let ver = try reader.readUInt8()
        guard ver == authSubnegotiationVersion else {
            throw SOCKS5Error.malformed("auth reply version \(ver), expected 1")
        }
        let status = try reader.readUInt8()
        guard status == 0x00 else {
            throw SOCKS5Error.malformed("authentication failed (status 0x\(String(format: "%02x", status)))")
        }
    }

    // MARK: - Requests

    /// `VER | CMD | RSV | ATYP | DST.ADDR | DST.PORT`
    public static func request(command: Command, host: String, port: UInt16) throws -> Data {
        var out = Data()
        out.append(version)
        out.append(command.rawValue)
        out.append(reserved)
        // `encodeAddress` appends ATYP and the address itself to `out` and returns
        // the ATYP it used. Appending the return value as well would insert a
        // stray byte and shift the port by one — which is exactly the bug the
        // codec tests caught.
        try encodeAddress(host: host, into: &out)
        out.appendUInt16(port)
        return out
    }

    /// Appends `ATYP | ADDR` for `host` and returns the address type used.
    ///
    /// Literal IP addresses are sent as-is (ATYP 1 or 4). Anything else is sent
    /// as a domain name (ATYP 3), which is what makes "remote DNS" work: the
    /// proxy resolves the name, so the local resolver is never consulted.
    @discardableResult
    public static func encodeAddress(host: String, into out: inout Data) throws -> UInt8 {
        if let address = IPAddress(presentationName: host) {
            let type: AddressType = address.isIPv4 ? .ipv4 : .ipv6
            out.append(type.rawValue)
            out.append(contentsOf: address.bytes)
            return type.rawValue
        }

        let nameBytes = Array(host.utf8)
        guard !nameBytes.isEmpty else { throw SOCKS5Error.unsupportedAddress("<empty>") }
        guard nameBytes.count <= 255 else { throw SOCKS5Error.fieldTooLong("domain name (\(nameBytes.count) bytes)") }
        out.append(AddressType.domainName.rawValue)
        out.append(UInt8(nameBytes.count))
        out.append(contentsOf: nameBytes)
        return AddressType.domainName.rawValue
    }

    // MARK: - Replies

    public struct ReplyMessage: Equatable, Sendable {
        public let reply: Reply
        /// Bound address reported by the server (BND.ADDR).
        public let boundHost: String
        public let boundPort: UInt16
        /// How many bytes of the input this message consumed.
        public let consumed: Int
    }

    /// Parses `VER | REP | RSV | ATYP | BND.ADDR | BND.PORT`.
    ///
    /// Throws `SOCKS5Error.incomplete` when the buffer does not yet hold the
    /// whole message, which is the signal for the caller to read more bytes.
    public static func parseReply(_ data: Data) throws -> ReplyMessage {
        var reader = ByteReader(data)
        guard reader.remaining >= 4 else { throw SOCKS5Error.incomplete(needed: 4 - reader.remaining) }

        let ver = try reader.readUInt8()
        guard ver == version else {
            throw SOCKS5Error.malformed("reply version \(ver), expected 5 (is this really a SOCKS5 proxy?)")
        }
        let repRaw = try reader.readUInt8()
        guard let reply = Reply(rawValue: repRaw) else {
            throw SOCKS5Error.malformed("unknown reply code 0x\(String(format: "%02x", repRaw))")
        }
        _ = try reader.readUInt8() // RSV
        let atypRaw = try reader.readUInt8()
        guard let atyp = AddressType(rawValue: atypRaw) else {
            throw SOCKS5Error.malformed("unknown address type 0x\(String(format: "%02x", atypRaw))")
        }

        let addressLength: Int
        switch atyp {
        case .ipv4:       addressLength = 4
        case .ipv6:       addressLength = 16
        case .domainName:
            guard reader.remaining >= 1 else { throw SOCKS5Error.incomplete(needed: 1) }
            let len = Int(try reader.readUInt8())
            addressLength = len
        }

        guard reader.remaining >= addressLength + 2 else {
            throw SOCKS5Error.incomplete(needed: addressLength + 2 - reader.remaining)
        }
        let addressBytes = try reader.readBytes(addressLength)
        let port = try reader.readUInt16()

        let host: String
        switch atyp {
        case .ipv4:
            host = IPAddress(bytes: addressBytes)?.description ?? "<invalid>"
        case .ipv6:
            host = IPAddress(bytes: addressBytes)?.description ?? "<invalid>"
        case .domainName:
            host = String(decoding: addressBytes, as: UTF8.self)
        }

        return ReplyMessage(reply: reply, boundHost: host, boundPort: port, consumed: reader.offset)
    }

    // MARK: - UDP datagram framing (RFC 1928 §7)

    /// ```
    /// +----+------+------+----------+----------+----------+
    /// |RSV | FRAG | ATYP | DST.ADDR | DST.PORT |   DATA   |
    /// +----+------+------+----------+----------+----------+
    /// | 2  |  1   |  1   | Variable |    2     | Variable |
    /// +----+------+------+----------+----------+----------+
    /// ```
    public struct UDPDatagram: Equatable, Sendable {
        public let fragment: UInt8
        public let destinationHost: String
        public let destinationPort: UInt16
        public let payload: Data
        public let consumed: Int
    }

    public static func encodeUDPDatagram(host: String, port: UInt16, payload: Data) throws -> Data {
        var out = Data()
        out.appendUInt16(0)          // RSV
        out.append(0)                // FRAG: we never fragment
        try encodeAddress(host: host, into: &out)
        out.appendUInt16(port)
        out.append(payload)
        return out
    }

    public static func parseUDPDatagram(_ data: Data) throws -> UDPDatagram {
        var reader = ByteReader(data)
        guard reader.remaining >= 4 else { throw SOCKS5Error.incomplete(needed: 4 - reader.remaining) }
        _ = try reader.readUInt16()  // RSV
        let frag = try reader.readUInt8()
        let atypRaw = try reader.readUInt8()
        guard let atyp = AddressType(rawValue: atypRaw) else {
            throw SOCKS5Error.malformed("unknown UDP address type 0x\(String(format: "%02x", atypRaw))")
        }

        let addressLength: Int
        switch atyp {
        case .ipv4: addressLength = 4
        case .ipv6: addressLength = 16
        case .domainName:
            guard reader.remaining >= 1 else { throw SOCKS5Error.incomplete(needed: 1) }
            addressLength = Int(try reader.readUInt8())
        }
        guard reader.remaining >= addressLength + 2 else {
            throw SOCKS5Error.incomplete(needed: addressLength + 2 - reader.remaining)
        }
        let addressBytes = try reader.readBytes(addressLength)
        let port = try reader.readUInt16()
        let payload = Data(reader.readRest())

        let host: String
        switch atyp {
        case .ipv4, .ipv6: host = IPAddress(bytes: addressBytes)?.description ?? "<invalid>"
        case .domainName:  host = String(decoding: addressBytes, as: UTF8.self)
        }

        return UDPDatagram(
            fragment: frag,
            destinationHost: host,
            destinationPort: port,
            payload: payload,
            consumed: reader.offset
        )
    }
}
