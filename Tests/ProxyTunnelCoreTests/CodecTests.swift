//
//  CodecTests.swift
//  ProxyTunnelCoreTests
//
//  Byte-level tests for the protocol codecs and the packet parser. These are the
//  tests that catch the mistakes a compiler cannot: wrong offsets, wrong byte
//  order, missing padding, bad checksums.
//

import XCTest
@testable import ProxyTunnelCore

final class InternetChecksumTests: XCTestCase {

    func testKnownVector() {
        // RFC 1071 §3 worked example.
        let bytes: [UInt8] = [0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7]
        XCTAssertEqual(InternetChecksum.fold(InternetChecksum.sum(bytes)), 0xDDF2)
        XCTAssertEqual(InternetChecksum.checksum(bytes), 0x220D)
    }

    func testOddLengthIsPaddedWithZero() {
        XCTAssertEqual(
            InternetChecksum.checksum([0x01, 0x02, 0x03]),
            InternetChecksum.checksum([0x01, 0x02, 0x03, 0x00])
        )
    }

    func testVerifyingAChecksummedBlockYieldsAllOnes() {
        // The identity "sum(block + its checksum) == 0xFFFF" holds when the total
        // number of bytes is even: an odd-length block gets a zero pad on the final
        // word, which breaks it. Twenty bytes keeps it even after the two checksum
        // bytes are appended.
        var bytes: [UInt8] = Array("the quick brown fox!".utf8)
        XCTAssertEqual(bytes.count % 2, 0, "the property needs an even-length block")
        let checksum = InternetChecksum.checksum(bytes)
        bytes.append(UInt8(checksum >> 8))
        bytes.append(UInt8(checksum & 0xFF))
        XCTAssertEqual(InternetChecksum.fold(InternetChecksum.sum(bytes)), 0xFFFF)
    }

    func testOddLengthBlocksArePaddedWithZero() {
        // Documenting the limitation above explicitly, so nobody "fixes" the
        // even-length requirement by changing the algorithm.
        var bytes: [UInt8] = Array("the quick brown fox".utf8)
        XCTAssertEqual(bytes.count % 2, 1)
        let checksum = InternetChecksum.checksum(bytes)
        bytes.append(UInt8(checksum >> 8))
        bytes.append(UInt8(checksum & 0xFF))
        XCTAssertNotEqual(InternetChecksum.fold(InternetChecksum.sum(bytes)), 0xFFFF)
    }
}

final class IPv4PacketTests: XCTestCase {

    func testHeaderChecksumIsValidAfterBuilding() {
        let packet = ParsedIPPacket.buildIPv4(
            source: IPAddress(presentationName: "10.7.0.1")!,
            destination: IPAddress(presentationName: "93.184.216.34")!,
            protocolNumber: IPProtocolNumber.udp,
            payload: [1, 2, 3, 4],
            identification: 42
        )
        XCTAssertTrue(ParsedIPPacket.isValidIPv4HeaderChecksum(packet))
    }

    func testRoundTrips() throws {
        let source = IPAddress(presentationName: "10.7.0.1")!
        let destination = IPAddress(presentationName: "93.184.216.34")!
        let payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let packet = ParsedIPPacket.buildIPv4(
            source: source,
            destination: destination,
            protocolNumber: IPProtocolNumber.tcp,
            payload: payload,
            identification: 7,
            hopLimit: 55,
            trafficClass: 0x28
        )
        let parsed = try ParsedIPPacket.parse(packet)
        XCTAssertEqual(parsed.version, .v4)
        XCTAssertEqual(parsed.source, source)
        XCTAssertEqual(parsed.destination, destination)
        XCTAssertEqual(parsed.protocolNumber, IPProtocolNumber.tcp)
        XCTAssertEqual(Array(parsed.payload), payload)
        XCTAssertEqual(parsed.hopLimit, 55)
        XCTAssertEqual(parsed.identification, 7)
    }

