package io.github.kylosonic.proxytunnel

import java.io.Closeable
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Loopback test servers, written by hand rather than pulled from a library.
 *
 * They exist so the connectivity test can be exercised against something that
 * really speaks SOCKS5 and really relays bytes, instead of a mock that asserts the
 * code calls the functions it calls. A framing bug in [io.github.kylosonic.proxytunnel.core.Socks5]
 * fails these tests; it would pass a mock.
 */
internal object TestNet {

    const val LOOPBACK = "127.0.0.1"

    fun readExactly(input: InputStream, count: Int): ByteArray {
        val buffer = ByteArray(count)
        var read = 0
        while (read < count) {
            val n = input.read(buffer, read, count - read)
            if (n < 0) throw IllegalStateException("peer closed after $read of $count bytes")
            read += n
        }
        return buffer
    }

    fun readHead(input: InputStream, limit: Int = 16 * 1024): String {
        val out = java.io.ByteArrayOutputStream()
        while (out.size() < limit) {
            val b = input.read()
            if (b < 0) break
            out.write(b)
            val text = out.toString("ISO-8859-1")
            if (text.endsWith("\r\n\r\n") || text.endsWith("\n\n")) break
        }
        return out.toString("ISO-8859-1")
    }

    fun pipe(from: InputStream, to: OutputStream) {
        val buffer = ByteArray(8192)
        while (true) {
            val n = try {
                from.read(buffer)
            } catch (e: Exception) {
                break
            }
            if (n < 0) break
            try {
                to.write(buffer, 0, n)
                to.flush()
            } catch (e: Exception) {
                break
            }
        }
        runCatching { to.close() }
    }

    fun daemonPool() = Executors.newCachedThreadPool { runnable ->
        Thread(runnable).apply { isDaemon = true }
    }

    /** A port nothing is listening on, for the "connection refused" path. */
    fun closedPort(): Int {
        val socket = ServerSocket(0, 1, InetAddress.getByName(LOOPBACK))
        val port = socket.localPort
        socket.close()
        return port
    }
}

/** A one-request HTTP origin, standing in for `api.ipify.org`. */
internal class FakeOrigin(private val body: String) : Closeable {

    private val listener = ServerSocket(0, 20, InetAddress.getByName(TestNet.LOOPBACK))
    private val pool = TestNet.daemonPool()
    private val closed = AtomicBoolean(false)

    val port: Int get() = listener.localPort

    @Volatile
    var lastRequestLine: String? = null

    init {
        pool.submit {
            while (!closed.get()) {
                val socket = try {
                    listener.accept()
                } catch (e: Exception) {
                    break
                }
                pool.submit { serve(socket) }
            }
        }
    }

    private fun serve(socket: Socket) {
        socket.use {
            val head = TestNet.readHead(it.getInputStream())
            lastRequestLine = head.lineSequence().firstOrNull()
            val bytes = body.toByteArray(StandardCharsets.UTF_8)
            val response = "HTTP/1.1 200 OK\r\n" +
                "Content-Type: text/plain\r\n" +
                "Content-Length: ${bytes.size}\r\n" +
                "Connection: close\r\n\r\n"
            it.getOutputStream().write(response.toByteArray(StandardCharsets.ISO_8859_1))
            it.getOutputStream().write(bytes)
            it.getOutputStream().flush()
        }
    }

    override fun close() {
        closed.set(true)
        runCatching { listener.close() }
        pool.shutdownNow()
    }
}

/**
 * A real SOCKS5 server: full handshake, optional RFC 1929 auth, and a byte relay to
 * whatever destination the client asked for.
 */
