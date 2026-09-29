package io.github.kylosonic.proxytunnel

import io.github.kylosonic.proxytunnel.core.HevConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests for the tunnel configuration the engine reads.
 *
 * The generated YAML has to satisfy two contradictory-looking requirements: it must
 * carry whatever the user typed, including punctuation that is special to YAML, and
 * nothing they typed may be able to add a key of its own.
 */
class HevConfigTest {

    private val sample = HevConfig.yaml(
        host = "gateway.example.com",
        port = 1080,
        username = "alice",
        password = "hunter2"
    )

    @Test
    fun `single quoting doubles an embedded quote`() {
        assertEquals("'plain'", HevConfig.singleQuote("plain"))
        assertEquals("'it''s'", HevConfig.singleQuote("it's"))
        assertEquals("''''", HevConfig.singleQuote("'"))
    }

    @Test
    fun `single quoting flattens line breaks so a value cannot become a second key`() {
        val injected = HevConfig.singleQuote("hunter2'\n  udp: 'off")
        assertFalse(injected.contains("\n"))
        assertEquals("'hunter2''  udp: ''off'", injected)
    }

    @Test
    fun `the tunnel block carries the addresses the vpn service is configured with`() {
        assertTrue(sample.contains("  ipv4: '${HevConfig.TUN_IPV4}'"))
        assertTrue(sample.contains("  ipv6: '${HevConfig.TUN_IPV6}'"))
        assertTrue(sample.contains("  mtu: ${HevConfig.DEFAULT_MTU}"))
    }

    @Test
    fun `the socks5 block names the upstream`() {
        assertTrue(sample.contains("socks5:"))
        assertTrue(sample.contains("  address: 'gateway.example.com'"))
        assertTrue(sample.contains("  port: 1080"))
    }

    @Test
    fun `udp is relayed through the association rather than dropped`() {
        assertTrue(sample.contains("  udp: 'udp'"))
    }

    @Test
    fun `credentials appear only when present`() {
        assertTrue(sample.contains("  username: 'alice'"))
        assertTrue(sample.contains("  password: 'hunter2'"))

        val anonymous = HevConfig.yaml("gateway.example.com", 1080, null, null)
        assertFalse(anonymous.contains("username:"))
        assertFalse(anonymous.contains("password:"))
    }

    @Test
    fun `a password with yaml metacharacters stays inside its scalar`() {
        val awkward = HevConfig.yaml("gateway.example.com", 1080, "ali:ce", "p@ss:word #not-a-comment")
        assertTrue(awkward.contains("  username: 'ali:ce'"))
        assertTrue(awkward.contains("  password: 'p@ss:word #not-a-comment'"))
        // Every line is still either a key, a list entry, or a comment.
        awkward.lineSequence().filter { it.isNotBlank() }.forEach { line ->
            val trimmed = line.trimStart()
            assertTrue(
                "unexpected line: \"$line\"",
                trimmed.startsWith("#") || trimmed.startsWith("-") ||
                    Regex("""^[A-Za-z][A-Za-z0-9-]*:""").containsMatchIn(trimmed)
            )
        }
    }

    @Test
    fun `the config ends with a newline so no parser sees a truncated last line`() {
        assertTrue(sample.endsWith("\n"))
    }

    @Test
    fun `logging goes to stderr rather than a file inside the app`() {
        assertTrue(sample.contains("  log-file: null"))
        assertTrue(sample.contains("  log-level: 'warn'"))
    }

    @Test
    fun `the redacted description never contains the password`() {
        val lines = HevConfig.describeRedacted("gateway.example.com", 1080, hasCredential = true)
        val text = lines.joinToString("\n")
        assertFalse(text.contains("hunter2"))
        assertTrue(text.contains("gateway.example.com:1080"))
        assertTrue(text.contains("present (kept out of this report)"))
    }

    @Test
    fun `the redacted description says so when there is no credential`() {
        val text = HevConfig.describeRedacted("gateway.example.com", 1080, hasCredential = false)
            .joinToString("\n")
        assertTrue(text.contains("none"))
    }

    @Test
    fun `the file name matches what the service deletes on stop`() {
        assertEquals("hev-socks5-tunnel.yml", HevConfig.FILE_NAME)
    }

    @Test
    fun `the tun addresses use a reserved range that cannot collide with a real network`() {
        // 198.18.0.0/15 is reserved for benchmarking, and fc00::/7 is unique-local.
        assertTrue(HevConfig.TUN_IPV4.startsWith("198.18."))
        assertTrue(HevConfig.TUN_IPV6.startsWith("fc00:"))
        assertTrue(HevConfig.TUN_IPV4_PREFIX in 1..30)
        assertTrue(HevConfig.TUN_IPV6_PREFIX in 1..126)
    }
}