    func testRejectsFragmentedPackets() {
        var packet = ParsedIPPacket.buildIPv4(
            source: IPAddress(presentationName: "10.0.0.1")!,
            destination: IPAddress(presentationName: "10.0.0.2")!,
            protocolNumber: IPProtocolNumber.udp,
            payload: [1, 2, 3, 4],
            identification: 1
        )
        // Set MF in the flags/fragment-offset field (bytes 6-7).
        packet[6] = 0x20
        XCTAssertThrowsError(try ParsedIPPacket.parse(packet)) { error in
            XCTAssertEqual(error as? IPPacketError, .fragmented)
        }
    }

    func testRejectsATruncatedHeader() {
        XCTAssertThrowsError(try ParsedIPPacket.parse(Data([0x45, 0x00, 0x00])))
    }

    func testRejectsUnknownVersion() {
        XCTAssertThrowsError(try ParsedIPPacket.parse(Data(repeating: 0x00, count: 40))) { error in
            XCTAssertEqual(error as? IPPacketError, .unsupportedVersion(0))
        }
    }
}

final class IPv6PacketTests: XCTestCase {

    func testRoundTrips() throws {
        let source = IPAddress(presentationName: "fd00:7:7:7::1")!
        let destination = IPAddress(presentationName: "2001:db8::9")!
        let packet = ParsedIPPacket.buildIPv6(
            source: source,
            destination: destination,
            protocolNumber: IPProtocolNumber.tcp,
            payload: [0xAA, 0xBB],
            hopLimit: 64,
            trafficClass: 0x00,
            flowLabel: 0x12345
        )
        let parsed = try ParsedIPPacket.parse(packet)
        XCTAssertEqual(parsed.version, .v6)
        XCTAssertEqual(parsed.source, source)
        XCTAssertEqual(parsed.destination, destination)
        XCTAssertEqual(parsed.protocolNumber, IPProtocolNumber.tcp)
        XCTAssertEqual(Array(parsed.payload), [0xAA, 0xBB])
        XCTAssertEqual(parsed.flowLabel, 0x12345)
    }

    func testWalksAHopByHopExtensionHeader() throws {
        // Build an IPv6 packet whose next header is hop-by-hop (0), which in turn
        // points at UDP.
        let source = IPAddress(presentationName: "fd00:7:7:7::1")!
        let destination = IPAddress(presentationName: "2001:db8::9")!
        var extensionHeader: [UInt8] = [IPProtocolNumber.udp, 0]  // next header, length (0 => 8 bytes)
        extensionHeader.append(contentsOf: [UInt8](repeating: 0, count: 6))
        let payload = extensionHeader + [1, 2, 3, 4]

        let packet = ParsedIPPacket.buildIPv6(
            source: source,
            destination: destination,
            protocolNumber: IPProtocolNumber.ipv6HopByHop,
            payload: payload
        )
        let parsed = try ParsedIPPacket.parse(packet)
        XCTAssertEqual(parsed.protocolNumber, IPProtocolNumber.udp)
        XCTAssertEqual(Array(parsed.payload), [1, 2, 3, 4])
    }

    func testRejectsAFragmentHeader() throws {
        let source = IPAddress(presentationName: "fd00:7:7:7::1")!
        let destination = IPAddress(presentationName: "2001:db8::9")!
        let packet = ParsedIPPacket.buildIPv6(
            source: source,
            destination: destination,
            protocolNumber: IPProtocolNumber.ipv6Fragment,
            payload: [UInt8](repeating: 0, count: 16)
        )
        XCTAssertThrowsError(try ParsedIPPacket.parse(packet)) { error in
            XCTAssertEqual(error as? IPPacketError, .fragmented)
        }
    }
}

final class TCPSegmentTests: XCTestCase {

