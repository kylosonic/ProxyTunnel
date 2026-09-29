package io.github.kylosonic.proxytunnel

import io.github.kylosonic.proxytunnel.core.ProxyCredential
import io.github.kylosonic.proxytunnel.core.ProxyProfile
import io.github.kylosonic.proxytunnel.core.ProxyProtocol
import io.github.kylosonic.proxytunnel.core.ProxyProbe
import io.github.kylosonic.proxytunnel.core.Socks5
import io.github.kylosonic.proxytunnel.core.Socks5Bridge
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.Closeable
import java.io.InputStream
import java.io.OutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket

/**
 * Tests for the SOCKS5-to-HTTP-CONNECT bridge.
 *
 * The bridge is what makes a proxy sold as "HTTP" usable behind the tunnel, so these
 * are end-to-end tests wherever they can be: a real HTTP CONNECT proxy relays to a
 * real origin, and the bridge is driven by the same SOCKS5 client code the app ships.
 * A mock would have proved that the bridge calls its own methods, which is not the
 * thing that can break.
 */
class Socks5BridgeTest {

    private val egress = "203.0.113.9"

    private fun upstreamProfile(port: Int, username: String? = null) = ProxyProfile(
        id = "upstream",
        name = "HTTP upstream",
        host = TestNet.LOOPBACK,
        port = port,
        protocol = ProxyProtocol.HTTP_CONNECT,
        username = username
    )

    /** The engine's view of the bridge: a plain SOCKS5 proxy on loopback. */
    private fun bridgeAsEngineSeesIt(port: Int) = ProxyProfile(
        id = "bridge",
        name = "bridge",
        host = TestNet.LOOPBACK,
        port = port,
        protocol = ProxyProtocol.SOCKS5
    )

    private fun configuration(originPort: Int) = ProxyProbe.Configuration(
        checkHost = TestNet.LOOPBACK,
        checkPort = originPort,
        timeoutMillis = 5_000,
        resolvedAddresses = listOf(TestNet.LOOPBACK)
    )

    // MARK: TCP

    @Test
    fun `tcp is relayed end to end through an http connect upstream`() {
        FakeOrigin(egress).use { origin ->
            FakeHttpProxy("HTTP/1.1 200 Connection established").use { proxy ->
                Socks5Bridge(upstreamProfile(proxy.port), null).use { bridge ->
                    bridge.start()

                    // The app's own probe — and the app's own SOCKS5 client — against the
                    // bridge. If the bridge's framing is wrong, this cannot pass.
                    val report = ProxyProbe.run(
                        bridgeAsEngineSeesIt(bridge.port),
                        null,
                        configuration(origin.port)
                    )

                    assertTrue(report.failureMessage ?: "", report.isSuccess)
                    assertEquals(200, report.httpStatus)
                    assertEquals(egress, report.egressIP)
                    assertTrue(report.summaryLines.any { it.contains("SOCKS5 CONNECT") })

                    // And it really did leave through the HTTP proxy.
                    assertEquals(1, proxy.connectCount.get())
                    assertTrue(
                        proxy.lastHead!!.startsWith("CONNECT ${TestNet.LOOPBACK}:${origin.port} HTTP/1.1")
                    )
                }
            }
        }
    }

    @Test
    fun `upstream credentials are passed on as basic auth`() {
        FakeOrigin(egress).use { origin ->
            FakeHttpProxy("HTTP/1.1 200 Connection established").use { proxy ->
                val upstream = upstreamProfile(proxy.port, username = "alice")
                Socks5Bridge(upstream, ProxyCredential("alice", "hunter2")).use { bridge ->
                    bridge.start()

                    val report = ProxyProbe.run(
                        bridgeAsEngineSeesIt(bridge.port), null, configuration(origin.port)
                    )

                    assertTrue(report.failureMessage ?: "", report.isSuccess)
                    // base64("alice:hunter2")
                    assertTrue(proxy.lastHead!!.contains("Proxy-Authorization: Basic YWxpY2U6aHVudGVyMg=="))
                }
            }
        }
    }

