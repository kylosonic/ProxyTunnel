//
//  DNSTunnelResolver.swift
//  ProxyTunnelCore
//
//  DNS inside the tunnel.
//
//  ## The leak problem
//
//  A naive packet tunnel resolves names with the system resolver, which the
//  carrier or the local Wi-Fi network can see. Even after the tunnel is up, an
//  app can still be handed a resolver on the local network.
//
//  ## What this does about it
//
//  `TunnelNetworkSettingsFactory` advertises the tunnel's own resolvers to iOS,
//  and `TunnelEngine` intercepts every UDP/53 packet that arrives. Each query is
//  then carried to the *origin server* over the proxy connection:
//
//    * with SOCKS5, over the UDP association (fastest, keeps datagram semantics);
//    * with HTTP CONNECT / HTTPS, as DNS-over-TCP (RFC 7766) inside the tunnelled
//      stream — no UDP needed anywhere.
//
//  We never parse DNS. The query is forwarded as opaque bytes and the answer is
//  returned verbatim, which means EDNS0, DNSSEC records, and any future extension
//  pass through untouched.
//
//  ## Honest limitations
//
//    * A query larger than `maximumQueryBytes` is dropped rather than being
//      fragmented.
//    * The TCP path opens one proxied connection per query. That is correct but
//      not cheap; it is a deliberate trade for not having to keep a connection
//      pool in a process that iOS may suspend at any moment.
//    * Encrypted DNS (DoH/DoT) initiated by an app is *not* intercepted — it is
//      just TCP/UDP to port 443/853 and is proxied like anything else, which is
//      fine because it is already encrypted.
//

import Foundation

public enum DNSTunnelResolver {

    /// DNS over TCP framing: a 2-byte big-endian length prefix per message.
    public static let maximumQueryBytes = 8 * 1024
    public static let maximumResponseBytes = 32 * 1024

    // MARK: - Path 1: raw relay over SOCKS5 UDP

    /// Forwards the datagram verbatim through the SOCKS5 UDP association.
    public static func resolveViaUDPRelay(
        query: Data,
        server: String,
        port: UInt16,
        relay: SOCKS5UDPRelay,
        timeout: TimeInterval,
        queue: DispatchQueue,
        log: DiagnosticLog?,
        completion: @escaping (Result<Data, ProxyError>) -> Void
    ) {
        let transactionID = query.count >= 2 ? UInt16(query[query.startIndex]) << 8 | UInt16(query[query.startIndex + 1]) : 0
        var finished = false

        func finish(_ result: Result<Data, ProxyError>) {
            guard !finished else { return }
            finished = true
            completion(result)
        }

        let timeoutWork = DispatchWorkItem { finish(.failure(.connectionTimeout)) }
        queue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

        relay.send(payload: query, to: server, port: port) { result in
            if case .failure(let error) = result {
                timeoutWork.cancel()
                finish(.failure(.connectionFailed("UDP relay send failed: \(error)")))
                return
            }
            relay.receive { result in
                timeoutWork.cancel()
                switch result {
                case .failure(let error):
                    finish(.failure(.connectionFailed("UDP relay receive failed: \(error)")))
                case .success(let datagram):
                    // Guard against a stale answer for a previous transaction.
                    guard datagram.payload.count >= 2 else {
                        finish(.failure(.badServerResponse("DNS reply is too short")))
                        return
                    }
                    let replyID = UInt16(datagram.payload[datagram.payload.startIndex]) << 8
                        | UInt16(datagram.payload[datagram.payload.startIndex + 1])
                    guard replyID == transactionID else {
                        log?.debug("dns", "ignoring DNS reply with mismatched transaction id")
                        finish(.failure(.badServerResponse("DNS reply transaction id mismatch")))
                        return
                    }
                    finish(.success(datagram.payload))
                }
            }
        }
    }

    // MARK: - Path 2: DNS over TCP through the proxy

    /// Sends the query as a length-prefixed DNS-over-TCP message on a freshly
    /// proxied stream to `server:port`.
    public static func resolveOverTCP(
        query: Data,
        server: String,
        port: UInt16,
        opener: ProxyStreamOpening,
        timeout: TimeInterval,
        queue: DispatchQueue,
        log: DiagnosticLog?,
        completion: @escaping (Result<Data, ProxyError>) -> Void
    ) {
        guard query.count <= maximumQueryBytes else {
            completion(.failure(.protocolViolation("DNS query of \(query.count) bytes exceeds the \(maximumQueryBytes)-byte limit")))
            return
        }

        opener.openProxyStream(to: .connect(host: server, port: port), queue: queue) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let connection):
                var framed = Data()
                framed.appendUInt16(UInt16(query.count))
                framed.append(query)