internal class FakeSocks5Proxy(
    private val username: String? = null,
    private val password: String? = null,
    private val forcedReplyCode: Byte = 0
) : Closeable {

    private val listener = ServerSocket(0, 20, InetAddress.getByName(TestNet.LOOPBACK))
    private val pool = TestNet.daemonPool()
    private val closed = AtomicBoolean(false)

    val port: Int get() = listener.localPort

    @Volatile var lastTarget: String? = null
    @Volatile var sawUsername: String? = null
    @Volatile var sawPassword: String? = null
    @Volatile var offeredMethods: List<Byte> = emptyList()

    init {
        pool.submit {
            while (!closed.get()) {
                val socket = try {
                    listener.accept()
                } catch (e: Exception) {
                    break
                }
                pool.submit { handle(socket) }
            }
        }
    }

    private fun handle(socket: Socket) {
        socket.use { client ->
            client.tcpNoDelay = true
            val input = client.getInputStream()
            val output = client.getOutputStream()

            // Greeting.
            val greeting = TestNet.readExactly(input, 2)
            check(greeting[0].toInt() == 5) { "client did not speak SOCKS5 (got ${greeting[0]})" }
            offeredMethods = TestNet.readExactly(input, greeting[1].toInt() and 0xFF).toList()

            if (username != null) {
                if (2.toByte() !in offeredMethods) {
                    output.write(byteArrayOf(5, 0xFF.toByte()))
                    output.flush()
                    return
                }
                output.write(byteArrayOf(5, 2))
                output.flush()

                val authHead = TestNet.readExactly(input, 2)
                check(authHead[0].toInt() == 1) { "expected RFC 1929 auth version 1" }
                val user = String(
                    TestNet.readExactly(input, authHead[1].toInt() and 0xFF),
                    StandardCharsets.UTF_8
                )
                val passLength = TestNet.readExactly(input, 1)[0].toInt() and 0xFF
                val pass = String(TestNet.readExactly(input, passLength), StandardCharsets.UTF_8)
                sawUsername = user
                sawPassword = pass

                val accepted = user == username && pass == password
                output.write(byteArrayOf(1, if (accepted) 0 else 1))
                output.flush()
                if (!accepted) return
            } else {
                if (0.toByte() !in offeredMethods) {
                    output.write(byteArrayOf(5, 0xFF.toByte()))
                    output.flush()
                    return
                }
                output.write(byteArrayOf(5, 0))
                output.flush()
            }

            // Request.
            val header = TestNet.readExactly(input, 4)
            check(header[0].toInt() == 5) { "request version was ${header[0]}" }
            val host = when (header[3].toInt()) {
                1 -> (0 until 4).joinToString(".") {
                    (TestNet.readExactly(input, 1)[0].toInt() and 0xFF).toString()
                }
                3 -> {
                    val length = TestNet.readExactly(input, 1)[0].toInt() and 0xFF
                    String(TestNet.readExactly(input, length), StandardCharsets.UTF_8)
                }
                4 -> {
                    val bytes = TestNet.readExactly(input, 16)
                    (0 until 8).joinToString(":") {
                        "%02x%02x".format(bytes[it * 2], bytes[it * 2 + 1])
                    }
                }
                else -> {
                    output.write(byteArrayOf(5, 8, 0, 1, 0, 0, 0, 0, 0, 0))
                    output.flush()
                    return
                }
            }
            val portBytes = TestNet.readExactly(input, 2)
            val targetPort = ((portBytes[0].toInt() and 0xFF) shl 8) or (portBytes[1].toInt() and 0xFF)
            lastTarget = "$host:$targetPort"

            if (forcedReplyCode.toInt() != 0) {
                output.write(byteArrayOf(5, forcedReplyCode, 0, 1, 0, 0, 0, 0, 0, 0))
                output.flush()
                return
            }

            val upstream = Socket()
            try {
                upstream.tcpNoDelay = true
                upstream.connect(InetSocketAddress(host, targetPort), 3_000)
            } catch (e: Exception) {
                output.write(byteArrayOf(5, 5, 0, 1, 0, 0, 0, 0, 0, 0))
                output.flush()
                runCatching { upstream.close() }
                return
            }

            output.write(byteArrayOf(5, 0, 0, 1, 127, 0, 0, 1, 0, 0))
            output.flush()

            Thread { TestNet.pipe(upstream.getInputStream(), output) }.apply { isDaemon = true }.start()
            TestNet.pipe(input, upstream.getOutputStream())
            runCatching { upstream.close() }
        }
    }

    override fun close() {
        closed.set(true)
        runCatching { listener.close() }
        pool.shutdownNow()
    }
}

/** A forward proxy that understands CONNECT, with a configurable answer. */
internal class FakeHttpProxy(private val statusLine: String) : Closeable {
    private val listener = ServerSocket(0, 20, InetAddress.getByName(TestNet.LOOPBACK))
    private val pool = TestNet.daemonPool()
    private val closed = AtomicBoolean(false)

    val port: Int get() = listener.localPort

    @Volatile var lastHead: String? = null

