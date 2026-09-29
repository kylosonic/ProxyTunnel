package io.github.kylosonic.proxytunnel

import io.github.kylosonic.proxytunnel.core.Socks5
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.charset.StandardCharsets

/**
 * Byte-level tests for the SOCKS5 codec.
 *
 * These are the tests that matter most in this module: a framing mistake here is
 * invisible until a real proxy rejects the connection, and every byte asserted
 * below comes from RFC 1928 / RFC 1929 rather than from this implementation.
 */
class Socks5CodecTest {

    private fun hex(bytes: ByteArray) = bytes.joinToString(" ") { "%02x".format(it) }

    @Test
    fun `greeting with no methods is version and count only`() {
        assertArrayEquals(byteArrayOf(0x05, 0x00), Socks5.greeting(emptyList()))
    }

    @Test
    fun `greeting with one method is three bytes`() {
        assertArrayEquals(byteArrayOf(0x05, 0x01, 0x00), Socks5.greeting(listOf(Socks5.METHOD_NONE)))
    }

    @Test
    fun `a profile with a credential offers user password first`() {
        assertArrayEquals(
            byteArrayOf(0x05, 0x02, 0x02, 0x00),
            Socks5.greeting(Socks5.defaultMethods(hasCredential = true))
        )
    }

    @Test
    fun `a profile without a credential offers only no auth`() {
        assertArrayEquals(
            byteArrayOf(0x05, 0x01, 0x00),
            Socks5.greeting(Socks5.defaultMethods(hasCredential = false))
        )
    }

    @Test
    fun `method selection must carry version 5`() {
        assertEquals(Socks5.METHOD_NONE, Socks5.parseMethodSelection(byteArrayOf(0x05, 0x00)))
        assertEquals(Socks5.METHOD_USER_PASSWORD, Socks5.parseMethodSelection(byteArrayOf(0x05, 0x02)))
        assertEquals(
            Socks5.METHOD_NO_ACCEPTABLE,
            Socks5.parseMethodSelection(byteArrayOf(0x05, 0xFF.toByte()))
        )
        assertThrows(Socks5.Socks5Exception::class.java) {
            Socks5.parseMethodSelection(byteArrayOf(0x04, 0x00))
        }
    }

    @Test
    fun `a truncated method selection is reported as incomplete`() {
        assertThrows(Socks5.IncompleteException::class.java) {
            Socks5.parseMethodSelection(byteArrayOf(0x05))
        }
    }

    @Test
    fun `user password request matches rfc 1929 layout`() {
        val bytes = Socks5.userPasswordRequest("alice", "hunter2")
        val expected = byteArrayOf(0x01, 0x05) +
            "alice".toByteArray(StandardCharsets.UTF_8) +
            byteArrayOf(0x07) +
            "hunter2".toByteArray(StandardCharsets.UTF_8)
        assertArrayEquals(expected, bytes)
        assertEquals("01 05 61 6c 69 63 65 07 68 75 6e 74 65 72 32", hex(bytes))
    }

    @Test
    fun `user password request refuses an over-long credential`() {
        assertThrows(IllegalArgumentException::class.java) {
            Socks5.userPasswordRequest("a".repeat(256), "x")
        }
    }

    @Test
    fun `user password response accepts only status zero`() {
        Socks5.parseUserPasswordResponse(byteArrayOf(0x01, 0x00))
        assertThrows(Socks5.Socks5Exception::class.java) {
            Socks5.parseUserPasswordResponse(byteArrayOf(0x01, 0x01))
        }
        assertThrows(Socks5.Socks5Exception::class.java) {
            Socks5.parseUserPasswordResponse(byteArrayOf(0x02, 0x00))
        }
    }

    @Test
    fun `connect request to an ipv4 literal writes atyp 1`() {
        val bytes = Socks5.request(Socks5.CMD_CONNECT, "1.2.3.4", 1080)
        assertEquals("05 01 00 01 01 02 03 04 04 38", hex(bytes))
        assertEquals(10, bytes.size)
    }