    @Test
    fun `an upstream 502 becomes host unreachable for the engine`() {
        FakeHttpProxy("HTTP/1.1 502 Bad Gateway").use { proxy ->
            Socks5Bridge(upstreamProfile(proxy.port), null).use { bridge ->
                bridge.start()
                BridgeClient(bridge.port).use { client ->
                    assertEquals(Socks5.METHOD_NONE, client.greet())
                    assertEquals(
                        Socks5.REP_HOST_UNREACHABLE.toInt(),
                        client.connect(TestNet.LOOPBACK, 9)
                    )
                }
                assertEquals(1, bridge.stats.refusedConnections)
                assertTrue(bridge.stats.lastError!!.contains("502"))
            }
        }
    }

    @Test
    fun `an upstream 407 becomes not allowed, and the password stays out of the message`() {
        FakeHttpProxy("HTTP/1.1 407 Proxy Authentication Required").use { proxy ->
            val upstream = upstreamProfile(proxy.port, username = "alice")
            Socks5Bridge(upstream, ProxyCredential("alice", "hunter2")).use { bridge ->
                bridge.start()
                BridgeClient(bridge.port).use { client ->
                    client.greet()
                    assertEquals(Socks5.REP_NOT_ALLOWED.toInt(), client.connect(TestNet.LOOPBACK, 9))
                }
                val message = bridge.stats.lastError!!
                assertTrue(message, message.contains("407"))
                assertTrue(message, message.lowercase().contains("authentication"))
                assertTrue(message, message.lowercase().contains("password"))
                assertFalse(message, message.contains("hunter2"))
            }
        }
    }

    @Test
    fun `an upstream that is not listening becomes host unreachable`() {
        Socks5Bridge(upstreamProfile(TestNet.closedPort()), null).use { bridge ->
            bridge.start()
            BridgeClient(bridge.port).use { client ->
                client.greet()
                assertEquals(Socks5.REP_HOST_UNREACHABLE.toInt(), client.connect(TestNet.LOOPBACK, 9))
            }
            assertTrue(bridge.stats.refusedConnections >= 1)
        }
    }

    @Test
    fun `a server that does not speak socks5 is rejected`() {
        // An HTTP origin answers a SOCKS5 greeting with an HTTP error page.
        FakeOrigin(egress).use { origin ->
            Socks5Bridge(upstreamProfile(TestNet.closedPort()), null).use { bridge ->
                bridge.start()
                Socket(TestNet.LOOPBACK, bridge.port).use { raw ->
                    raw.soTimeout = 3_000
                    raw.getOutputStream().write(byteArrayOf(0x04, 0x01, 0x00))
                    raw.getOutputStream().flush()
                    assertEquals(-1, raw.getInputStream().read())
                }
            }
        }
    }

    @Test
    fun `a client offering only username password auth gets no acceptable method`() {
        Socks5Bridge(upstreamProfile(TestNet.closedPort()), null).use { bridge ->
            bridge.start()
            BridgeClient(bridge.port).use { client ->
                assertEquals(
                    Socks5.METHOD_NO_ACCEPTABLE.toInt(),
                    client.greet(methods = listOf(Socks5.METHOD_USER_PASSWORD)).toInt()
                )
            }
        }
    }

    @Test
    fun `bind is refused as a command this bridge does not implement`() {
        Socks5Bridge(upstreamProfile(TestNet.closedPort()), null).use { bridge ->
            bridge.start()
            BridgeClient(bridge.port).use { client ->
                client.greet()
                // CMD 0x02 is BIND, which RFC 1928 defines and nothing uses.
                assertEquals(Socks5.REP_COMMAND_NOT_SUPPORTED.toInt(), client.command(0x02, TestNet.LOOPBACK, 9))
            }
        }
    }

