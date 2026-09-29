package io.github.kylosonic.proxytunnel.core

import java.io.ByteArrayOutputStream
import java.nio.charset.StandardCharsets

/**
 * SOCKS5 codec (RFC 1928) and username/password auth (RFC 1929).
 *
 * Pure byte handling, so every branch is unit-testable without a socket — the
 * same split the iOS side uses, and for the same reason: a framing bug is
 * invisible until a real proxy rejects it.
 */
object Socks5 {
    const val VERSION: Byte = 0x05
    const val AUTH_VERSION: Byte = 0x01
    const val RESERVED: Byte = 0x00

    const val METHOD_NONE: Byte = 0x00
    const val METHOD_USER_PASSWORD: Byte = 0x02
    const val METHOD_NO_ACCEPTABLE: Byte = 0xFF.toByte()

    const val CMD_CONNECT: Byte = 0x01
    const val CMD_UDP_ASSOCIATE: Byte = 0x03

    const val ATYP_IPV4: Byte = 0x01
    const val ATYP_DOMAIN: Byte = 0x03
    const val ATYP_IPV6: Byte = 0x04

    class Socks5Exception(message: String) : Exception(message)
    class IncompleteException(val needed: Int) : Exception("incomplete (need $needed more bytes)")

    /** `VER | NMETHODS | METHODS…` */
    fun greeting(methods: List<Byte>): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(VERSION.toInt())
        out.write(methods.size)
        methods.forEach { out.write(it.toInt()) }
        return out.toByteArray()
    }

    fun defaultMethods(hasCredential: Boolean): List<Byte> =
        if (hasCredential) listOf(METHOD_USER_PASSWORD, METHOD_NONE) else listOf(METHOD_NONE)

    /** `VER | METHOD` — exactly two bytes. */
    fun parseMethodSelection(data: ByteArray): Byte {
        if (data.size < 2) throw IncompleteException(2 - data.size)
        if (data[0] != VERSION) {
            throw Socks5Exception("server replied with SOCKS version ${data[0].toInt()}, expected 5")
        }
        return data[1]
    }

    /** `VER(1) | ULEN | UNAME | PLEN | PASSWD` */
    fun userPasswordRequest(username: String, password: String): ByteArray {
        val user = username.toByteArray(StandardCharsets.UTF_8)
        val pass = password.toByteArray(StandardCharsets.UTF_8)
        require(user.size <= 255) { "username is longer than the 255 bytes RFC 1929 allows" }
        require(pass.size <= 255) { "password is longer than the 255 bytes RFC 1929 allows" }

        val out = ByteArrayOutputStream()
        out.write(AUTH_VERSION.toInt())
        out.write(user.size)
        out.write(user)
        out.write(pass.size)
        out.write(pass)
        return out.toByteArray()
    }

    /** `VER(1) | STATUS`. STATUS 0 means accepted. */
    fun parseUserPasswordResponse(data: ByteArray) {
        if (data.size < 2) throw IncompleteException(2 - data.size)
        if (data[0] != AUTH_VERSION) throw Socks5Exception("auth reply version ${data[0].toInt()}, expected 1")
        if (data[1] != 0.toByte()) {
            throw Socks5Exception("authentication rejected (status 0x%02x)".format(data[1]))
        }
    }

    /** `VER | CMD | RSV | ATYP | DST.ADDR | DST.PORT` */
    fun request(command: Byte, host: String, port: Int): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(VERSION.toInt())
        out.write(command.toInt())
        out.write(RESERVED.toInt())
        writeAddress(out, host)
        out.write((port shr 8) and 0xFF)
        out.write(port and 0xFF)
        return out.toByteArray()
    }

    /** Literal addresses go as-is; anything else goes as a domain name, which is what makes remote DNS work. */
    private fun writeAddress(out: ByteArrayOutputStream, host: String) {
        val ipv4 = host.split(".")
        if (ipv4.size == 4 && ipv4.all { it.toIntOrNull()?.let { v -> v in 0..255 } == true }) {
            out.write(ATYP_IPV4.toInt())
            ipv4.forEach { out.write(it.toInt()) }
            return
        }
        if (host.contains(':') && HostValidator.isIpv6Literal(host)) {
            out.write(ATYP_IPV6.toInt())
            out.write(ipv6ToBytes(host))
            return
        }
        val name = host.toByteArray(StandardCharsets.UTF_8)
        require(name.isNotEmpty() && name.size <= 255) { "domain name must be 1-255 bytes" }
        out.write(ATYP_DOMAIN.toInt())
        out.write(name.size)
        out.write(name)
    }

    fun ipv6ToBytes(host: String): ByteArray {
        val bytes = ByteArray(16)
        val doubleColon = host.indexOf("::")
        val head = if (doubleColon >= 0) host.substring(0, doubleColon) else host
        val tail = if (doubleColon >= 0) host.substring(doubleColon + 2) else ""
        val headGroups = if (head.isEmpty()) emptyList() else head.split(":")
        val tailGroups = if (tail.isEmpty()) emptyList() else tail.split(":")

        var cursor = 0
        headGroups.forEach { group ->
            val value = group.toInt(16)
            bytes[cursor++] = ((value shr 8) and 0xFF).toByte()
            bytes[cursor++] = (value and 0xFF).toByte()
        }
        cursor = 16 - tailGroups.size * 2
        tailGroups.forEach { group ->
            val value = group.toInt(16)
            bytes[cursor++] = ((value shr 8) and 0xFF).toByte()
            bytes[cursor++] = (value and 0xFF).toByte()
        }
        return bytes
    }

    data class Reply(val code: Int, val boundHost: String, val boundPort: Int, val consumed: Int)

    /** `VER | REP | RSV | ATYP | BND.ADDR | BND.PORT` */
    fun parseReply(data: ByteArray): Reply {
        if (data.size < 4) throw IncompleteException(4 - data.size)
        if (data[0] != VERSION) throw Socks5Exception("reply version ${data[0].toInt()}, expected 5 (is this really a SOCKS5 proxy?)")
        val code = data[1].toInt() and 0xFF
        val atyp = data[3]
        var offset = 4

        val host: String
        when (atyp) {
            ATYP_IPV4 -> {
                if (data.size < offset + 6) throw IncompleteException(offset + 6 - data.size)
                host = (0 until 4).joinToString(".") { (data[offset + it].toInt() and 0xFF).toString() }
                offset += 4
            }
            ATYP_IPV6 -> {
                if (data.size < offset + 18) throw IncompleteException(offset + 18 - data.size)
                host = (0 until 8).joinToString(":") {
                    "%02x%02x".format(data[offset + it * 2], data[offset + it * 2 + 1])
                }
                offset += 16
            }
            ATYP_DOMAIN -> {
                if (data.size < offset + 1) throw IncompleteException(1)
                val length = data[offset].toInt() and 0xFF
                offset += 1
                if (data.size < offset + length + 2) throw IncompleteException(offset + length + 2 - data.size)
                host = String(data, offset, length, StandardCharsets.UTF_8)
                offset += length
            }
            else -> throw Socks5Exception("unknown address type 0x%02x".format(atyp))
        }

        val port = ((data[offset].toInt() and 0xFF) shl 8) or (data[offset + 1].toInt() and 0xFF)
        return Reply(code, host, port, offset + 2)
    }

    /** Human-readable reply text, from RFC 1928 §6. */
    fun replyName(code: Int): String = when (code) {
        0x00 -> "succeeded"
        0x01 -> "general SOCKS server failure"
        0x02 -> "connection not allowed by ruleset"
        0x03 -> "network unreachable"
        0x04 -> "host unreachable"
        0x05 -> "connection refused"
        0x06 -> "TTL expired"
        0x07 -> "command not supported"
        0x08 -> "address type not supported"
        else -> "unknown reply 0x%02x".format(code)
    }
}

