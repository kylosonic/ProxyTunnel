package io.github.kylosonic.proxytunnel.core

import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * A SOCKS5 server on loopback that egresses through an HTTP CONNECT proxy.
 *
 * ## Why this exists
 *
 * The tunnel engine, hev-socks5-tunnel, speaks SOCKS5 and nothing else. Most proxy
 * plans — including every free tier worth having — sell HTTP CONNECT, not SOCKS5.
 * Without this bridge those two facts are incompatible: you can pay for a proxy and
 * still be unable to put it behind the tunnel.
 *
 * So the engine is pointed at this instead:
 *
 * ```
 *   hev-socks5-tunnel ──SOCKS5──▶ 127.0.0.1:bridgePort ──HTTP CONNECT──▶ your proxy ──▶ internet
 * ```
 *
 * Both sides of a proxied connection run inside this app's process, which is
 * excluded from its own tunnel by `addDisallowedApplication`. So the loopback hop
 * and the dial to the proxy both bypass the tun, and there is no routing loop.
 *
 * ## What it carries, and what it cannot
 *
 * * **TCP** — fully. Every `CONNECT` becomes one HTTP CONNECT tunnel.
 * * **DNS** — yes, by a deliberate trick. `UDP ASSOCIATE` is accepted, and DNS
 *   queries are relayed as **DNS-over-TCP (RFC 7766)** through a CONNECT tunnel.
 *   This is the same technique the iOS tunnel uses for HTTP proxies. It matters
 *   because the alternative — dropping UDP — means no name resolution at all, and
 *   a tunnel where nothing resolves is not a tunnel.
 * * **Everything else UDP** — dropped, and counted. HTTP CONNECT has no datagram
 *   relay, so QUIC, HTTP/3, WireGuard and UDP games cannot work through it. The
 *   count is surfaced in the UI rather than hidden, because "some of your traffic
 *   is silently going nowhere" is something a user deserves to see.
 *
 * HTTPS CONNECT upstreams (TLS *to the proxy*) are deliberately not implemented
 * here. Doing it means wrapping this dial in TLS with its own trust decisions, and
 * an untested TLS path in the middle of a tunnel is worse than an honest refusal.
 * [ProxyProfile.supportsBridgeUpstream] is the single place that decides.
 */