    @Test
    fun `an unknown address type is refused`() {
        Socks5Bridge(upstreamProfile(TestNet.closedPort()), null).use { bridge ->
            bridge.start()
            BridgeClient(bridge.port).use { client ->
                client.greet()
                assertEquals(Socks5.REP_COMMAND_NOT_SUPPORTED.toInt(), client.rawRequest(command = 0x01, atyp = 0x09))
            }
        }
    }

    @Test
    fun `byte counters reflect what was relayed`() {
        FakeOrigin(egress).use { origin ->
            FakeHttpProxy("HTTP/1.1 200 Connection established").use { proxy ->
                Socks5Bridge(upstreamProfile(proxy.port), null).use { bridge ->
                    bridge.start()
                    ProxyProbe.run(bridgeAsEngineSeesIt(bridge.port), null, configuration(origin.port))

                    val stats = bridge.stats
                    assertEquals(1, stats.tcpConnections)
                    assertTrue("up=${stats.bytesUp}", stats.bytesUp > 0)
                    assertTrue("down=${stats.bytesDown}", stats.bytesDown > 0)
                    // The handler thread decrements this after the client sees EOF, so
                    // wait for it rather than racing it.
                    val settled = waitFor(2_000) { bridge.stats.activeConnections == 0 }
                    assertTrue("activeConnections stayed at ${bridge.stats.activeConnections}", settled)
                }
            }
        }
    }

    // MARK: UDP — DNS over TCP

    @Test
    fun `udp associate hands back a loopback relay endpoint`() {
        Socks5Bridge(upstreamProfile(TestNet.closedPort()), null).use { bridge ->
            bridge.start()
            BridgeClient(bridge.port).use { client ->
                client.greet()
                val (host, port) = client.udpAssociate()
                assertEquals(TestNet.LOOPBACK, host)
                assertTrue("relay port $port", port in 1..65535)
            }
        }
    }

    @Test
    fun `a dns query travels as dns over tcp through the connect tunnel`() {
        FakeDnsOverTcpServer(egress).use { dns ->
            FakeHttpProxy("HTTP/1.1 200 Connection established").use { proxy ->
                // dns.port stands in for 53: a CI runner cannot bind a privileged port.
                Socks5Bridge(upstreamProfile(proxy.port), null, dnsPort = dns.port).use { bridge ->
                    bridge.start()

                    BridgeClient(bridge.port).use { client ->
                        client.greet()
                        val (relayHost, relayPort) = client.udpAssociate()

                        val query = dnsQueryBytes("example.com")
                        val reply = client.sendUdp(relayHost, relayPort, TestNet.LOOPBACK, dns.port, query)

                        assertNotNull("no UDP reply arrived", reply)
                        // The answer came back through the CONNECT tunnel, so the fake
                        // proxy must have opened a tunnel to the DNS server.
                        assertEquals(1, proxy.connectCount.get())
                        assertTrue(proxy.lastHead!!.startsWith("CONNECT ${TestNet.LOOPBACK}:${dns.port}"))
                        assertEquals(1, dns.queries.size)

                        // The reply is a SOCKS5 UDP datagram wrapping the DNS answer.
                        assertEquals(0, reply!![2].toInt())
                        val inner = stripUdpHeader(reply)
                        assertNotNull(inner)
                        assertArrayEquals(query.copyOfRange(0, 2), inner!!.copyOfRange(0, 2))
                        // RCODE 0 in the low nibble of the flags' second byte: NOERROR.
                        assertEquals(0, inner[3].toInt() and 0x0F)
                        // One answer, and it is the address the fake server was told to give.
                        assertEquals(1, ((inner[6].toInt() and 0xFF) shl 8) or (inner[7].toInt() and 0xFF))
                        assertTrue(inner.takeLast(4).toByteArray().contentEquals(byteArrayOf(203.toByte(), 0, 113, 9)))
                    }

                    assertEquals(1, bridge.stats.dnsQueries)
                    assertEquals(0, bridge.stats.droppedDatagrams)
                }
            }
        }
    }