    func testRoundTripsAHeader() throws {
        let segment = TCPSegment(
            sourcePort: 49152,
            destinationPort: 443,
            sequenceNumber: 0xDEADBEEF,
            acknowledgmentNumber: 0x01020304,
            flags: [.syn, .ack],
            windowSize: 65535,
            options: [2, 4, 0x05, 0xB4],
            payload: Data("hello".utf8)
        )
        let source = IPAddress(presentationName: "10.7.0.1")!
        let destination = IPAddress(presentationName: "93.184.216.34")!
        let raw = segment.serialized(source: source, destination: destination)
        let parsed = try TCPSegment.parse(raw)

        XCTAssertEqual(parsed.sourcePort, 49152)
        XCTAssertEqual(parsed.destinationPort, 443)
        XCTAssertEqual(parsed.sequenceNumber, 0xDEADBEEF)
        XCTAssertEqual(parsed.acknowledgmentNumber, 0x01020304)
        XCTAssertEqual(parsed.flags, [.syn, .ack])
        XCTAssertEqual(parsed.windowSize, 65535)
        XCTAssertEqual(parsed.maximumSegmentSize, 1460)
        XCTAssertEqual(String(decoding: parsed.payload, as: UTF8.self), "hello")
    }

    func testFlagsByteLayoutMatchesTheStandard() {
        // FIN=0x01, SYN=0x02, RST=0x04, PSH=0x08, ACK=0x10, URG=0x20, ECE=0x40, CWR=0x80
        XCTAssertEqual(TCPFlags.fin.rawValue, 0x01)
        XCTAssertEqual(TCPFlags.syn.rawValue, 0x02)
        XCTAssertEqual(TCPFlags.rst.rawValue, 0x04)
        XCTAssertEqual(TCPFlags.psh.rawValue, 0x08)
        XCTAssertEqual(TCPFlags.ack.rawValue, 0x10)
        XCTAssertEqual(TCPFlags.urg.rawValue, 0x20)
        XCTAssertEqual(TCPFlags.ece.rawValue, 0x40)
        XCTAssertEqual(TCPFlags.cwr.rawValue, 0x80)
    }

    func testChecksumIsCorrect() throws {
        let segment = TCPSegment(
            sourcePort: 1, destinationPort: 2,
            sequenceNumber: 3, acknowledgmentNumber: 4,
            flags: [.ack], windowSize: 100,
            payload: Data(repeating: 0x5A, count: 40)
        )
        let source = IPAddress(presentationName: "10.0.0.1")!
        let destination = IPAddress(presentationName: "10.0.0.2")!
        let raw = segment.serialized(source: source, destination: destination)

        // Recomputing over the finished segment (checksum field included) must
        // yield zero for a valid one's-complement checksum.
        var material = [UInt8]()
        material.append(contentsOf: source.bytes)
        material.append(contentsOf: destination.bytes)
        material.append(0)
        material.append(IPProtocolNumber.tcp)
        material.append(UInt8((raw.count >> 8) & 0xFF))
        material.append(UInt8(raw.count & 0xFF))
        material.append(contentsOf: raw)
        XCTAssertEqual(InternetChecksum.fold(InternetChecksum.sum(material)), 0xFFFF)
    }

    func testOptionsArePaddedToAFourByteBoundary() throws {
        // Three bytes of options force one padding byte, so the data offset must
        // still be a whole number of words.
        let segment = TCPSegment(
            sourcePort: 1, destinationPort: 2,
            sequenceNumber: 0, acknowledgmentNumber: 0,
            flags: [.syn], windowSize: 0,
            options: [3, 3, 7]
        )
        let source = IPAddress(presentationName: "10.0.0.1")!
        let raw = segment.serialized(source: source, destination: source)
        let dataOffset = Int((raw[12] >> 4) & 0x0F)
        XCTAssertEqual(dataOffset, 6, "5 words of header + 1 word of padded options")
        XCTAssertEqual(raw.count, 24, "20 bytes of header + 4 bytes of padded options")
    }