class Socks5Bridge(
    private val upstream: ProxyProfile,
    private val upstreamCredential: ProxyCredential?,
    private val connectTimeoutMillis: Int = 15_000,
    private val handshakeTimeoutMillis: Int = 30_000,
    /**
     * The only UDP destination this bridge relays. 53 is the real value everywhere
     * except tests, which cannot bind a privileged port on CI.
     */
    private val dnsPort: Int = 53,
    private val dnsReadTimeoutMillis: Int = 10_000
) : Closeable {

    data class Stats(
        val tcpConnections: Long = 0,
        val activeConnections: Int = 0,
        val bytesUp: Long = 0,
        val bytesDown: Long = 0,
        val dnsQueries: Long = 0,
        val droppedDatagrams: Long = 0,
        val refusedConnections: Long = 0,
        val lastError: String? = null
    )

    private val listener = ServerSocket(0, 64, InetAddress.getByName(LOOPBACK))
    private val udpRelay = DatagramSocket(0, InetAddress.getByName(LOOPBACK))
    private val pool = Executors.newCachedThreadPool { runnable ->
        Thread(runnable, "socks5-bridge").apply { isDaemon = true }
    }
    private val running = AtomicBoolean(false)
    private val sockets = ConcurrentHashMap.newKeySet<Socket>()
    private val dnsChannels = ConcurrentHashMap<String, DnsOverTcpChannel>()

    private val tcpConnections = AtomicLong()
    private val activeConnections = AtomicInteger()
    private val bytesUp = AtomicLong()
    private val bytesDown = AtomicLong()
    private val dnsQueries = AtomicLong()
    private val droppedDatagrams = AtomicLong()
    private val refusedConnections = AtomicLong()

    @Volatile
    private var lastError: String? = null

    /** The loopback port the engine should be pointed at. */
    val port: Int get() = listener.localPort

    val stats: Stats
        get() = Stats(
            tcpConnections = tcpConnections.get(),
            activeConnections = activeConnections.get(),
            bytesUp = bytesUp.get(),
            bytesDown = bytesDown.get(),
            dnsQueries = dnsQueries.get(),
            droppedDatagrams = droppedDatagrams.get(),
            refusedConnections = refusedConnections.get(),
            lastError = lastError
        )

    companion object {
        const val LOOPBACK = "127.0.0.1"
        private const val BUFFER = 16 * 1024
        private const val MAX_DNS_MESSAGE = 65_535

        /** Whether [profile] can be bridged this way. */
        fun supports(profile: ProxyProfile): Boolean = profile.supportsBridgeUpstream

        private fun readExactly(input: InputStream, count: Int): ByteArray {
            val buffer = ByteArray(count)
            var read = 0
            while (read < count) {
                val n = input.read(buffer, read, count - read)
                if (n < 0) throw IOException("peer closed after $read of $count bytes")
                read += n
            }
            return buffer
        }
    }

    fun start(): Int {
        if (!running.compareAndSet(false, true)) return port
        pool.submit { acceptLoop() }
        pool.submit { udpLoop() }
        return port
    }

    override fun close() {
        running.set(false)
        runCatching { listener.close() }
        runCatching { udpRelay.close() }
        dnsChannels.values.forEach { it.close() }
        dnsChannels.clear()
        sockets.forEach { runCatching { it.close() } }
        sockets.clear()
        pool.shutdownNow()
    }

    // MARK: TCP

    private fun acceptLoop() {
        while (running.get()) {
            val client = try {
                listener.accept()
            } catch (e: IOException) {
                break
            }
            tcpConnections.incrementAndGet()
            pool.submit { serve(client) }
        }
    }

    private fun serve(client: Socket) {
        activeConnections.incrementAndGet()
        sockets += client
        try {
            client.tcpNoDelay = true
            client.soTimeout = handshakeTimeoutMillis
            val input = client.getInputStream()
            val output = client.getOutputStream()

            if (!negotiate(input, output)) return

            val request = readRequest(input)
            if (request == null) {
                reply(output, Socks5.REP_COMMAND_NOT_SUPPORTED)
                return
            }

            when (request.command) {
                Socks5.CMD_CONNECT -> {
                    val tunnel = try {
                        openTunnel(request.host, request.port)
                    } catch (e: UpstreamRefusal) {
                        refusedConnections.incrementAndGet()
                        lastError = e.message
                        reply(output, e.replyCode)
                        return
                    }
                    sockets += tunnel
                    replySuccess(output, request)
                    // Past the handshake there is no such thing as too quiet: the client
                    // may hold a connection open for hours.
                    client.soTimeout = 0
                    relay(client, tunnel)
                }

                Socks5.CMD_UDP_ASSOCIATE -> {
                    // The association lives as long as this TCP connection, so the reply
                    // has to be sent before we block waiting for it to close.
                    replyWithEndpoint(output, udpRelay.localPort)
                    client.soTimeout = 0
                    drainUntilClosed(input)
                }

                else -> reply(output, Socks5.REP_COMMAND_NOT_SUPPORTED)
            }
        } catch (e: IOException) {
            // A client that hangs up mid-handshake is ordinary, not an error worth keeping.
        } catch (e: Exception) {
            lastError = LogRedactor.redact("${e.javaClass.simpleName}: ${e.message}")
        } finally {
            activeConnections.decrementAndGet()
            sockets -= client
            runCatching { client.close() }
        }
    }

    private class Request(val command: Byte, val host: String, val port: Int)

    private fun negotiate(input: InputStream, output: OutputStream): Boolean {
        val header = readExactly(input, 2)
        if (header[0] != Socks5.VERSION) {
            lastError = "client did not speak SOCKS5 (version ${header[0]})"
            return false
        }
        val methods = readExactly(input, header[1].toInt() and 0xFF)
        // Loopback only, and the only client is the engine inside this process, so
        // there is nothing to authenticate: no other app can reach this socket.
        return if (methods.contains(Socks5.METHOD_NONE)) {
            output.write(byteArrayOf(Socks5.VERSION, Socks5.METHOD_NONE))
            output.flush()
            true
        } else {
            output.write(byteArrayOf(Socks5.VERSION, Socks5.METHOD_NO_ACCEPTABLE))
            output.flush()
            lastError = "client offered no acceptable authentication method"
            false
        }
    }

    private fun readRequest(input: InputStream): Request? {
        val header = readExactly(input, 4)
        if (header[0] != Socks5.VERSION) return null
        val command = header[1]
        val host = when (header[3]) {
            Socks5.ATYP_IPV4 -> (0 until 4).joinToString(".") {
                (readExactly(input, 1)[0].toInt() and 0xFF).toString()
            }
            Socks5.ATYP_IPV6 -> {
                val bytes = readExactly(input, 16)
                (0 until 8).joinToString(":") { "%02x%02x".format(bytes[it * 2], bytes[it * 2 + 1]) }
            }
            Socks5.ATYP_DOMAIN -> {
                val length = readExactly(input, 1)[0].toInt() and 0xFF
                String(readExactly(input, length), StandardCharsets.UTF_8)
            }
            else -> return null
        }
        // A UDP ASSOCIATE request may carry 0.0.0.0:0, meaning "I do not know yet".
        val portBytes = readExactly(input, 2)
        val port = ((portBytes[0].toInt() and 0xFF) shl 8) or (portBytes[1].toInt() and 0xFF)
        return Request(command, host, port)
    }

    /** A CONNECT reply, then the pipe is opaque bytes in both directions. */
    private fun replySuccess(output: OutputStream, request: Request) {
        output.write(
            byteArrayOf(
                Socks5.VERSION, Socks5.REP_SUCCEEDED, Socks5.RESERVED, Socks5.ATYP_IPV4,
                0, 0, 0, 0, 0, 0
            )
        )
        output.flush()
    }

    private fun replyWithEndpoint(output: OutputStream, port: Int) {
        output.write(
            byteArrayOf(
                Socks5.VERSION, Socks5.REP_SUCCEEDED, Socks5.RESERVED, Socks5.ATYP_IPV4,
                127, 0, 0, 1,
                ((port shr 8) and 0xFF).toByte(), (port and 0xFF).toByte()
            )
        )
        output.flush()
    }

    private fun reply(output: OutputStream, code: Byte) {
        runCatching {
            output.write(
                byteArrayOf(Socks5.VERSION, code, Socks5.RESERVED, Socks5.ATYP_IPV4, 0, 0, 0, 0, 0, 0)
            )
            output.flush()
        }
    }

    private fun drainUntilClosed(input: InputStream) {
        val scratch = ByteArray(1024)
        while (running.get()) {
            val n = try {
                input.read(scratch)
            } catch (e: IOException) {
                return
            }
            if (n < 0) return
        }
    }

    private fun relay(client: Socket, tunnel: Socket) {
        val upstreamToClient = Thread({
            runCatching { copy(tunnel.getInputStream(), client.getOutputStream(), bytesDown) }
            runCatching { client.shutdownOutput() }
            runCatching { tunnel.close() }
        }, "socks5-bridge-down")
        upstreamToClient.isDaemon = true
        upstreamToClient.start()

        runCatching { copy(client.getInputStream(), tunnel.getOutputStream(), bytesUp) }
        runCatching { tunnel.shutdownOutput() }
        runCatching { tunnel.close() }
        runCatching { upstreamToClient.join(2_000) }
    }

    private fun copy(from: InputStream, to: OutputStream, counter: AtomicLong) {
        val buffer = ByteArray(BUFFER)
        while (true) {
            val n = try {
                from.read(buffer)
            } catch (e: IOException) {
                return
            }
            if (n < 0) return
            try {
                to.write(buffer, 0, n)
                to.flush()
            } catch (e: IOException) {
                return
            }
            counter.addAndGet(n.toLong())
        }
    }

    // MARK: the upstream hop

    private class UpstreamRefusal(message: String, val replyCode: Byte) : Exception(message)

    /**
     * Opens one HTTP CONNECT tunnel to `host:port` through [upstream].
     *
     * The socket to the proxy is created inside this app's process, so it is
     * excluded from the tunnel and cannot loop back into itself.
     */
    private fun openTunnel(host: String, port: Int): Socket {
        val socket = Socket()
        try {
            socket.tcpNoDelay = true
            socket.connect(InetSocketAddress(upstream.host, upstream.port), connectTimeoutMillis)
            socket.soTimeout = connectTimeoutMillis

            val request = HttpConnect.request(host, port, upstreamCredential)
            socket.getOutputStream().write(request)
            socket.getOutputStream().flush()

            val head = readHttpHead(socket.getInputStream())
            val response = try {
                HttpConnect.parseResponseHead(head)
            } catch (e: Socks5.Socks5Exception) {
                throw UpstreamRefusal(
                    "the proxy did not answer CONNECT with HTTP: ${e.message}",
                    Socks5.REP_GENERAL_FAILURE
                )
            }

            if (!response.isSuccess) {
                val code = when {
                    response.isAuthenticationChallenge -> Socks5.REP_NOT_ALLOWED
                    response.statusCode == 403 -> Socks5.REP_NOT_ALLOWED
                    response.statusCode == 502 || response.statusCode == 503 -> Socks5.REP_HOST_UNREACHABLE
                    else -> Socks5.REP_GENERAL_FAILURE
                }
                val hint = if (response.isAuthenticationChallenge) {
                    " (the proxy rejected the username or password)"
                } else {
                    ""
                }
                throw UpstreamRefusal("the proxy refused $host:$port — ${response.summary}$hint", code)
            }

            socket.soTimeout = 0
            return socket
        } catch (e: UpstreamRefusal) {
            runCatching { socket.close() }
            throw e
        } catch (e: java.net.SocketTimeoutException) {
            runCatching { socket.close() }
            throw UpstreamRefusal(
                "the proxy ${upstream.displayEndpoint} did not answer in time",
                Socks5.REP_HOST_UNREACHABLE
            )
        } catch (e: java.net.ConnectException) {
            runCatching { socket.close() }
            throw UpstreamRefusal(
                "nothing is listening on ${upstream.displayEndpoint}",
                Socks5.REP_HOST_UNREACHABLE
            )
        } catch (e: java.net.UnknownHostException) {
            runCatching { socket.close() }
            throw UpstreamRefusal(
                "the proxy host ${upstream.host} could not be resolved",
                Socks5.REP_HOST_UNREACHABLE
            )
        } catch (e: IOException) {
            runCatching { socket.close() }
            throw UpstreamRefusal(
                "could not reach ${upstream.displayEndpoint}: ${e.message}",
                Socks5.REP_GENERAL_FAILURE
            )
        }
    }

    /** Reads up to and including the blank line that ends a response head. */
    private fun readHttpHead(input: InputStream): ByteArray {
        val buffer = java.io.ByteArrayOutputStream()
        var b = input.read()
        while (b >= 0) {
            buffer.write(b)
            if (buffer.size() > 32 * 1024) {
                throw UpstreamRefusal("the proxy sent 32 KiB without ending its response head", Socks5.REP_GENERAL_FAILURE)
            }
            if (HttpConnect.findHeadTerminator(buffer.toByteArray()) >= 0) break
            b = input.read()
        }
        if (buffer.size() == 0) {
            throw UpstreamRefusal("the proxy closed the connection during the CONNECT handshake", Socks5.REP_GENERAL_FAILURE)
        }
        return buffer.toByteArray()
    }

    // MARK: UDP — DNS only, relayed over TCP

    /**
     * One `UDP ASSOCIATE` socket for the whole bridge.
     *
     * RFC 1928 wants one association per client connection, but the only client here
     * is the engine inside this process, and a single relay socket keeps the DNS
     * connection pool shared. If this bridge is ever exposed beyond loopback, this is
     * the assumption that has to change first.
     */
    private fun udpLoop() {
        val buffer = ByteArray(MAX_DNS_MESSAGE)
        while (running.get()) {
            val packet = DatagramPacket(buffer, buffer.size)
            try {
                udpRelay.receive(packet)
            } catch (e: IOException) {
                return
            }

            val datagram = packet.data.copyOfRange(packet.offset, packet.offset + packet.length)
            val parsed = parseUdpRequest(datagram)
            if (parsed == null) {
                droppedDatagrams.incrementAndGet()
                continue
            }
            if (parsed.port != dnsPort) {
                // No datagram relay exists in HTTP CONNECT. Counting is the honest
                // response; pretending to forward would be worse.
                droppedDatagrams.incrementAndGet()
                continue
            }

            val reply = try {
                dnsOverTcp(parsed.host, parsed.port, parsed.payload)
            } catch (e: Exception) {
                lastError = LogRedactor.redact("DNS over TCP failed: ${e.message}")
                null
            }
            if (reply == null) {
                droppedDatagrams.incrementAndGet()
                continue
            }
            dnsQueries.incrementAndGet()

            val framed = buildUdpReply(parsed.host, parsed.port, reply)
            runCatching {
                udpRelay.send(DatagramPacket(framed, framed.size, packet.address, packet.port))
            }
        }
    }

    private class UdpRequest(val host: String, val port: Int, val payload: ByteArray)

    private fun parseUdpRequest(data: ByteArray): UdpRequest? {
        if (data.size < 4) return null
        if (data[2] != 0.toByte()) return null // fragmented datagrams are not reassembled
        var offset = 4
        val host: String
        when (data[3]) {
            Socks5.ATYP_IPV4 -> {
                if (data.size < offset + 4 + 2) return null
                host = (0 until 4).joinToString(".") { (data[offset + it].toInt() and 0xFF).toString() }
                offset += 4
            }
            Socks5.ATYP_IPV6 -> {
                if (data.size < offset + 16 + 2) return null
                host = (0 until 8).joinToString(":") {
                    "%02x%02x".format(data[offset + it * 2], data[offset + it * 2 + 1])
                }
                offset += 16
            }
            Socks5.ATYP_DOMAIN -> {
                if (data.size < offset + 1) return null
                val length = data[offset].toInt() and 0xFF
                offset += 1
                if (data.size < offset + length + 2) return null
                host = String(data, offset, length, StandardCharsets.UTF_8)
                offset += length
            }
            else -> return null
        }
        val port = ((data[offset].toInt() and 0xFF) shl 8) or (data[offset + 1].toInt() and 0xFF)
        offset += 2
        if (offset >= data.size) return null
        return UdpRequest(host, port, data.copyOfRange(offset, data.size))
    }

    private fun buildUdpReply(host: String, port: Int, payload: ByteArray): ByteArray {
        val address = host.toByteArray(StandardCharsets.UTF_8)
        val out = java.io.ByteArrayOutputStream()
        out.write(byteArrayOf(0, 0, 0, Socks5.ATYP_DOMAIN))
        out.write(address.size)
        out.write(address)
        out.write((port shr 8) and 0xFF)
        out.write(port and 0xFF)
        out.write(payload)
        return out.toByteArray()
    }

    /**
     * Sends one DNS message as DNS-over-TCP through a CONNECT tunnel and returns the
     * answer.
     *
     * The connection is pooled per destination: a fresh CONNECT per query would put
     * three round trips through the proxy in front of every single name lookup, which
     * is the difference between a usable tunnel and an unusable one.
     */
    private fun dnsOverTcp(host: String, port: Int, query: ByteArray): ByteArray? {
        val key = "$host:$port"
        repeat(2) { attempt ->
            val channel = dnsChannels.getOrPut(key) { DnsOverTcpChannel(host, port) }
            try {
                return channel.exchange(query)
            } catch (e: Exception) {
                // A pooled tunnel can be closed by the far end at any time. Drop it and
                // try once with a fresh one; a second failure is a real failure.
                dnsChannels.remove(key)
                channel.close()
                if (attempt == 1) return null
            }
        }
        return null
    }

    /** A single CONNECT tunnel held open for DNS-over-TCP exchanges. */
    private inner class DnsOverTcpChannel(private val host: String, private val port: Int) {
        private val lock = Any()
        private var tunnel: Socket? = null

        fun exchange(query: ByteArray): ByteArray = synchronized(lock) {
            val socket = tunnel?.takeIf { it.isConnected && !it.isClosed } ?: openTunnel(host, port).also {
                // A pooled DNS tunnel that goes quiet must not hold a lookup open
                // forever; the resolver's own retry logic is the backstop.
                it.soTimeout = dnsReadTimeoutMillis
                sockets += it
                tunnel = it
            }

            val framed = byteArrayOf(((query.size shr 8) and 0xFF).toByte(), (query.size and 0xFF).toByte()) + query
            socket.getOutputStream().write(framed)
            socket.getOutputStream().flush()

            val lengthBytes = readExactly(socket.getInputStream(), 2)
            val length = ((lengthBytes[0].toInt() and 0xFF) shl 8) or (lengthBytes[1].toInt() and 0xFF)
            if (length <= 0 || length > MAX_DNS_MESSAGE) {
                throw IOException("DNS-over-TCP reply length $length is out of range")
            }
            readExactly(socket.getInputStream(), length)
        }

        fun close() {
            synchronized(lock) {
                tunnel?.let { sockets -= it; runCatching { it.close() } }
                tunnel = null
            }
        }
    }
}
