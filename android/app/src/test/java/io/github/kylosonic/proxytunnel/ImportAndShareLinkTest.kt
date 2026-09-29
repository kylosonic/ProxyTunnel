package io.github.kylosonic.proxytunnel

import io.github.kylosonic.proxytunnel.core.ImportEntry
import io.github.kylosonic.proxytunnel.core.ProxyCredential
import io.github.kylosonic.proxytunnel.core.ProxyImportParser
import io.github.kylosonic.proxytunnel.core.ProxyProfile
import io.github.kylosonic.proxytunnel.core.ProxyProtocol
import io.github.kylosonic.proxytunnel.core.RegionCatalog
import io.github.kylosonic.proxytunnel.core.ShareLink
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests for the paste importer and the share-link format.
 *
 * The importer is the feature most likely to be used with a real, messy list copied
 * out of a provider's dashboard, so the tests cover the shapes that actually appear
 * there rather than only the tidy ones.
 */
class ImportAndShareLinkTest {

    private fun only(text: String, default: ProxyProtocol? = null): ImportEntry {
        val entries = ProxyImportParser.parse(text, default)
        assertEquals("expected exactly one entry for \"$text\", got $entries", 1, entries.size)
        return entries[0]
    }

    private fun ready(text: String, default: ProxyProtocol? = null): ImportEntry {
        val entry = only(text, default)
        assertTrue("line \"$text\" failed: ${entry.failure}", entry.isReady)
        return entry
    }

    // MARK: share links

    @Test
    fun `a scheme url is read with its credentials`() {
        val entry = ready("socks5://alice:hunter2@gateway.example.com:1080")
        assertEquals("gateway.example.com", entry.host)
        assertEquals(1080, entry.port)
        assertEquals(ProxyProtocol.SOCKS5, entry.protocol)
        assertEquals("alice", entry.username)
        assertEquals("hunter2", entry.password)
    }

    @Test
    fun `socks5h is accepted and means socks5`() {
        assertEquals(ProxyProtocol.SOCKS5, ready("socks5h://gateway.example.com:1080").protocol)
    }

    @Test
    fun `http and https schemes select the matching protocol`() {
        assertEquals(ProxyProtocol.HTTP_CONNECT, ready("http://proxy.example.com:3128").protocol)
        assertEquals(ProxyProtocol.HTTPS_CONNECT, ready("https://proxy.example.com:8443").protocol)
    }

    @Test
    fun `socks4 is refused with an explanation rather than silently misread`() {
        val entry = only("socks4://gateway.example.com:1080")
        assertFalse(entry.isReady)
        assertTrue(entry.failure!!.contains("SOCKS5"))
    }

    @Test
    fun `a fragment becomes the name`() {
        val entry = ready("socks5://alice:hunter2@gateway.example.com:1080#ProxyCheap%20US")
        assertEquals("ProxyCheap US", entry.name)
        // The importer hands the name on; the location label is derived from it.
        assertEquals("US", RegionCatalog.guess(entry.name)?.code)
    }

    @Test
    fun `a missing port falls back to the protocol default and says so`() {
        val entry = ready("socks5://gateway.example.com")
        assertEquals(1080, entry.port)
        assertTrue(entry.notes.any { it.contains("1080") })
    }

    @Test
    fun `an ipv6 literal in brackets is parsed`() {
        val entry = ready("socks5://alice:hunter2@[2001:db8::1]:1080")
        assertEquals("2001:db8::1", entry.host)
        assertEquals(1080, entry.port)
    }

    @Test
    fun `a scheme with no host is refused`() {
        val entry = only("socks5://")
        assertFalse(entry.isReady)
    }

    // MARK: implicit formats

    @Test
    fun `host colon port colon user colon pass`() {
        val entry = ready("1.2.3.4:1080:alice:hunter2")
        assertEquals("1.2.3.4", entry.host)
        assertEquals(1080, entry.port)
        assertEquals("alice", entry.username)
        assertEquals("hunter2", entry.password)
    }

