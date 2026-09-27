//
//  HTTPConnectProtocol.swift
//  ProxyTunnelCore
//
//  Pure codec for the HTTP CONNECT method (RFC 9110 §9.3.6) as used by forward
//  proxies, including Basic proxy authentication (RFC 7617).
//
//  We only ever *send* CONNECT and *parse* the response head. Once the proxy
//  answers 2xx the connection becomes an opaque byte pipe, which is exactly what
//  the tunnel needs.
//

import Foundation

public enum HTTPConnectError: Error, Equatable, CustomStringConvertible {
    case incomplete
    case malformed(String)
    case invalidAuthority(String)

    public var description: String {
        switch self {
        case .incomplete:                 return "incomplete response head"
        case .malformed(let detail):      return "malformed: \(detail)"
        case .invalidAuthority(let what): return "invalid authority: \(what)"
        }
    }
}

public enum HTTPConnect {

    public static let defaultUserAgent = "ProxyTunnel/1.0 (iOS)"

    /// The response head, once a complete `\r\n\r\n`-terminated block is present.
    public struct Response: Equatable, Sendable {
        public let statusCode: Int
        public let reasonPhrase: String
        public let headers: [String: String]
        /// The HTTP version token from the status line, e.g. "HTTP/1.1".
        public let httpVersion: String

        public var isSuccess: Bool { (200...299).contains(statusCode) }

        /// `true` when the proxy wants credentials we did not supply (or that it
        /// did not accept).
        public var isAuthenticationChallenge: Bool { statusCode == 407 }

        public var summary: String {
            "\(httpVersion) \(statusCode) \(reasonPhrase)"
        }
    }

    // MARK: - Request

    /// Builds the CONNECT request head.
    ///
    /// Credentials, when present, are sent **pre-emptively** in a
    /// `Proxy-Authorization: Basic` header. That saves a round trip and, more
    /// importantly, avoids the failure mode where a proxy closes the connection
    /// instead of issuing a 407 challenge.
    public static func request(
        host: String,
        port: UInt16,
        credential: ProxyCredential?,
        userAgent: String = defaultUserAgent
    ) throws -> Data {
        let authority: String
        if let address = IPAddress(presentationName: host) {
            authority = address.authority(port: port)
        } else {
            guard !host.isEmpty, !host.contains(where: { $0 == " " || $0 == "\r" || $0 == "\n" }) else {
                throw HTTPConnectError.invalidAuthority(host)
            }
            authority = "\(host):\(port)"
        }

        var head = "CONNECT \(authority) HTTP/1.1\r\n"
        head += "Host: \(authority)\r\n"
        head += "User-Agent: \(userAgent)\r\n"
        head += "Proxy-Connection: Keep-Alive\r\n"
        if let credential {
            // RFC 7617 Basic: base64(user ":" password)
            let token = Data("\(credential.username):\(credential.password)".utf8).base64EncodedString()
            head += "Proxy-Authorization: Basic \(token)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8)
    }

    // MARK: - Response

    /// Parses a response head.
    ///
    /// - Throws: `HTTPConnectError.incomplete` when the terminating blank line
    ///   has not arrived yet. The caller should read more bytes and try again.
    public static func parseResponseHead(_ data: Data) throws -> Response {
        guard let terminator = findHeadTerminator(in: data) else {
            throw HTTPConnectError.incomplete
        }
        let headData = data[data.startIndex..<terminator]
        guard let headText = String(data: headData, encoding: .utf8) ?? String(data: headData, encoding: .isoLatin1) else {
            throw HTTPConnectError.malformed("response head is not text")
        }

        // Split on CRLF, tolerating bare LF.
        let lines = headText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        guard let statusLine = lines.first, !statusLine.isEmpty else {
            throw HTTPConnectError.malformed("empty status line")
        }

        // Status-Line = HTTP-Version SP Status-Code SP Reason-Phrase
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard statusParts.count >= 2 else {
            throw HTTPConnectError.malformed("bad status line: \"\(sanitizeForLog(statusLine))\"")
        }
        let version = String(statusParts[0])
        guard version.uppercased().hasPrefix("HTTP/") else {
            throw HTTPConnectError.malformed("not an HTTP response (\"\(sanitizeForLog(statusLine))\")")
        }
        guard let statusCode = Int(statusParts[1]), (100...599).contains(statusCode) else {
            throw HTTPConnectError.malformed("bad status code in \"\(sanitizeForLog(statusLine))\"")
        }
        let reason = statusParts.count >= 3 ? String(statusParts[2]) : ""

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            // Fold repeated headers (rare for the ones we care about).
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        return Response(
            statusCode: statusCode,
            reasonPhrase: reason,
            headers: headers,
            httpVersion: version
        )
    }

    /// Byte offset of the end of the head (just past the blank line), or `nil`.
    public static func findHeadTerminator(in data: Data) -> Data.Index? {
        let bytes = [UInt8](data)
        if bytes.count >= 4 {
            for i in 0...(bytes.count - 4) where bytes[i] == 0x0D && bytes[i + 1] == 0x0A
                && bytes[i + 2] == 0x0D && bytes[i + 3] == 0x0A {
                return data.startIndex + i + 4
            }
        }
        // Tolerate a server that only sends LF.
        if bytes.count >= 2 {
            for i in 0...(bytes.count - 2) where bytes[i] == 0x0A && bytes[i + 1] == 0x0A {
                return data.startIndex + i + 2
            }
        }
        return nil
    }

    /// Strips CR/LF so a malicious or broken proxy cannot inject fake log lines.
    static func sanitizeForLog(_ text: String) -> String {
        String(text.prefix(200)).replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: - Cap on the response head

    /// A response head larger than this is treated as an attack / broken proxy.
    public static let maximumResponseHeadBytes = 32 * 1024
}

// MARK: - Tiny HTTP/1.1 client used by the proxy connectivity probe

/// The probe sends one plaintext HTTP/1.1 request **through** the proxy so the
/// user can see the proxy's egress IP address. That is a real end-to-end proof
/// that the proxy relays traffic, and it needs only a trivial amount of HTTP.
public enum SimpleHTTP {

    public struct Response: Equatable, Sendable {
        public let statusCode: Int
        public let headers: [String: String]
        public let body: Data

        public var bodyText: String {
            String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    public static func getRequest(host: String, path: String) -> Data {
        var head = "GET \(path.isEmpty ? "/" : path) HTTP/1.1\r\n"
        head += "Host: \(host)\r\n"
        head += "User-Agent: \(HTTPConnect.defaultUserAgent)\r\n"
        head += "Accept: */*\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"
        return Data(head.utf8)
    }

    /// Parses a complete (or, with `Connection: close`, nearly complete) response.
    /// Returns `nil` while the head is still incomplete.
    public static func parse(_ data: Data) -> Response? {
        guard let terminator = HTTPConnect.findHeadTerminator(in: data) else { return nil }
        guard let response = try? HTTPConnect.parseResponseHead(data) else { return nil }
        let body = Data(data.suffix(from: terminator))
        return Response(statusCode: response.statusCode, headers: response.headers, body: body)
    }
}