    /** How many CONNECT tunnels were opened. Used to prove DNS tunnels are pooled. */
    val connectCount = java.util.concurrent.atomic.AtomicInteger()

    init {
        pool.submit {
            while (!closed.get()) {
                val socket = try {
                    listener.accept()
                } catch (e: Exception) {
                    break
                }
                pool.submit { handle(socket) }
            }
        }
    }

    private fun handle(socket: Socket) {
        socket.use { client ->
            val head = TestNet.readHead(client.getInputStream())
            lastHead = head
            connectCount.incrementAndGet()
            val output = client.getOutputStream()

            if (!statusLine.contains(" 200")) {
                val extra = if (statusLine.contains(" 407")) {
                    "Proxy-Authenticate: Basic realm=\"proxy\"\r\n"
                } else {
                    ""
                }
                output.write("$statusLine\r\n$extra\r\n".toByteArray(StandardCharsets.ISO_8859_1))
                output.flush()
                return
            }

            val authority = head.lineSequence().firstOrNull()
                ?.removePrefix("CONNECT ")?.substringBefore(' ') ?: return
            val host = authority.substringBeforeLast(':')
            val port = authority.substringAfterLast(':').toIntOrNull() ?: return

            val upstream = Socket()
            try {
                upstream.connect(InetSocketAddress(host, port), 3_000)
            } catch (e: Exception) {
                output.write("HTTP/1.1 502 Bad Gateway\r\n\r\n".toByteArray(StandardCharsets.ISO_8859_1))
                output.flush()
                return
            }

            output.write("$statusLine\r\n\r\n".toByteArray(StandardCharsets.ISO_8859_1))
            output.flush()

            Thread { TestNet.pipe(upstream.getInputStream(), output) }.apply { isDaemon = true }.start()
            TestNet.pipe(client.getInputStream(), upstream.getOutputStream())
            runCatching { upstream.close() }
        }
    }

    override fun close() {
        closed.set(true)
        runCatching { listener.close() }
        pool.shutdownNow()
    }
}

/**
 * A DNS server reachable only over TCP, speaking the RFC 7766 two-byte length prefix.
 *
 * It exists to prove the bridge's UDP path: a SOCKS5 `UDP ASSOCIATE` datagram goes in,
 * and the answer has to come back out having travelled as DNS-over-TCP through an HTTP
 * CONNECT tunnel. A UDP DNS server would not exercise any of that.
 *
 * It answers every query with a fixed A record, so the test asserts on bytes rather
 * than on a resolver's behaviour.
 */
internal class FakeDnsOverTcpServer(private val answerIP: String = "203.0.113.9") : Closeable {

    private val listener = ServerSocket(0, 20, InetAddress.getByName(TestNet.LOOPBACK))
    private val pool = TestNet.daemonPool()
    private val closed = AtomicBoolean(false)

    val port: Int get() = listener.localPort

    /** Every question this server was asked, as raw bytes. */
    val queries: MutableList<ByteArray> = java.util.Collections.synchronizedList(mutableListOf())

    /** Set to refuse the connection, for the failure path. */
    @Volatile
    var refuseConnections = false

    init {
        pool.submit {
            while (!closed.get()) {
                val socket = try {
                    listener.accept()
                } catch (e: Exception) {
                    break
                }
                pool.submit { serve(socket) }
            }
        }
    }

    private fun serve(socket: Socket) {
        socket.use {
            try {
                it.tcpNoDelay = true
                val input = it.getInputStream()
                val output = it.getOutputStream()
                while (true) {
                    val lengthBytes = TestNet.readExactly(input, 2)
                    val length = ((lengthBytes[0].toInt() and 0xFF) shl 8) or (lengthBytes[1].toInt() and 0xFF)
                    if (length == 0) return
                    val query = TestNet.readExactly(input, length)
                    queries += query

                    val response = buildResponse(query)
                    output.write(byteArrayOf(((response.size shr 8) and 0xFF).toByte(), (response.size and 0xFF).toByte()))
                    output.write(response)
                    output.flush()
                }
            } catch (e: Exception) {
                // The peer closed, or the test is tearing down.
            }
        }
    }

