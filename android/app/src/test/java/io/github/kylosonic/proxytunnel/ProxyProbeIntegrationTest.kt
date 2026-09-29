package io.github.kylosonic.proxytunnel

import io.github.kylosonic.proxytunnel.core.ProxyCredential
import io.github.kylosonic.proxytunnel.core.ProxyProfile
import io.github.kylosonic.proxytunnel.core.ProxyProtocol
import io.github.kylosonic.proxytunnel.core.ProxyProbe
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * End-to-end tests for the "Test connection" feature.
 *
 * Every test here starts a real server on loopback, has the probe perform a real
 * SOCKS5 or CONNECT handshake, and asserts on what came back through the relay. The
 * egress address is served by the origin, so a reported value proves bytes actually
 * traversed the proxy — which is the only claim the UI makes.
 *
 * These run on the CI Linux runner as ordinary JVM tests: no emulator, no device.
 */
class ProxyProbeIntegrationTest {

    private val egress = "203.0.113.9"

    private fun profile(port: Int, protocol: ProxyProtocol = ProxyProtocol.SOCKS5, username: String? = null) =
        ProxyProfile(
            id = "test",
            name = "Test proxy",
            host = TestNet.LOOPBACK,
            port = port,
            protocol = protocol,
            username = username
        )

    private fun configuration(originPort: Int) = ProxyProbe.Configuration(
        checkHost = TestNet.LOOPBACK,
        checkPort = originPort,
        checkPath = "/",
        timeoutMillis = 5_000,
        resolvedAddresses = listOf(TestNet.LOOPBACK)
    )

    @Test
    fun `an anonymous socks5 proxy relays the request and the egress address comes back`() {
        FakeOrigin(egress).use { origin ->
            FakeSocks5Proxy().use { proxy ->
                val report = ProxyProbe.run(profile(proxy.port), null, configuration(origin.port))

                assertTrue(report.failureMessage ?: "", report.isSuccess)
                assertEquals(200, report.httpStatus)
                assertEquals(egress, report.egressIP)
                assertEquals("${TestNet.LOOPBACK}:${origin.port}", proxy.lastTarget)
                assertEquals(listOf(0.toByte()), proxy.offeredMethods)
                assertNotNull(origin.lastRequestLine)
                assertTrue(origin.lastRequestLine!!.startsWith("GET / HTTP/1.1"))
            }
        }
    }

    @Test
    fun `a username and password reach the proxy intact`() {
        FakeOrigin(egress).use { origin ->
            FakeSocks5Proxy(username = "alice", password = "p@ss word:1").use { proxy ->
                val report = ProxyProbe.run(
                    profile(proxy.port, username = "alice"),
                    ProxyCredential("alice", "p@ss word:1"),
                    configuration(origin.port)
                )

                assertTrue(report.failureMessage ?: "", report.isSuccess)
                assertEquals(egress, report.egressIP)
                assertEquals("alice", proxy.sawUsername)
                assertEquals("p@ss word:1", proxy.sawPassword)
                assertEquals(listOf(2.toByte(), 0.toByte()), proxy.offeredMethods)
            }
        }
    }

    @Test
    fun `a proxy that requires authentication rejects a profile without a credential`() {
        FakeOrigin(egress).use { origin ->
            FakeSocks5Proxy(username = "alice", password = "hunter2").use { proxy ->
                val report = ProxyProbe.run(profile(proxy.port), null, configuration(origin.port))

                assertFalse(report.isSuccess)
                assertEquals("badServerResponse", report.failureKind)
                assertTrue(report.failureMessage!!, report.failureMessage!!.contains("authentication"))
                assertTrue(report.failureSuggestion!!.contains("protocol"))
            }
        }
    }