    func testHeaderIsTwentyBytesWithNoOptions() throws {
        let segment = TCPSegment(
            sourcePort: 1, destinationPort: 2,
            sequenceNumber: 0, acknowledgmentNumber: 0,
            flags: [.ack], windowSize: 0
        )
        let source = IPAddress(presentationName: "10.0.0.1")!
        let raw = segment.serialized(source: source, destination: source)
        XCTAssertEqual(raw.count, 20)
        XCTAssertEqual(Int((raw[12] >> 4) & 0x0F), 5)
    }

    func testChecksumFieldIsNotWrittenOverTheUrgentPointer() throws {
        // The checksum occupies bytes 16-17 and the urgent pointer 18-19. Getting
        // that order wrong silently corrupts both, so pin it down.
        let segment = TCPSegment(
            sourcePort: 1, destinationPort: 2,
            sequenceNumber: 0, acknowledgmentNumber: 0,
            flags: [.ack], windowSize: 0,
            urgentPointer: 0xBEEF
        )
        let source = IPAddress(presentationName: "10.0.0.1")!
        let raw = segment.serialized(source: source, destination: source)
        XCTAssertEqual(raw[18], 0xBE, "urgent pointer high byte")
        XCTAssertEqual(raw[19], 0xEF, "urgent pointer low byte")
        let parsed = try TCPSegment.parse(raw)
        XCTAssertEqual(parsed.urgentPointer, 0xBEEF)
    }

    func testSequenceNumberAfterPayloadAccountsForSynAndFin() {
        let syn = TCPSegment(
            sourcePort: 1, destinationPort: 2, sequenceNumber: 100,
            acknowledgmentNumber: 0, flags: [.syn], windowSize: 0
        )
        XCTAssertEqual(syn.sequenceNumberAfterPayload, 101)

        let finWithData = TCPSegment(
            sourcePort: 1, destinationPort: 2, sequenceNumber: 200,
            acknowledgmentNumber: 0, flags: [.fin, .ack], windowSize: 0,
            payload: Data(repeating: 0, count: 10)
        )
        XCTAssertEqual(finWithData.sequenceNumberAfterPayload, 211)
        XCTAssertEqual(finWithData.payloadSequenceNumber, 200)
    }

    func testParsesWindowScaleOption() throws {
        let segment = TCPSegment(
            sourcePort: 1, destinationPort: 2,
            sequenceNumber: 0, acknowledgmentNumber: 0,
            flags: [.syn], windowSize: 0,
            options: [2, 4, 0x05, 0xB4, 3, 3, 7]
        )
        let raw = segment.serialized(
            source: IPAddress(presentationName: "10.0.0.1")!,
            destination: IPAddress(presentationName: "10.0.0.2")!
        )
        let parsed = try TCPSegment.parse(raw)
        XCTAssertEqual(parsed.windowScale, 7)
        XCTAssertEqual(parsed.maximumSegmentSize, 1460)
    }

    func testRejectsABadDataOffset() {
        var raw = [UInt8](repeating: 0, count: 24)
        raw[12] = 0x30   // data offset 3 words: impossible, the minimum is 5
        XCTAssertThrowsError(try TCPSegment.parse(Data(raw)))
    }
}

final class UDPDatagramTests: XCTestCase {

    func testRoundTrips() throws {
        let datagram = UDPDatagram(sourcePort: 5353, destinationPort: 53, payload: Data([1, 2, 3]))
        let source = IPAddress(presentationName: "10.7.0.1")!
        let destination = IPAddress(presentationName: "1.1.1.1")!
        let raw = datagram.serialized(source: source, destination: destination)
        let parsed = try UDPDatagram.parse(raw)
        XCTAssertEqual(parsed.sourcePort, 5353)
        XCTAssertEqual(parsed.destinationPort, 53)
        XCTAssertEqual(Array(parsed.payload), [1, 2, 3])
    }