/**
 * HTTP CONNECT codec, as used by forward proxies (RFC 9110 §9.3.6).
 *
 * We only ever send CONNECT and parse the response head; after a 2xx the
 * connection is an opaque byte pipe.
 */
object HttpConnect {
    const val DEFAULT_USER_AGENT = "ProxyTunnel-Android/1.0"

    data class Response(val statusCode: Int, val reason: String, val headers: Map<String, String>) {
        val isSuccess: Boolean get() = statusCode in 200..299
        val isAuthenticationChallenge: Boolean get() = statusCode == 407
        val summary: String get() = "HTTP $statusCode $reason"
    }

    fun request(host: String, port: Int, credential: ProxyCredential?, userAgent: String = DEFAULT_USER_AGENT): ByteArray {
        val authority = ShareLink.authority(host, port)
        val builder = StringBuilder()
        builder.append("CONNECT ").append(authority).append(" HTTP/1.1\r\n")
        builder.append("Host: ").append(authority).append("\r\n")
        builder.append("User-Agent: ").append(userAgent).append("\r\n")
        builder.append("Proxy-Connection: Keep-Alive\r\n")
        if (credential != null) {
            // Sent pre-emptively: it saves a round trip and avoids proxies that
            // close the connection instead of issuing a 407.
            val token = java.util.Base64.getEncoder()
                .encodeToString("${credential.username}:${credential.password}".toByteArray(StandardCharsets.UTF_8))
            builder.append("Proxy-Authorization: Basic ").append(token).append("\r\n")
        }
        builder.append("\r\n")
        return builder.toString().toByteArray(StandardCharsets.ISO_8859_1)
    }

    /** Returns the byte offset just past the blank line, or -1. */
    fun findHeadTerminator(data: ByteArray): Int {
        for (i in 0..data.size - 4) {
            if (data[i] == 0x0D.toByte() && data[i + 1] == 0x0A.toByte() &&
                data[i + 2] == 0x0D.toByte() && data[i + 3] == 0x0A.toByte()
            ) return i + 4
        }
        for (i in 0..data.size - 2) {
            if (data[i] == 0x0A.toByte() && data[i + 1] == 0x0A.toByte()) return i + 2
        }
        return -1
    }

    class IncompleteException : Exception("response head is not complete yet")

    fun parseResponseHead(data: ByteArray): Response {
        val terminator = findHeadTerminator(data)
        if (terminator < 0) throw IncompleteException()

        val head = String(data, 0, terminator, StandardCharsets.ISO_8859_1)
        val lines = head.replace("\r\n", "\n").split("\n")
        val statusLine = lines.firstOrNull()?.takeIf { it.isNotEmpty() }
            ?: throw Socks5.Socks5Exception("empty status line")

        val parts = statusLine.split(" ", limit = 3).filter { it.isNotEmpty() }
        if (parts.size < 2 || !parts[0].uppercase().startsWith("HTTP/")) {
            throw Socks5.Socks5Exception("not an HTTP response (\"${statusLine.take(120)}\")")
        }
        val status = parts[1].toIntOrNull()
            ?: throw Socks5.Socks5Exception("bad status code in \"${statusLine.take(120)}\"")
        val reason = if (parts.size > 2) parts[2] else ""

        val headers = mutableMapOf<String, String>()
        lines.drop(1).filter { it.isNotEmpty() }.forEach { line ->
            val colon = line.indexOf(':')
            if (colon <= 0) return@forEach
            val key = line.substring(0, colon).trim().lowercase()
            val value = line.substring(colon + 1).trim()
            headers[key] = headers[key]?.let { "$it, $value" } ?: value
        }

        return Response(status, reason, headers)
    }
}