    @Test
    fun `a wrong password is reported without repeating it`() {
        FakeOrigin(egress).use { origin ->
            FakeSocks5Proxy(username = "alice", password = "hunter2").use { proxy ->
                val report = ProxyProbe.run(
                    profile(proxy.port, username = "alice"),
                    ProxyCredential("alice", "wrong-guess"),
                    configuration(origin.port)
                )

                assertFalse(report.isSuccess)
                assertEquals("badServerResponse", report.failureKind)
                val text = report.summaryLines.joinToString("\n")
                assertFalse(text.contains("wrong-guess"))
                assertFalse(text.contains("hunter2"))
                assertEquals("wrong-guess", proxy.sawPassword)
            }
        }
    }

    @Test
    fun `a proxy that refuses the destination reports the socks reply text`() {
        // REP 0x05 is "connection refused" in RFC 1928 §6.
        FakeSocks5Proxy(forcedReplyCode = 5).use { proxy ->
            val report = ProxyProbe.run(profile(proxy.port), null, configuration(9))

            assertFalse(report.isSuccess)
            assertEquals("badServerResponse", report.failureKind)
            assertTrue(report.failureMessage!!, report.failureMessage!!.contains("refused"))
        }
    }

    @Test
    fun `a port with nothing listening is reported as unreachable not as a protocol error`() {
        val report = ProxyProbe.run(profile(TestNet.closedPort()), null, configuration(9))

        assertFalse(report.isSuccess)
        assertEquals("proxyUnreachable", report.failureKind)
        assertTrue(report.failureMessage!!.contains("refused"))
        assertNotNull(report.failureSuggestion)
    }

    @Test
    fun `an unresolvable proxy host is reported before anything is dialled`() {
        // No configuration is passed, so the probe really does try to resolve the
        // name. ".invalid" is reserved by RFC 2606 and must never resolve.
        val unreachable = ProxyProfile(
            id = "x", name = "x", host = "this-host-does-not-exist.invalid", port = 1080,
            protocol = ProxyProtocol.SOCKS5
        )
        val report = ProxyProbe.run(unreachable, null)

        assertFalse(report.isSuccess)
        assertEquals("proxyUnreachable", report.failureKind)
        assertTrue(report.failureSuggestion!!.contains("host name"))
        assertTrue(report.resolvedAddresses.isEmpty())
    }

    @Test
    fun `an empty host fails local validation without touching the network`() {
        val report = ProxyProbe.run(
            ProxyProfile(id = "x", name = "x", host = "", port = 1080, protocol = ProxyProtocol.SOCKS5),
            null
        )
        assertEquals("invalidHost", report.failureKind)
        assertTrue(report.resolvedAddresses.isEmpty())
    }

    @Test
    fun `a port outside the valid range fails local validation`() {
        val report = ProxyProbe.run(
            ProxyProfile(id = "x", name = "x", host = TestNet.LOOPBACK, port = 70000, protocol = ProxyProtocol.SOCKS5),
            null
        )
        assertEquals("invalidPort", report.failureKind)
    }

    @Test
    fun `an http connect proxy works end to end`() {
        FakeOrigin(egress).use { origin ->
            FakeHttpProxy("HTTP/1.1 200 Connection established").use { proxy ->
                val report = ProxyProbe.run(
                    profile(proxy.port, ProxyProtocol.HTTP_CONNECT),
                    null,
                    configuration(origin.port)
                )

                assertTrue(report.failureMessage ?: "", report.isSuccess)
                assertEquals(egress, report.egressIP)
                assertTrue(proxy.lastHead!!.startsWith("CONNECT ${TestNet.LOOPBACK}:${origin.port} HTTP/1.1"))
            }
        }
    }

    @Test
    fun `an http connect proxy sees the proxy authorization header when credentials exist`() {
        FakeOrigin(egress).use { origin ->
            FakeHttpProxy("HTTP/1.1 200 Connection established").use { proxy ->
                val report = ProxyProbe.run(
                    profile(proxy.port, ProxyProtocol.HTTP_CONNECT, username = "alice"),
                    ProxyCredential("alice", "hunter2"),
                    configuration(origin.port)
                )

                assertTrue(report.failureMessage ?: "", report.isSuccess)
                // base64("alice:hunter2")
                assertTrue(proxy.lastHead!!.contains("Proxy-Authorization: Basic YWxpY2U6aHVudGVyMg=="))
            }
        }
    }