    func testIPv6UDPChecksumIsMandatoryAndNeverZero() {
        let datagram = UDPDatagram(sourcePort: 1, destinationPort: 2, payload: Data())
        let source = IPAddress(presentationName: "fd00:7:7:7::1")!
        let destination = IPAddress(presentationName: "2001:db8::1")!
        let raw = datagram.serialized(source: source, destination: destination)
        let checksum = UInt16(raw[6]) << 8 | UInt16(raw[7])
        XCTAssertNotEqual(checksum, 0, "IPv6 forbids a zero UDP checksum")
    }
}

final class SOCKS5CodecTests: XCTestCase {

    func testGreetingLayout() {
        let greeting = SOCKS5.greeting(methods: [.userPassword, .none])
        XCTAssertEqual(Array(greeting), [0x05, 0x02, 0x02, 0x00])
    }

    func testDefaultMethodsDependOnCredentials() {
        XCTAssertEqual(SOCKS5.defaultMethods(hasCredential: true), [.userPassword, .none])
        XCTAssertEqual(SOCKS5.defaultMethods(hasCredential: false), [.none])
    }

    func testParsesMethodSelection() throws {
        XCTAssertEqual(try SOCKS5.parseMethodSelection(Data([0x05, 0x00])), .none)
        XCTAssertEqual(try SOCKS5.parseMethodSelection(Data([0x05, 0x02])), .userPassword)
        XCTAssertEqual(try SOCKS5.parseMethodSelection(Data([0x05, 0xFF])), .noAcceptable)
    }

    func testThrowsIncompleteForAShortMethodSelection() {
        XCTAssertThrowsError(try SOCKS5.parseMethodSelection(Data([0x05]))) { error in
            XCTAssertEqual(error as? SOCKS5Error, .incomplete(needed: 1))
        }
    }

    func testRejectsAWrongVersion() {
        XCTAssertThrowsError(try SOCKS5.parseMethodSelection(Data([0x04, 0x00])))
    }

    func testUserPasswordRequestLayout() throws {
        let request = try SOCKS5.userPasswordRequest(username: "me", password: "pw")
        XCTAssertEqual(Array(request), [0x01, 0x02, 0x6D, 0x65, 0x02, 0x70, 0x77])
    }

    func testRejectsOverlongCredentialFields() {
        XCTAssertThrowsError(try SOCKS5.userPasswordRequest(username: String(repeating: "u", count: 256), password: "x"))
        XCTAssertThrowsError(try SOCKS5.userPasswordRequest(username: "u", password: String(repeating: "p", count: 256)))
    }

    func testUserPasswordResponse() throws {
        XCTAssertNoThrow(try SOCKS5.parseUserPasswordResponse(Data([0x01, 0x00])))
        XCTAssertThrowsError(try SOCKS5.parseUserPasswordResponse(Data([0x01, 0x01])))
    }

    func testConnectRequestWithIPv4() throws {
        let request = try SOCKS5.request(command: .connect, host: "203.0.113.7", port: 443)
        XCTAssertEqual(Array(request.prefix(4)), [0x05, 0x01, 0x00, 0x01])
        XCTAssertEqual(Array(request.suffix(2)), [0x01, 0xBB])
        XCTAssertEqual(request.count, 10)
    }

    func testConnectRequestWithIPv6() throws {
        let request = try SOCKS5.request(command: .connect, host: "2001:db8::1", port: 80)
        XCTAssertEqual(request[3], 0x04)
        XCTAssertEqual(request.count, 4 + 16 + 2)
    }

    func testConnectRequestWithADomainNameUsesRemoteDNS() throws {
        let request = try SOCKS5.request(command: .connect, host: "example.com", port: 80)
        XCTAssertEqual(request[3], 0x03)
        XCTAssertEqual(request[4], 11)
        XCTAssertEqual(String(decoding: request[5..<16], as: UTF8.self), "example.com")
    }

    func testUDPAssociateCommand() throws {
        let request = try SOCKS5.request(command: .udpAssociate, host: "0.0.0.0", port: 0)
        XCTAssertEqual(request[1], 0x03)
    }

