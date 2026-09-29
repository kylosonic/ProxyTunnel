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