    @Test
    fun `a 407 from an http proxy is reported as an authentication problem`() {
        FakeHttpProxy("HTTP/1.1 407 Proxy Authentication Required").use { proxy ->
            val report = ProxyProbe.run(
                profile(proxy.port, ProxyProtocol.HTTP_CONNECT),
                null,
                configuration(9)
            )

            assertFalse(report.isSuccess)
            assertEquals("badServerResponse", report.failureKind)
            assertTrue(report.failureMessage!!.contains("authentication"))
        }
    }

    @Test
    fun `a 502 from an http proxy is reported with its status`() {
        FakeHttpProxy("HTTP/1.1 502 Bad Gateway").use { proxy ->
            val report = ProxyProbe.run(
                profile(proxy.port, ProxyProtocol.HTTP_CONNECT),
                null,
                configuration(9)
            )

            assertFalse(report.isSuccess)
            assertTrue(report.failureMessage!!.contains("502"))
        }
    }

    @Test
    fun `a server that is not a proxy at all is reported instead of hanging`() {
        // The HTTP origin answers a SOCKS5 greeting with an HTTP error page.
        FakeOrigin(egress).use { origin ->
            val report = ProxyProbe.run(profile(origin.port), null, configuration(9))

            assertFalse(report.isSuccess)
            assertNotNull(report.failureKind)
            assertNotNull(report.failureMessage)
        }
    }

    @Test
    fun `a proxy that stalls is abandoned at the timeout rather than blocking the app`() {
        java.net.ServerSocket(0, 5, java.net.InetAddress.getByName(TestNet.LOOPBACK)).use { silent ->
            val started = System.currentTimeMillis()
            val report = ProxyProbe.run(
                profile(silent.localPort),
                null,
                ProxyProbe.Configuration(
                    checkHost = TestNet.LOOPBACK,
                    checkPort = 9,
                    timeoutMillis = 1_000,
                    resolvedAddresses = listOf(TestNet.LOOPBACK)
                )
            )
            val elapsed = System.currentTimeMillis() - started

            assertFalse(report.isSuccess)
            assertEquals("connectionTimeout", report.failureKind)
            assertTrue("took ${elapsed}ms", elapsed < 5_000)
            assertTrue(report.failureSuggestion!!.contains("network"))
        }
    }

    @Test
    fun `the report lists what was checked in a readable order`() {
        FakeOrigin(egress).use { origin ->
            FakeSocks5Proxy().use { proxy ->
                val report = ProxyProbe.run(profile(proxy.port), null, configuration(origin.port))
                val lines = report.summaryLines

                assertTrue(lines[0].startsWith("Proxy host resolved to"))
                assertTrue(lines[1].startsWith("TCP connect to"))
                assertTrue(lines[2].startsWith("Proxy handshake: SOCKS5 CONNECT"))
                assertTrue(lines[3].startsWith("HTTP request through the proxy: status 200"))
                assertTrue(lines[4].startsWith("Traffic exited via $egress"))
                assertTrue(report.totalMillis >= 0)
            }
        }
    }

    @Test
    fun `extractIP accepts a bare address and refuses to invent one`() {
        assertEquals("203.0.113.9", ProxyProbe.extractIP("203.0.113.9"))
        assertEquals("203.0.113.9", ProxyProbe.extractIP("  203.0.113.9\n"))
        assertEquals("2001:db8::1", ProxyProbe.extractIP("2001:db8::1"))
        // Not an address: the first token is returned as text rather than guessed at.
        assertEquals("not-an-address", ProxyProbe.extractIP("not-an-address"))
    }
}