    @Test
    fun `user colon pass colon host colon port`() {
        val entry = ready("alice:hunter2:1.2.3.4:1080")
        assertEquals("1.2.3.4", entry.host)
        assertEquals(1080, entry.port)
        assertEquals("alice", entry.username)
        assertEquals("hunter2", entry.password)
    }

    @Test
    fun `a bare host and port is enough`() {
        val entry = ready("1.2.3.4:1080")
        assertEquals("1.2.3.4", entry.host)
        assertEquals(1080, entry.port)
        assertNull(entry.username)
        assertNull(entry.password)
    }

    @Test
    fun `user colon pass at host colon port`() {
        val entry = ready("alice:hunter2@1.2.3.4:1080")
        assertEquals("1.2.3.4", entry.host)
        assertEquals(1080, entry.port)
        assertEquals("alice", entry.username)
        assertEquals("hunter2", entry.password)
    }

    @Test
    fun `host colon port at user colon pass`() {
        val entry = ready("1.2.3.4:1080@alice:hunter2")
        assertEquals("1.2.3.4", entry.host)
        assertEquals(1080, entry.port)
        assertEquals("alice", entry.username)
        assertEquals("hunter2", entry.password)
    }

    @Test
    fun `space, comma and semicolon separated values are all understood`() {
        assertEquals(1080, ready("1.2.3.4 1080").port)
        assertEquals(1080, ready("1.2.3.4,1080").port)
        assertEquals(1080, ready("1.2.3.4;1080").port)
    }

    @Test
    fun `key value pairs in any order`() {
        val entry = ready("host = 1.2.3.4  port = 1080  user = alice  pass = hunter2")
        assertEquals("1.2.3.4", entry.host)
        assertEquals(1080, entry.port)
        assertEquals("alice", entry.username)
        assertEquals("hunter2", entry.password)
        assertTrue(entry.notes.any { it.contains("key=value") })
    }

    @Test
    fun `colon separated key value pairs from a provider dashboard`() {
        val entry = ready("server:1.2.3.4:port:1080:username:alice:password:hunter2")
        assertEquals("1.2.3.4", entry.host)
        assertEquals(1080, entry.port)
        assertEquals("alice", entry.username)
        assertEquals("hunter2", entry.password)
    }

    @Test
    fun `a json object is understood`() {
        val entry = ready("""{"host":"1.2.3.4","port":1080,"username":"alice","password":"hunter2"}""")
        assertEquals("1.2.3.4", entry.host)
        assertEquals(1080, entry.port)
        assertEquals("alice", entry.username)
        assertEquals("hunter2", entry.password)
    }

    @Test
    fun `a label before a pipe becomes the name`() {
        val entry = ready("ProxyCheap NL | socks5://alice:hunter2@nl.example.com:1080")
        assertEquals("ProxyCheap NL", entry.name)
        assertEquals("nl.example.com", entry.host)
        assertEquals("NL", RegionCatalog.guess(entry.name)?.code)
    }

    @Test
    fun `a country code in the label is picked up from the source when there is no name`() {
        val entry = ready("socks5://alice:hunter2@gateway.example.com:1080")
        // No country anywhere: the caller must not invent one.
        assertNull(RegionCatalog.guess(entry.name ?: entry.redactedSource))
    }

    @Test
    fun `quotes and backticks around a line are stripped`() {
        val entry = ready("\"1.2.3.4:1080\"")
        assertEquals("1.2.3.4", entry.host)
    }

    // MARK: ambiguity

    @Test
    fun `a line that could be read either way is flagged instead of guessed silently`() {
        // Both readings are structurally as strong as each other.
        val entry = ready("1.2.3.4:1080:5.6.7.8:3128")
        assertTrue(entry.isAmbiguous)
        assertTrue(entry.notes.any { it.contains("either way") })
    }

    @Test
    fun `an ipv4 host beats a hostname reading, so ordinary lines are not flagged`() {
        val entry = ready("1.2.3.4:1080:alice:hunter2")
        assertFalse(entry.isAmbiguous)
    }