    func testParsesAReply() throws {
        var data = Data([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1])
        data.appendUInt16(9050)
        let reply = try SOCKS5.parseReply(data)
        XCTAssertEqual(reply.reply, .succeeded)
        XCTAssertEqual(reply.boundHost, "127.0.0.1")
        XCTAssertEqual(reply.boundPort, 9050)
        XCTAssertEqual(reply.consumed, 10)
    }

    func testParsesAReplyWithADomainBoundAddress() throws {
        var data = Data([0x05, 0x00, 0x00, 0x03, 0x03])
        data.append(contentsOf: Array("rel".utf8))
        data.appendUInt16(1080)
        let reply = try SOCKS5.parseReply(data)
        XCTAssertEqual(reply.boundHost, "rel")
        XCTAssertEqual(reply.boundPort, 1080)
    }

    func testReportsIncompleteRepliesSoTheCallerCanReadMore() {
        // Header only: we need the address and port too.
        XCTAssertThrowsError(try SOCKS5.parseReply(Data([0x05, 0x00, 0x00, 0x01]))) { error in
            XCTAssertEqual(error as? SOCKS5Error, .incomplete(needed: 6))
        }
    }

    func testReportsEveryReplyCode() throws {
        let codes: [(UInt8, SOCKS5.Reply)] = [
            (0x01, .generalFailure), (0x02, .connectionNotAllowed), (0x03, .networkUnreachable),
            (0x04, .hostUnreachable), (0x05, .connectionRefused), (0x06, .ttlExpired),
            (0x07, .commandNotSupported), (0x08, .addressTypeNotSupported)
        ]
        for (raw, expected) in codes {
            var data = Data([0x05, raw, 0x00, 0x01, 0, 0, 0, 0])
            data.appendUInt16(0)
            XCTAssertEqual(try SOCKS5.parseReply(data).reply, expected)
        }
    }

    func testUDPDatagramFraming() throws {
        let encoded = try SOCKS5.encodeUDPDatagram(host: "1.1.1.1", port: 53, payload: Data([0xAA, 0xBB]))
        XCTAssertEqual(Array(encoded.prefix(4)), [0x00, 0x00, 0x00, 0x01])
        XCTAssertEqual(Array(encoded.suffix(2)), [0xAA, 0xBB])

        let decoded = try SOCKS5.parseUDPDatagram(encoded)
        XCTAssertEqual(decoded.fragment, 0)
        XCTAssertEqual(decoded.destinationHost, "1.1.1.1")
        XCTAssertEqual(decoded.destinationPort, 53)
        XCTAssertEqual(Array(decoded.payload), [0xAA, 0xBB])
    }

    func testUDPDatagramWithADomainName() throws {
        let encoded = try SOCKS5.encodeUDPDatagram(host: "dns.example.com", port: 53, payload: Data([1]))
        let decoded = try SOCKS5.parseUDPDatagram(encoded)
        XCTAssertEqual(decoded.destinationHost, "dns.example.com")
    }
}

final class HTTPConnectCodecTests: XCTestCase {