    @Test
    fun `two dns queries reuse one tunnel instead of paying for a connect each time`() {
        FakeDnsOverTcpServer(egress).use { dns ->
            FakeHttpProxy("HTTP/1.1 200 Connection established").use { proxy ->
                Socks5Bridge(upstreamProfile(proxy.port), null, dnsPort = dns.port).use { bridge ->
                    bridge.start()
                    BridgeClient(bridge.port).use { client ->
                        client.greet()
                        val (relayHost, relayPort) = client.udpAssociate()

                        repeat(3) { index ->
                            val reply = client.sendUdp(
                                relayHost, relayPort, TestNet.LOOPBACK, dns.port,
                                dnsQueryBytes("host$index.example.com")
                            )
                            assertNotNull("query $index got no reply", reply)
                        }
                    }
                    assertEquals(3, bridge.stats.dnsQueries)
                    // This is the assertion that matters: three lookups, one CONNECT.
                    // A fresh tunnel per query would put three round trips through the
                    // proxy in front of every name resolution.
                    assertEquals(1, proxy.connectCount.get())
                }
            }
        }
    }

    @Test
    fun `non dns udp is dropped and counted rather than silently forwarded`() {
        FakeDnsOverTcpServer(egress).use { dns ->
            FakeHttpProxy("HTTP/1.1 200 Connection established").use { proxy ->
                Socks5Bridge(upstreamProfile(proxy.port), null, dnsPort = dns.port).use { bridge ->
                    bridge.start()
                    BridgeClient(bridge.port).use { client ->
                        client.greet()
                        val (relayHost, relayPort) = client.udpAssociate()

                        // Port 443 UDP is QUIC, which HTTP CONNECT cannot carry.
                        val reply = client.sendUdp(
                            relayHost, relayPort, TestNet.LOOPBACK, 443, byteArrayOf(1, 2, 3, 4),
                            timeoutMillis = 1_200
                        )

                        assertEquals(null, reply)
                    }
                    assertEquals(1, bridge.stats.droppedDatagrams)
                    assertEquals(0, bridge.stats.dnsQueries)
                    assertEquals(0, proxy.connectCount.get())
                }
            }
        }
    }

    @Test
    fun `a fragmented udp datagram is dropped instead of misparsed`() {
        FakeHttpProxy("HTTP/1.1 200 Connection established").use { proxy ->
            Socks5Bridge(upstreamProfile(proxy.port), null).use { bridge ->
                bridge.start()
                BridgeClient(bridge.port).use { client ->
                    client.greet()
                    val (relayHost, relayPort) = client.udpAssociate()

                    val fragmented = byteArrayOf(0, 0, 0x01, 0x01, 127, 0, 0, 1, 0, 53, 9, 9)
                    val reply = client.sendUdpRaw(relayHost, relayPort, fragmented, timeoutMillis = 1_200)

                    assertEquals(null, reply)
                }
                assertEquals(1, bridge.stats.droppedDatagrams)
            }
        }
    }

    @Test
    fun `a dns server that is down is counted rather than reported as an answer`() {
        // Nothing is listening on this port, so the CONNECT tunnel is refused.
        FakeHttpProxy("HTTP/1.1 502 Bad Gateway").use { proxy ->
            Socks5Bridge(upstreamProfile(proxy.port), null, dnsPort = 53).use { bridge ->
                bridge.start()
                BridgeClient(bridge.port).use { client ->
                    client.greet()
                    val (relayHost, relayPort) = client.udpAssociate()
                    val reply = client.sendUdp(
                        relayHost, relayPort, TestNet.LOOPBACK, 53, dnsQueryBytes("example.com"),
                        timeoutMillis = 1_500
                    )
                    assertEquals(null, reply)
                }
                assertEquals(0, bridge.stats.dnsQueries)
                assertEquals(1, bridge.stats.droppedDatagrams)
            }
        }
    }

