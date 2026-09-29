package io.github.kylosonic.proxytunnel

import io.github.kylosonic.proxytunnel.core.HostKind
import io.github.kylosonic.proxytunnel.core.HostValidator
import io.github.kylosonic.proxytunnel.core.LogRedactor
import io.github.kylosonic.proxytunnel.core.PortValidator
import io.github.kylosonic.proxytunnel.core.ProxyCredential
import io.github.kylosonic.proxytunnel.core.ProxyProfile
import io.github.kylosonic.proxytunnel.core.ProxyProtocol
import io.github.kylosonic.proxytunnel.core.Sanitizer
import io.github.kylosonic.proxytunnel.core.Severity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ValidationTest {

    // MARK: hosts

    @Test
    fun `accepts a plain hostname`() {
        val result = HostValidator.validate("gateway.example.com")
        assertTrue(result.issues.none { it.severity == Severity.ERROR })
        assertEquals("gateway.example.com", result.sanitized)
        assertTrue(result.kind is HostKind.Hostname)
    }

    @Test
    fun `accepts an ipv4 literal`() {
        val result = HostValidator.validate("203.0.113.7")
        assertTrue(result.kind is HostKind.Ipv4)
        assertTrue(result.kind!!.isLiteral)
    }

    @Test
    fun `accepts and normalises an ipv6 literal in brackets`() {
        val result = HostValidator.validate("[2001:db8::1]")
        assertTrue(result.issues.none { it.severity == Severity.ERROR })
        assertEquals("2001:db8::1", result.sanitized)
        assertTrue(result.kind is HostKind.Ipv6)
        assertTrue(result.kind!!.isLiteral)
    }

    @Test
    fun `rejects an ipv4 octet out of range`() {
        val result = HostValidator.validate("192.168.1.256")
        assertTrue(result.issues.any { it.severity == Severity.ERROR })
    }

    @Test
    fun `rejects an empty host`() {
        assertTrue(HostValidator.validate("").issues.any { it.severity == Severity.ERROR })
    }

    @Test
    fun `rejects a host with a space`() {
        assertTrue(HostValidator.validate("bad host").issues.any { it.severity == Severity.ERROR })
    }

    @Test
    fun `rejects a hostname label longer than 63 characters`() {
        val label = "a".repeat(64)
        assertTrue(HostValidator.validate("$label.example.com").issues.any { it.severity == Severity.ERROR })
    }

    @Test
    fun `rejects a hostname longer than 253 characters`() {
        val host = (1..5).joinToString(".") { "a".repeat(60) }
        assertTrue(host.length > 253)
        assertTrue(HostValidator.validate(host).issues.any { it.severity == Severity.ERROR })
    }

    @Test
    fun `rejects a host with a leading hyphen in a label`() {
        assertTrue(HostValidator.validate("-leading.example.com").issues.any { it.severity == Severity.ERROR })
    }

    @Test
    fun `trims surrounding whitespace and strips a bracketed ipv6`() {
        assertEquals("example.com", HostValidator.validate("  example.com  ").sanitized)
    }

    @Test
    fun `isIpv6Literal agrees with the validator`() {
        assertTrue(HostValidator.isIpv6Literal("2001:db8::1"))
        assertTrue(HostValidator.isIpv6Literal("::1"))
        assertFalse(HostValidator.isIpv6Literal("example.com"))
        assertFalse(HostValidator.isIpv6Literal("1.2.3.4"))
    }

    // MARK: ports

    @Test
    fun `accepts a normal port`() {
        val result = PortValidator.validate("1080", ProxyProtocol.SOCKS5)
        assertEquals(1080, result.value)
        assertTrue(result.issues.none { it.severity == Severity.ERROR })
    }

    @Test
    fun `rejects port zero and port 65536`() {
        assertNull(PortValidator.validate("0").value)
        assertNull(PortValidator.validate("65536").value)
    }

    @Test
    fun `rejects a non-numeric port`() {
        assertNull(PortValidator.validate("http").value)
    }

    @Test
    fun `warns when the port is unusual for the chosen protocol but still accepts it`() {
        val result = PortValidator.validate("8080", ProxyProtocol.SOCKS5)
        assertEquals(8080, result.value)
        assertTrue(result.isValid)
        assertTrue(result.issues.any { it.severity == Severity.WARNING })
    }

    @Test
    fun `the default port produces no warnings at all`() {
        val result = PortValidator.validate("1080", ProxyProtocol.SOCKS5)
        assertEquals(1080, result.value)
        assertTrue(result.issues.isEmpty())
    }

    @Test
    fun `warns about a privileged port`() {
        val result = PortValidator.validate("80", ProxyProtocol.HTTP_CONNECT)
        assertEquals(80, result.value)
        assertTrue(result.issues.any { it.severity == Severity.WARNING })
    }

    // MARK: sanitiser

    @Test
    fun `sanitiser removes a zero width space`() {
        assertEquals("hostname", Sanitizer.clean("host\u200Bname"))
    }

    @Test
    fun `sanitiser removes a bidi override`() {
        assertEquals("hostname", Sanitizer.clean("host\u202Ename"))
    }

    @Test
    fun `sanitiser detects control characters rather than silently keeping them`() {
        assertTrue(Sanitizer.containsControlCharacters("host\u0000name"))
        assertFalse(Sanitizer.containsControlCharacters("hostname"))
    }

    @Test
    fun `the host validator rejects a host with a control character and strips it`() {
        val result = HostValidator.validate("host\u0000name.example.com")
        assertTrue(result.issues.any { it.severity == Severity.ERROR })
        assertFalse(Sanitizer.containsControlCharacters(result.sanitized))
    }

    @Test
    fun `the host validator refuses embedded credentials`() {
        val result = HostValidator.validate("alice:hunter2@example.com")
        assertTrue(result.issues.any { it.severity == Severity.ERROR })
        assertEquals("example.com", result.sanitized)
        // The message must not repeat the password back into a log or a text field.
        assertFalse(result.issues.joinToString { it.message }.contains("hunter2"))
    }

    // MARK: redaction

    @Test
    fun `redacts a password in a key value pair`() {
        val redacted = LogRedactor.redact("password=hunter2 host=example.com")
        assertFalse(redacted.contains("hunter2"))
        assertTrue(redacted.contains("example.com"))
    }

    @Test
    fun `redacts credentials inside a url`() {
        val redacted = LogRedactor.redact("dialing socks5://alice:hunter2@example.com:1080")
        assertFalse(redacted.contains("hunter2"))
        assertTrue(redacted.contains("example.com"))
    }

    @Test
    fun `redacts a proxy authorization header`() {
        val redacted = LogRedactor.redact("Proxy-Authorization: Basic YWxpY2U6aHVudGVyMg==")
        assertFalse(redacted.contains("YWxpY2U6aHVudGVyMg=="))
    }

    @Test
    fun `maskes a username without revealing it`() {
        val masked = LogRedactor.maskUsername("alice")
        assertFalse(masked.contains("alice"))
        assertEquals("a•••e", masked)
    }

    @Test
    fun `maskes a very short username completely`() {
        assertEquals("••", LogRedactor.maskUsername("ab"))
    }

    @Test
    fun `a credential never prints its password`() {
        val credential = ProxyCredential("alice", "hunter2")
        assertFalse(credential.toString().contains("hunter2"))
        assertFalse(credential.toString().contains("alice"))
    }

    @Test
    fun `a profile has no field that could hold a password`() {
        val profile = ProxyProfile(
            id = "abc",
            name = "Test",
            host = "example.com",
            port = 1080,
            protocol = ProxyProtocol.SOCKS5,
            username = "alice",
            hasStoredPassword = true
        )
        assertEquals(
            "ProxyProfile(id=abc…, name=\"Test\", endpoint=example.com:1080, protocol=socks5, " +
                "region=<none>, user=a•••e, hasPassword=true, enabled=true)",
            profile.redactedSummary
        )
        // The type is the guarantee: the only field whose name mentions a password is
        // the boolean flag, so there is nowhere for a secret to be stored by accident.
        val fields = ProxyProfile::class.java.declaredFields.associateBy { it.name }
        assertFalse("ProxyProfile must not declare a password field", fields.containsKey("password"))
        assertEquals(Boolean::class.javaPrimitiveType, fields.getValue("hasStoredPassword").type)
    }

    // MARK: protocol capabilities

    @Test
    fun `only socks5 can carry the tunnel upstream`() {
        assertTrue(ProxyProtocol.SOCKS5.supportsTunnelUpstream)
        assertFalse(ProxyProtocol.HTTP_CONNECT.supportsTunnelUpstream)
        assertFalse(ProxyProtocol.HTTPS_CONNECT.supportsTunnelUpstream)
    }

    @Test
    fun `protocol wire names round trip`() {
        ProxyProtocol.entries.forEach { protocol ->
            assertEquals(protocol, ProxyProtocol.fromWireName(protocol.wireName))
        }
        assertNull(ProxyProtocol.fromWireName("socks4"))
    }

    @Test
    fun `an ipv6 endpoint is bracketed for display`() {
        assertEquals("[2001:db8::1]:1080", ProxyProfile.formatEndpoint("2001:db8::1", 1080))
        assertEquals("example.com:1080", ProxyProfile.formatEndpoint("example.com", 1080))
    }
}