    /**
     * A minimal but structurally valid DNS response: it echoes the question section
     * from the query and answers with one A record, so a real parser would accept it.
     */
    private fun buildResponse(query: ByteArray): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        val id = if (query.size >= 2) byteArrayOf(query[0], query[1]) else byteArrayOf(0, 0)
        out.write(id)
        out.write(byteArrayOf(0x81.toByte(), 0x80.toByte())) // response, recursion available
        out.write(byteArrayOf(0, 1))                          // QDCOUNT
        out.write(byteArrayOf(0, 1))                          // ANCOUNT
        out.write(byteArrayOf(0, 0))                          // NSCOUNT
        out.write(byteArrayOf(0, 0))                          // ARCOUNT

        // Copy the question section verbatim: QNAME ... QTYPE QCLASS.
        var offset = 12
        while (offset < query.size) {
            out.write(query[offset].toInt())
            if (query[offset].toInt() == 0) {
                offset++
                break
            }
            offset += (query[offset].toInt() and 0xFF) + 1
        }
        if (offset + 3 < query.size) {
            out.write(query, offset, 4)
        } else {
            out.write(byteArrayOf(0, 1, 0, 1))
        }

        // Answer: a compression pointer to the question name, type A, class IN, TTL 60.
        out.write(byteArrayOf(0xC0.toByte(), 0x0C))
        out.write(byteArrayOf(0, 1))       // TYPE A
        out.write(byteArrayOf(0, 1))       // CLASS IN
        out.write(byteArrayOf(0, 0, 0, 60)) // TTL
        out.write(byteArrayOf(0, 4))       // RDLENGTH
        answerIP.split(".").forEach { out.write(it.toInt()) }
        return out.toByteArray()
    }

    override fun close() {
        closed.set(true)
        runCatching { listener.close() }
        pool.shutdownNow()
    }
}
/**
 * A stand-in for a proxy provider's REST API.
 *
 * Deliberately a real HTTP server on loopback rather than a mock of the client: the
 * thing worth testing is that the app builds the right request — path, query, auth
 * header — and parses the documented response, and a mock would test neither.
 */
internal class FakeProviderServer(
    private val handler: (target: String, authorization: String?) -> Pair<Int, String>
) : Closeable {

    private val listener = ServerSocket(0, 20, InetAddress.getByName(TestNet.LOOPBACK))
    private val pool = TestNet.daemonPool()
    private val closed = AtomicBoolean(false)

    val port: Int get() = listener.localPort
    val baseUrl: String get() = "http://${TestNet.LOOPBACK}:$port/api/v2"

    val requests = java.util.Collections.synchronizedList(mutableListOf<String>())

    @Volatile var lastAuthorization: String? = null

    init {
        pool.submit {
            while (!closed.get()) {
                val socket = try {
                    listener.accept()
                } catch (e: Exception) {
                    break
                }
                pool.submit { serve(socket) }
            }
        }
    }

    private fun serve(socket: Socket) {
        socket.use {
            try {
                val head = TestNet.readHead(it.getInputStream())
                val lines = head.replace("\r\n", "\n").split("\n")
                val requestLine = lines.firstOrNull().orEmpty()
                val target = requestLine.split(" ").getOrNull(1).orEmpty()
                val authorization = lines.drop(1)
                    .firstOrNull { it.lowercase().startsWith("authorization:") }
                    ?.substringAfter(":")
                    ?.trim()

                requests += target
                lastAuthorization = authorization

                val (status, body) = handler(target, authorization)
                val bytes = body.toByteArray(StandardCharsets.UTF_8)
                val reason = when (status) {
                    200 -> "OK"
                    302 -> "Found"
                    401 -> "Unauthorized"
                    403 -> "Forbidden"
                    429 -> "Too Many Requests"
                    else -> "Status"
                }
                val extra = if (status == 302) "Location: https://elsewhere.example.com/steal\r\n" else ""
                it.getOutputStream().write(
                    (
                        "HTTP/1.1 $status $reason\r\n" +
                            "Content-Type: application/json\r\n" +
                            "Content-Length: ${bytes.size}\r\n" +
                            extra +
                            "Connection: close\r\n\r\n"
                        ).toByteArray(StandardCharsets.ISO_8859_1)
                )
                it.getOutputStream().write(bytes)
                it.getOutputStream().flush()
            } catch (e: Exception) {
                // The client hung up; nothing to report.
            }
        }
    }

    override fun close() {
        closed.set(true)
        runCatching { listener.close() }
        pool.shutdownNow()
    }
}