    // MARK: lifecycle

    @Test
    fun `closing the bridge releases the port`() {
        val bridge = Socks5Bridge(upstreamProfile(TestNet.closedPort()), null)
        val port = bridge.start()
        assertTrue(port > 0)
        bridge.close()
        // The port must be immediately reusable, or restarting the tunnel leaks sockets.
        java.net.ServerSocket(port, 1, InetAddress.getByName(TestNet.LOOPBACK)).use { reclaimed ->
            assertEquals(port, reclaimed.localPort)
        }
    }

    @Test
    fun `starting twice returns the same port and does not fork a second listener`() {
        Socks5Bridge(upstreamProfile(TestNet.closedPort()), null).use { bridge ->
            val first = bridge.start()
            val second = bridge.start()
            assertEquals(first, second)
        }
    }

    @Test
    fun `the bridge advertises which upstreams it can carry`() {
        val socks = ProxyProfile("1", "s", "h", 1080, ProxyProtocol.SOCKS5)
        val http = ProxyProfile("2", "h", "h", 8080, ProxyProtocol.HTTP_CONNECT)
        val https = ProxyProfile("3", "t", "h", 443, ProxyProtocol.HTTPS_CONNECT)

        assertTrue(Socks5Bridge.supports(socks))
        assertTrue(Socks5Bridge.supports(http))
        // TLS to the proxy is deliberately not implemented, so it is refused up front
        // rather than half-supported.
        assertFalse(Socks5Bridge.supports(https))
        assertFalse(http.needsBridge.not())
        assertTrue(http.needsBridge)
        assertFalse(socks.needsBridge)
    }

    // MARK: helpers