    @Test
    fun `connect request to a host name writes atyp 3 so the proxy resolves it`() {
        val bytes = Socks5.request(Socks5.CMD_CONNECT, "example.com", 443)
        assertEquals(0x05, bytes[0].toInt())
        assertEquals(0x01, bytes[1].toInt())
        assertEquals(0x00, bytes[2].toInt())
        assertEquals(0x03, bytes[3].toInt())
        assertEquals(11, bytes[4].toInt())
        assertEquals("example.com", String(bytes, 5, 11, StandardCharsets.UTF_8))
        assertEquals(443, ((bytes[16].toInt() and 0xFF) shl 8) or (bytes[17].toInt() and 0xFF))
        assertEquals("05 01 00 03 0b 65 78 61 6d 70 6c 65 2e 63 6f 6d 01 bb", hex(bytes))
    }

    @Test
    fun `connect request to an ipv6 literal writes atyp 4 and sixteen bytes`() {
        val bytes = Socks5.request(Socks5.CMD_CONNECT, "2001:db8::1", 1080)
        assertEquals(22, bytes.size)
        assertEquals(0x04, bytes[3].toInt())
        val expected = byteArrayOf(
            0x05, 0x01, 0x00, 0x04,
            0x20, 0x01, 0x0d, 0xb8.toByte(), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01,
            0x04, 0x38
        )
        assertArrayEquals(expected, bytes)
    }

    @Test
    fun `ipv6 compression expands to the right sixteen bytes`() {
        assertArrayEquals(
            byteArrayOf(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1),
            Socks5.ipv6ToBytes("::1")
        )
        assertArrayEquals(
            byteArrayOf(0xfe.toByte(), 0x80.toByte(), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1),
            Socks5.ipv6ToBytes("fe80::1")
        )
    }

    @Test
    fun `a successful reply is parsed with its bound address`() {
        val reply = Socks5.parseReply(byteArrayOf(0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0x1F, 0x90.toByte()))
        assertEquals(0, reply.code)
        assertEquals("127.0.0.1", reply.boundHost)
        assertEquals(8080, reply.boundPort)
        assertEquals(10, reply.consumed)
    }

    @Test
    fun `a domain reply is parsed at variable length`() {
        val name = "proxy.example".toByteArray(StandardCharsets.UTF_8)
        val reply = Socks5.parseReply(
            byteArrayOf(0x05, 0x00, 0x00, 0x03, name.size.toByte()) + name + byteArrayOf(0x00, 0x50)
        )
        assertEquals("proxy.example", reply.boundHost)
        assertEquals(80, reply.boundPort)
        assertEquals(4 + 1 + name.size + 2, reply.consumed)
    }

    @Test
    fun `an ipv6 reply is parsed into sixteen bytes of address`() {
        val reply = Socks5.parseReply(
            byteArrayOf(0x05, 0x00, 0x00, 0x04) +
                byteArrayOf(0x20, 0x01, 0x0d, 0xb8.toByte(), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1) +
                byteArrayOf(0x01, 0xBB.toByte())
        )
        assertEquals("2001:0db8:0000:0000:0000:0000:0000:0001", reply.boundHost)
        assertEquals(443, reply.boundPort)
    }

    @Test
    fun `a reply with the wrong version is rejected`() {
        assertThrows(Socks5.Socks5Exception::class.java) {
            Socks5.parseReply(byteArrayOf(0x04, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0))
        }
    }

    @Test
    fun `a truncated reply is reported as incomplete rather than mis-parsed`() {
        assertThrows(Socks5.IncompleteException::class.java) {
            Socks5.parseReply(byteArrayOf(0x05, 0x00, 0x00))
        }
        assertThrows(Socks5.IncompleteException::class.java) {
            Socks5.parseReply(byteArrayOf(0x05, 0x00, 0x00, 0x01, 127, 0))
        }
    }

    @Test
    fun `every reply code has a readable name`() {
        (0..8).forEach { code ->
            val name = Socks5.replyName(code)
            assertTrue("code $code produced \"$name\"", name.isNotBlank())
            assertTrue(!name.startsWith("unknown"))
        }
        assertTrue(Socks5.replyName(0x42).startsWith("unknown"))
    }
}