                connection.stream.write(framed) { writeResult in
                    if case .failure(let error) = writeResult {
                        connection.close()
                        completion(.failure(.connectionFailed("could not send the DNS query: \(error)")))
                        return
                    }
                    readLengthPrefixedMessage(
                        stream: connection.stream,
                        queue: queue,
                        timeout: timeout,
                        log: log
                    ) { readResult in
                        connection.close()
                        completion(readResult)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Reads `[uint16 length][message]` from a stream.
    static func readLengthPrefixedMessage(
        stream: DuplexByteStream,
        queue: DispatchQueue,
        timeout: TimeInterval,
        log: DiagnosticLog?,
        completion: @escaping (Result<Data, ProxyError>) -> Void
    ) {
        let reader = LengthPrefixedReader(
            stream: stream,
            queue: queue,
            timeout: timeout,
            maximumMessageBytes: maximumResponseBytes,
            completion: completion
        )
        reader.begin()
    }
}

// MARK: - Length-prefixed reader

/// Accumulates bytes until a complete `[uint16 length][payload]` message is
/// available, or the deadline passes.
private final class LengthPrefixedReader {

    private let stream: DuplexByteStream
    private let queue: DispatchQueue
    private let timeout: TimeInterval
    private let maximumMessageBytes: Int
    private let completion: (Result<Data, ProxyError>) -> Void

    private var buffer = Data()
    private var isFinished = false
    private var timeoutWork: DispatchWorkItem?

    /// Keeps this reader alive while the read is in flight.
    ///
    /// The receive callback captures `self` weakly so that a DNS server which never
    /// answers cannot leak a reader, which means nothing else retains it:
    /// `readLengthPrefixedMessage` returns as soon as `begin()` does. Released in
    /// `finish`, which runs exactly once. See `ProxySession.Runner` for the same
    /// pattern and the failure it prevents.
    private var selfRetain: LengthPrefixedReader?

    init(
        stream: DuplexByteStream,
        queue: DispatchQueue,
        timeout: TimeInterval,
        maximumMessageBytes: Int,
        completion: @escaping (Result<Data, ProxyError>) -> Void
    ) {
        self.stream = stream
        self.queue = queue
        self.timeout = timeout
        self.maximumMessageBytes = maximumMessageBytes
        self.completion = completion
    }

    func begin() {
        selfRetain = self
        let work = DispatchWorkItem { [weak self] in
            self?.finish(.failure(.connectionTimeout))
        }
        timeoutWork = work
        queue.asyncAfter(deadline: .now() + timeout, execute: work)
        readNext()
    }

    private func readNext() {
        guard !isFinished else { return }
        stream.read { [weak self] result in
            guard let self, !self.isFinished else { return }
            switch result {
            case .failure(let error):
                self.finish(.failure(.connectionFailed("\(error)")))
            case .success(let chunk):
                if chunk.isEmpty {
                    self.finish(.failure(.connectionFailed("the DNS server closed the connection before answering")))
                    return
                }
                self.buffer.append(chunk)
                self.evaluate()
            }
        }
    }

    private func evaluate() {
        guard buffer.count >= 2 else {
            readNext()
            return
        }
        let length = Int(buffer[buffer.startIndex]) << 8 | Int(buffer[buffer.startIndex + 1])
        guard length > 0, length <= maximumMessageBytes else {
            finish(.failure(.badServerResponse("DNS-over-TCP message length \(length) is out of range")))
            return
        }
        guard buffer.count >= 2 + length else {
            readNext()
            return
        }
        let message = Data(buffer[buffer.startIndex + 2 ..< buffer.startIndex + 2 + length])
        finish(.success(message))
    }

    private func finish(_ result: Result<Data, ProxyError>) {
        guard !isFinished else { return }
        isFinished = true
        timeoutWork?.cancel()
        timeoutWork = nil
        let callback = completion
        selfRetain = nil
        callback(result)
    }
}