    func testRequestLayoutForIPv4() throws {
        let request = try HTTPConnect.request(host: "203.0.113.7", port: 443, credential: nil)
        let text = String(decoding: request, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("CONNECT 203.0.113.7:443 HTTP/1.1\r\n"))
        XCTAssertTrue(text.contains("Host: 203.0.113.7:443\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
        XCTAssertFalse(text.lowercased().contains("proxy-authorization"))
    }

    func testRequestBracketsIPv6() throws {
        let request = try HTTPConnect.request(host: "2001:db8::1", port: 443, credential: nil)
        XCTAssertTrue(String(decoding: request, as: UTF8.self).hasPrefix("CONNECT [2001:db8::1]:443 HTTP/1.1"))
    }

    func testRequestSendsBasicCredentialsPreemptively() throws {
        let request = try HTTPConnect.request(
            host: "proxy.example.com",
            port: 8080,
            credential: ProxyCredential(username: "u", password: "p")
        )
        let text = String(decoding: request, as: UTF8.self)
        let expected = Data("u:p".utf8).base64EncodedString()
        XCTAssertTrue(text.contains("Proxy-Authorization: Basic \(expected)\r\n"))
    }

    func testParsesASuccessResponse() throws {
        let raw = Data("HTTP/1.1 200 Connection established\r\nProxy-Agent: x\r\n\r\n".utf8)
        let response = try HTTPConnect.parseResponseHead(raw)
        XCTAssertTrue(response.isSuccess)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers["proxy-agent"], "x")
    }

    func testParsesAnAuthenticationChallenge() throws {
        let raw = Data("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic\r\n\r\n".utf8)
        let response = try HTTPConnect.parseResponseHead(raw)
        XCTAssertTrue(response.isAuthenticationChallenge)
        XCTAssertFalse(response.isSuccess)
    }

    func testToleratesBareLineFeed() throws {
        let raw = Data("HTTP/1.0 200 OK\n\n".utf8)
        XCTAssertEqual(try HTTPConnect.parseResponseHead(raw).statusCode, 200)
    }

    func testReportsIncompleteUntilTheBlankLineArrives() {
        XCTAssertThrowsError(try HTTPConnect.parseResponseHead(Data("HTTP/1.1 200 OK\r\n".utf8))) { error in
            XCTAssertEqual(error as? HTTPConnectError, .incomplete)
        }
    }

    func testRejectsANonHTTPResponse() {
        XCTAssertThrowsError(try HTTPConnect.parseResponseHead(Data("garbage\r\n\r\n".utf8)))
    }

    func testFindsTheHeadTerminatorSoLeftoverBytesSurvive() throws {
        let raw = Data("HTTP/1.1 200 OK\r\n\r\nBODYDATA".utf8)
        let terminator = try XCTUnwrap(HTTPConnect.findHeadTerminator(in: raw))
        XCTAssertEqual(String(decoding: Data(raw.suffix(from: terminator)), as: UTF8.self), "BODYDATA")
    }

    func testRequestRejectsAnAuthorityWithSpaces() {
        XCTAssertThrowsError(try HTTPConnect.request(host: "bad host", port: 80, credential: nil))
    }

    func testRequestRejectsHeaderInjection() {
        XCTAssertThrowsError(try HTTPConnect.request(host: "evil\r\nX: y", port: 80, credential: nil))
    }

    func testSimpleHTTPResponseParsing() throws {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\n1.2.3.4".utf8)
        let response = try XCTUnwrap(SimpleHTTP.parse(raw))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.bodyText, "1.2.3.4")
    }
}

final class ProxyProtocolCapabilityTests: XCTestCase {

    func testEveryProtocolHasACapabilityDescription() {
        for protocolType in ProxyProtocol.allCases {
            let described = ProxyProtocolCapabilities.describe(protocolType)
            XCTAssertEqual(described.protocolType, protocolType)
            XCTAssertFalse(described.tcp.isEmpty)
            XCTAssertFalse(described.udp.isEmpty)
            XCTAssertFalse(described.dns.isEmpty)
            XCTAssertFalse(described.ipv4.isEmpty)
            XCTAssertFalse(described.ipv6.isEmpty)
            XCTAssertFalse(described.notes.isEmpty)
        }
    }

    func testSOCKS5IsTheOnlyProtocolAdvertisingUDP() {
        for protocolType in ProxyProtocol.allCases {
            let described = ProxyProtocolCapabilities.describe(protocolType)
            if protocolType.supportsUDP {
                XCTAssertTrue(described.udp.hasPrefix("Yes"), "\(protocolType) claims UDP support")
            } else {
                XCTAssertTrue(described.udp.hasPrefix("No"), "\(protocolType) must not claim UDP support")
            }
        }
    }
}