    // MARK: rejection

    @Test
    fun `a line with no host and port is reported as unreadable`() {
        val entry = only("hello world")
        assertFalse(entry.isReady)
        assertNotNull(entry.failure)
        assertTrue(entry.failure!!.contains("host and port"))
    }

    @Test
    fun `an out of range port is refused`() {
        val entry = only("socks5://gateway.example.com:99999")
        assertFalse(entry.isReady)
        assertTrue(entry.failure!!.contains("Port"))
    }

    @Test
    fun `blank lines and comments are skipped rather than reported`() {
        val entries = ProxyImportParser.parse(
            """
            # my proxies
            socks5://alice:hunter2@a.example.com:1080

            // second one
            socks5://bob:hunter3@b.example.com:1080
            ; trailing note
            """.trimIndent()
        )
        assertEquals(2, entries.size)
        assertTrue(entries.all { it.isReady })
        assertEquals(listOf("a.example.com", "b.example.com"), entries.map { it.host })
    }

    @Test
    fun `every line of a mixed paste is accounted for`() {
        val entries = ProxyImportParser.parse(
            """
            socks5://alice:hunter2@a.example.com:1080
            this line is nonsense
            1.2.3.4:1080
            """.trimIndent()
        )
        assertEquals(3, entries.size)
        assertEquals(2, entries.count { it.isReady })
        assertEquals(1, entries.count { !it.isReady })
        assertEquals(listOf(1, 2, 3), entries.map { it.lineNumber })
    }

    // MARK: redaction

    @Test
    fun `a parsed line never shows the password back`() {
        val entry = ready("socks5://alice:hunter2@gateway.example.com:1080")
        assertFalse(entry.redactedSource.contains("hunter2"))
        assertTrue(entry.redactedSource.contains("gateway.example.com"))
    }

    @Test
    fun `an unreadable line never shows the password back either`() {
        val entry = only("alice:hunter2@not a host at all")
        assertFalse(entry.redactedSource.contains("hunter2"))
    }

    @Test
    fun `a failed scheme line never shows the password back`() {
        val entry = only("socks5://alice:hunter2@gateway.example.com:99999")
        assertFalse(entry.isReady)
        assertFalse(entry.redactedSource.contains("hunter2"))
    }

    // MARK: share link round trip

    @Test
    fun `a formatted share link is a url with the name as a fragment`() {
        val profile = ProxyProfile(
            id = "1", name = "ProxyCheap US", host = "gateway.example.com", port = 1080,
            protocol = ProxyProtocol.SOCKS5, username = "alice", hasStoredPassword = true
        )
        val link = ShareLink.format(profile, ProxyCredential("alice", "hunter2"))
        assertEquals("socks5://alice:hunter2@gateway.example.com:1080#ProxyCheap%20US", link)
    }

    @Test
    fun `the password can be left out of a share link`() {
        val profile = ProxyProfile(
            id = "1", name = "P", host = "gateway.example.com", port = 1080,
            protocol = ProxyProtocol.SOCKS5, username = "alice", hasStoredPassword = true
        )
        val link = ShareLink.format(profile, ProxyCredential("alice", "hunter2"), includePassword = false)
        assertEquals("socks5://alice@gateway.example.com:1080#P", link)
    }

    @Test
    fun `a profile without credentials produces a bare link`() {
        val profile = ProxyProfile(
            id = "1", name = "P", host = "1.2.3.4", port = 1080, protocol = ProxyProtocol.SOCKS5
        )
        assertEquals("socks5://1.2.3.4:1080#P", ShareLink.format(profile, null))
    }

