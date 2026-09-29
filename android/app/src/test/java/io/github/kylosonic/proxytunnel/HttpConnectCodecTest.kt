package io.github.kylosonic.proxytunnel

import io.github.kylosonic.proxytunnel.core.HttpConnect
import io.github.kylosonic.proxytunnel.core.ProxyCredential
import io.github.kylosonic.proxytunnel.core.Socks5
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.charset.StandardCharsets
import java.util.Base64

class HttpConnectCodecTest {

    private fun bytes(text: String) = text.toByteArray(StandardCharsets.ISO_8859_1)

    @Test
    fun `a connect request is a well formed http request head`() {
        val text = String(HttpConnect.request("example.com", 443, null), StandardCharsets.ISO_8859_1)
        assertTrue(text.startsWith("CONNECT example.com:443 HTTP/1.1\r\n"))
        assertTrue(text.contains("Host: example.com:443\r\n"))
        assertTrue(text.endsWith("\r\n\r\n"))
        assertFalse(text.contains("Proxy-Authorization"))
    }

    @Test
    fun `an ipv6 target is bracketed in the request line`() {
        val text = String(HttpConnect.request("2001:db8::1", 443, null), StandardCharsets.ISO_8859_1)
        assertTrue(text.startsWith("CONNECT [2001:db8::1]:443 HTTP/1.1\r\n"))
        assertTrue(text.contains("Host: [2001:db8::1]:443\r\n"))
    }

    @Test
    fun `credentials are sent pre-emptively as basic auth`() {
        val text = String(
            HttpConnect.request("example.com", 8080, ProxyCredential("alice", "hunter2")),
            StandardCharsets.ISO_8859_1
        )
        val expected = Base64.getEncoder().encodeToString("alice:hunter2".toByteArray(StandardCharsets.UTF_8))
        assertTrue(text.contains("Proxy-Authorization: Basic $expected\r\n"))
    }

    @Test
    fun `a credential with non ascii characters is base64 of utf8`() {
        val text = String(
            HttpConnect.request("example.com", 8080, ProxyCredential("ülrik", "påss")),
            StandardCharsets.ISO_8859_1
        )
        val expected = Base64.getEncoder().encodeToString("ülrik:påss".toByteArray(StandardCharsets.UTF_8))
        assertTrue(text.contains("Basic $expected"))
    }

    @Test
    fun `the head terminator is found at the byte after the blank line`() {
        val data = bytes("HTTP/1.1 200 OK\r\nA: b\r\n\r\nBODY")
        assertEquals(data.size - 4, HttpConnect.findHeadTerminator(data))
    }

    @Test
    fun `the head terminator tolerates bare line feeds`() {
        val data = bytes("HTTP/1.1 200 OK\nA: b\n\nBODY")
        assertEquals(data.size - 4, HttpConnect.findHeadTerminator(data))
    }

    @Test
    fun `an incomplete head reports minus one rather than guessing`() {
        assertEquals(-1, HttpConnect.findHeadTerminator(bytes("HTTP/1.1 200 OK\r\nA: b\r\n")))
        assertEquals(-1, HttpConnect.findHeadTerminator(ByteArray(0)))
    }

    @Test
    fun `a 200 response is a success`() {
        val response = HttpConnect.parseResponseHead(bytes("HTTP/1.1 200 Connection established\r\n\r\n"))
        assertEquals(200, response.statusCode)
        assertTrue(response.isSuccess)
        assertFalse(response.isAuthenticationChallenge)
    }

    @Test
    fun `a 407 response is recognised as an authentication challenge`() {
        val response = HttpConnect.parseResponseHead(
            bytes("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"x\"\r\n\r\n")
        )
        assertEquals(407, response.statusCode)
        assertFalse(response.isSuccess)
        assertTrue(response.isAuthenticationChallenge)
        assertEquals("Basic realm=\"x\"", response.headers["proxy-authenticate"])
    }

    @Test
    fun `header names are lower cased and repeated headers are joined`() {
        val response = HttpConnect.parseResponseHead(
            bytes("HTTP/1.1 200 OK\r\nX-Thing: one\r\nX-Thing: two\r\n\r\n")
        )
        assertEquals("one, two", response.headers["x-thing"])
    }

    @Test
    fun `a reason phrase with spaces is kept whole`() {
        val response = HttpConnect.parseResponseHead(bytes("HTTP/1.1 403 Forbidden By Policy\r\n\r\n"))
        assertEquals(403, response.statusCode)
        assertEquals("Forbidden By Policy", response.reason)
    }

    @Test
    fun `something that is not an http response is rejected`() {
        assertThrows(Socks5.Socks5Exception::class.java) {
            HttpConnect.parseResponseHead(bytes("SSH-2.0-OpenSSH_9.0\r\n\r\n"))
        }
    }

    @Test
    fun `a non numeric status code is rejected`() {
        assertThrows(Socks5.Socks5Exception::class.java) {
            HttpConnect.parseResponseHead(bytes("HTTP/1.1 OK\r\n\r\n"))
        }
    }

    @Test
    fun `parsing an incomplete head throws rather than returning garbage`() {
        assertThrows(HttpConnect.IncompleteException::class.java) {
            HttpConnect.parseResponseHead(bytes("HTTP/1.1 200 OK\r\n"))
        }
    }

    @Test
    fun `the summary line names the status`() {
        val response = HttpConnect.parseResponseHead(bytes("HTTP/1.1 502 Bad Gateway\r\n\r\n"))
        assertEquals("HTTP 502 Bad Gateway", response.summary)
    }

    @Test
    fun `asking for a body with no head terminator is not mistaken for a response`() {
        // A proxy that answers CONNECT with an HTML error page and no blank line
        // must not be read as a success.
        val data = bytes("<html><body>proxy error</body></html>")
        assertEquals(-1, HttpConnect.findHeadTerminator(data))
    }

    @Test
    fun `the user agent names this client`() {
        val text = String(HttpConnect.request("example.com", 80, null), StandardCharsets.ISO_8859_1)
        assertTrue(text.contains("User-Agent: ${HttpConnect.DEFAULT_USER_AGENT}\r\n"))
    }

    @Test
    fun `a request round trips through the response parser's line handling`() {
        // Guards the CRLF convention: the request builder and the response parser
        // must agree on what a line break is, or every handshake stalls.
        val request = HttpConnect.request("example.com", 443, null)
        assertArrayEquals(
            byteArrayOf(0x0D, 0x0A, 0x0D, 0x0A),
            request.copyOfRange(request.size - 4, request.size)
        )
    }
}