    /** Polls [condition] until it holds or [timeoutMillis] elapses. */
    private fun waitFor(timeoutMillis: Long, condition: () -> Boolean): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (System.currentTimeMillis() < deadline) {
            if (condition()) return true
            Thread.sleep(20)
        }
        return condition()
    }

    /** A hand-written SOCKS5 client, so the tests do not verify the bridge with itself. */
    private class BridgeClient(port: Int) : Closeable {        private val socket = Socket().apply {
            tcpNoDelay = true
            connect(InetSocketAddress(TestNet.LOOPBACK, port), 3_000)
            soTimeout = 5_000
        }
        private val input: InputStream = socket.getInputStream()
        private val output: OutputStream = socket.getOutputStream()

        fun greet(methods: List<Byte> = listOf(Socks5.METHOD_NONE)): Byte {
            output.write(byteArrayOf(Socks5.VERSION, methods.size.toByte()))
            output.write(methods.toByteArray())
            output.flush()
            return TestNet.readExactly(input, 2)[1]
        }

        fun connect(host: String, port: Int): Int = command(Socks5.CMD_CONNECT, host, port)

        fun command(command: Byte, host: String, port: Int): Int {
            output.write(Socks5.request(command, host, port))
            output.flush()
            return TestNet.readExactly(input, 2)[1].toInt() and 0xFF
        }

        /** Sends a request with a hand-picked ATYP, for the malformed-input tests. */
        fun rawRequest(command: Byte, atyp: Byte): Int {
            output.write(byteArrayOf(Socks5.VERSION, command, Socks5.RESERVED, atyp, 0, 0, 0, 0, 0, 0))
            output.flush()
            return TestNet.readExactly(input, 2)[1].toInt() and 0xFF
        }

        fun udpAssociate(): Pair<String, Int> {
            val reply = command(Socks5.CMD_UDP_ASSOCIATE, "0.0.0.0", 0)
            if (reply != 0) throw AssertionError("UDP ASSOCIATE refused: ${Socks5.replyName(reply)}")
            // command() consumed VER and REP. What remains is RSV, ATYP, BND.ADDR, BND.PORT.
            val header = TestNet.readExactly(input, 2)
            val host: String = when (header[1]) {
                Socks5.ATYP_IPV4 -> {
                    val bytes = TestNet.readExactly(input, 4)
                    bytes.joinToString(".") { (it.toInt() and 0xFF).toString() }
                }
                Socks5.ATYP_IPV6 -> {
                    val bytes = TestNet.readExactly(input, 16)
                    (0 until 8).joinToString(":") { "%02x%02x".format(bytes[it * 2], bytes[it * 2 + 1]) }
                }
                else -> {
                    val length = TestNet.readExactly(input, 1)[0].toInt() and 0xFF
                    String(TestNet.readExactly(input, length), Charsets.UTF_8)
                }
            }
            val portBytes = TestNet.readExactly(input, 2)
            return host to (((portBytes[0].toInt() and 0xFF) shl 8) or (portBytes[1].toInt() and 0xFF))
        }

        fun sendUdp(
            relayHost: String,
            relayPort: Int,
            destinationHost: String,
            destinationPort: Int,
            payload: ByteArray,
            timeoutMillis: Int = 2_000
        ): ByteArray? {
            val request = java.io.ByteArrayOutputStream()
            val address = destinationHost.toByteArray(Charsets.UTF_8)
            request.write(byteArrayOf(0, 0, 0, Socks5.ATYP_DOMAIN))
            request.write(address.size)
            request.write(address)
            request.write((destinationPort shr 8) and 0xFF)
            request.write(destinationPort and 0xFF)
            request.write(payload)
            return sendUdpRaw(relayHost, relayPort, request.toByteArray(), timeoutMillis)
        }

        fun sendUdpRaw(
            relayHost: String,
            relayPort: Int,
            datagram: ByteArray,
            timeoutMillis: Int = 2_000
        ): ByteArray? = DatagramSocket().use { udp ->
            udp.soTimeout = timeoutMillis
            udp.send(
                DatagramPacket(
                    datagram, datagram.size,
                    InetAddress.getByName(relayHost), relayPort
                )
            )
            val buffer = ByteArray(65_535)
            val packet = DatagramPacket(buffer, buffer.size)
            try {
                udp.receive(packet)
            } catch (e: java.net.SocketTimeoutException) {
                return null
            }
            buffer.copyOfRange(packet.offset, packet.offset + packet.length)
        }

        override fun close() {
            runCatching { socket.close() }
        }
    }

    /** Strips RSV/FRAG/ATYP/ADDR/PORT from a SOCKS5 UDP reply, returning the payload. */
    private fun stripUdpHeader(datagram: ByteArray): ByteArray? {
        if (datagram.size < 4) return null
        var offset = 4
        when (datagram[3]) {
            Socks5.ATYP_IPV4 -> offset += 4
            Socks5.ATYP_IPV6 -> offset += 16
            Socks5.ATYP_DOMAIN -> {
                val length = datagram[offset].toInt() and 0xFF
                offset += 1 + length
            }
            else -> return null
        }
        offset += 2
        if (offset >= datagram.size) return null
        return datagram.copyOfRange(offset, datagram.size)
    }

    /** A minimal DNS query for an A record: header, one question, no answers. */
    private fun dnsQueryBytes(name: String): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        out.write(byteArrayOf(0x12, 0x34))       // ID
        out.write(byteArrayOf(0x01, 0x00))       // standard query, recursion desired
        out.write(byteArrayOf(0, 1))             // QDCOUNT
        out.write(byteArrayOf(0, 0, 0, 0, 0, 0)) // AN/NS/AR counts
        name.split(".").forEach { label ->
            out.write(label.length)
            out.write(label.toByteArray(Charsets.UTF_8))
        }
        out.write(0)                             // root label
        out.write(byteArrayOf(0, 1))             // QTYPE A
        out.write(byteArrayOf(0, 1))             // QCLASS IN
        return out.toByteArray()
    }
}