    @Test
    fun `export then import returns the same proxy, including awkward characters`() {
        val cases = listOf(
            Triple("alice", "hunter2", "gateway.example.com"),
            // Every character here is a delimiter somewhere in the format.
            Triple("ali ce", "p@ss:w/rd?#&=%", "gateway.example.com"),
            Triple("user+tag", "unicode-→-ok", "gateway.example.com")
        )

        cases.forEach { (username, password, host) ->
            val profile = ProxyProfile(
                id = "1", name = "Round trip", host = host, port = 1080,
                protocol = ProxyProtocol.SOCKS5, username = username, hasStoredPassword = true
            )
            val link = ShareLink.format(profile, ProxyCredential(username, password))
            val entry = ready(link)

            assertEquals("username survived: $link", username, entry.username)
            assertEquals("password survived: $link", password, entry.password)
            assertEquals("host survived: $link", host, entry.host)
            assertEquals(1080, entry.port)
            assertEquals("Round trip", entry.name)
        }
    }

    @Test
    fun `an ipv6 proxy survives the round trip`() {
        val profile = ProxyProfile(
            id = "1", name = "Six", host = "2001:db8::1", port = 1080, protocol = ProxyProtocol.SOCKS5
        )
        val link = ShareLink.format(profile, null)
        assertEquals("socks5://[2001:db8::1]:1080#Six", link)
        assertEquals("2001:db8::1", ready(link).host)
    }

    @Test
    fun `percent encoding leaves unreserved characters alone and escapes the rest`() {
        assertEquals("abcXYZ019-._~", ShareLink.percentEncode("abcXYZ019-._~"))
        assertEquals("a%20b", ShareLink.percentEncode("a b"))
        assertEquals("%40%3A%2F%3F%23%26%3D%25", ShareLink.percentEncode("@:/?#&=%"))
        assertEquals("caf%C3%A9", ShareLink.percentEncode("café"))
    }

    @Test
    fun `percent decoding reverses encoding exactly`() {
        val samples = listOf("plain", "a b", "@:/?#&=%", "café", "→", "100%", "%41", "a+b")
        samples.forEach { sample ->
            assertEquals(sample, ShareLink.percentDecode(ShareLink.percentEncode(sample)))
        }
    }

    @Test
    fun `percent decoding tolerates a stray percent sign`() {
        assertEquals("100%", ShareLink.percentDecode("100%"))
        assertEquals("%zz", ShareLink.percentDecode("%zz"))
    }

    @Test
    fun `the exported scheme follows the protocol`() {
        val base = ProxyProfile(id = "1", name = "P", host = "h.example.com", port = 1, protocol = ProxyProtocol.SOCKS5)
        assertEquals("socks5", ShareLink.schemeFor(ProxyProtocol.SOCKS5))
        assertEquals("http", ShareLink.schemeFor(ProxyProtocol.HTTP_CONNECT))
        assertEquals("https", ShareLink.schemeFor(ProxyProtocol.HTTPS_CONNECT))
        assertTrue(ShareLink.format(base.copy(protocol = ProxyProtocol.HTTP_CONNECT), null).startsWith("http://"))
    }

    @Test
    fun `a default protocol can be forced for a list that does not say`() {
        assertEquals(ProxyProtocol.HTTP_CONNECT, ready("1.2.3.4:3128", ProxyProtocol.HTTP_CONNECT).protocol)
        // Port-based detection is the fallback when nothing is forced.
        assertEquals(ProxyProtocol.HTTP_CONNECT, ready("1.2.3.4:3128").protocol)
        assertEquals(ProxyProtocol.SOCKS5, ready("1.2.3.4:1080").protocol)
    }

    @Test
    fun `host and port splitting handles the shapes a provider list contains`() {
        assertEquals("h.example.com" to 1080, ProxyImportParser.splitHostPort("h.example.com:1080"))
        assertEquals("2001:db8::1" to 1080, ProxyImportParser.splitHostPort("[2001:db8::1]:1080"))
        assertEquals("2001:db8::1" to null, ProxyImportParser.splitHostPort("[2001:db8::1]"))
        assertEquals("h.example.com" to null, ProxyImportParser.splitHostPort("h.example.com"))
        assertNull(ProxyImportParser.splitHostPort("h.example.com:0"))
        assertNull(ProxyImportParser.splitHostPort(""))
        assertNull(ProxyImportParser.splitHostPort("[2001:db8::1"))
    }
}
