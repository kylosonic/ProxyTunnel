package io.github.kylosonic.proxytunnel.core

import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener

/**
 * The interchange format, byte-for-byte compatible with the iOS app.
 *
 * This is the one thing the two platforms genuinely share: a share link produced
 * on the iPhone imports on Android and vice versa, so a proxy list moves between
 * them without retyping. The tests assert the round trip in both directions.
 */
object ShareLink {

    private const val UNRESERVED =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

    fun percentEncode(text: String): String {
        val out = StringBuilder()
        for (byte in text.toByteArray(Charsets.UTF_8)) {
            val ch = (byte.toInt() and 0xFF).toChar()
            if (UNRESERVED.indexOf(ch) >= 0) {
                out.append(ch)
            } else {
                // Locale.ROOT: a hex escape must not change with the device language.
                out.append('%').append(String.format(java.util.Locale.ROOT, "%02X", byte.toInt() and 0xFF))
            }
        }
        return out.toString()
    }

    fun percentDecode(text: String): String {
        val bytes = mutableListOf<Byte>()
        var i = 0
        while (i < text.length) {
            val ch = text[i]
            if (ch == '%' && i + 2 < text.length) {
                val hex = text.substring(i + 1, i + 3).toIntOrNull(16)
                if (hex != null) {
                    bytes += hex.toByte()
                    i += 3
                    continue
                }
            }
            bytes += ch.toString().toByteArray(Charsets.UTF_8).toList()
            i++
        }
        return String(bytes.toByteArray(), Charsets.UTF_8)
    }

    /** `host:port`, with an IPv6 literal bracketed. */
    fun authority(host: String, port: Int): String =
        if (host.contains(':') && !host.startsWith("[")) "[$host]:$port" else "$host:$port"

    fun schemeFor(protocol: ProxyProtocol): String = when (protocol) {
        ProxyProtocol.SOCKS5 -> "socks5"
        ProxyProtocol.HTTP_CONNECT -> "http"
        ProxyProtocol.HTTPS_CONNECT -> "https"
    }

    /**
     * `scheme://user:pass@host:port#Name`
     *
     * The password is included by default because an export without it does not
     * work; the UI is what warns about where it ends up.
     */
    fun format(
        profile: ProxyProfile,
        credential: ProxyCredential?,
        includePassword: Boolean = true,
        nameOverride: String? = null
    ): String {
        val builder = StringBuilder(schemeFor(profile.protocol)).append("://")

        val username = credential?.username
        if (!username.isNullOrEmpty()) {
            builder.append(percentEncode(username))
            val password = if (includePassword) credential.password else null
            if (!password.isNullOrEmpty()) {
                builder.append(':').append(percentEncode(password))
            }
            builder.append('@')
        }

        builder.append(authority(profile.host, profile.port))

        val name = nameOverride ?: profile.name
        if (name.isNotEmpty()) {
            builder.append('#').append(percentEncode(name))
        }
        return builder.toString()
    }
}

/** One parsed line, plus why it failed if it did. */
data class ImportEntry(
    val lineNumber: Int,
    /** Credentials masked. This is what the UI and any log may show. */
    val redactedSource: String,
    val host: String? = null,
    val port: Int? = null,
    val protocol: ProxyProtocol = ProxyProtocol.SOCKS5,
    val username: String? = null,
    val password: String? = null,
    val name: String? = null,
    val notes: List<String> = emptyList(),
    val isAmbiguous: Boolean = false,
    val failure: String? = null
) {
    val isReady: Boolean get() = failure == null && host != null && port != null
    val displayEndpoint: String get() = if (host != null && port != null) ProxyProfile.formatEndpoint(host, port) else redactedSource
}

/**
 * Parses pasted text into proxies.
 *
 * Supports the same shapes as the iOS importer — including the scoring that
 * resolves `a:b:c:d`, which is genuinely two readings — so the same list can be
 * pasted on either platform.
 */
object ProxyImportParser {

    /**
     * `key=value`, `key = value`, `key: value`. A value may be quoted, otherwise it
     * runs to the next space, comma, semicolon or ampersand — which is what keeps a
     * `password = p@ss word` line ambiguous in exactly the way a human would find it.
     */
    private val PAIR = Regex("""([A-Za-z_][A-Za-z0-9_-]*)\s*[:=]\s*("[^"]*"|'[^']*'|[^\s,;&]+)""")

    fun parse(text: String, defaultProtocol: ProxyProtocol? = null): List<ImportEntry> {
        // A whole-document JSON paste is handled before line splitting, because a
        // pretty-printed object spans many lines and each one alone is meaningless.
        val document = text.trim()
        if (document.startsWith("{") || document.startsWith("[")) {
            interpretJson(document, defaultProtocol)?.let { return listOf(it.copy(lineNumber = 1)) }
        }

        val entries = mutableListOf<ImportEntry>()
        text.replace("\r\n", "\n").replace("\r", "\n")
            .split("\n")
            .forEachIndexed { index, raw ->
                val trimmed = raw.trim()
                // Blank lines and comments are skipped rather than reported: a pasted
                // list with a header comment should not show that comment as a line
                // that "could not be read".
                if (trimmed.isEmpty() || isComment(trimmed)) return@forEachIndexed
                entries += parseLine(trimmed, index + 1, defaultProtocol)
            }
        return entries
    }

    /** `#`, `//` and `;` all start a comment, matching the iOS importer. */
    fun isComment(line: String): Boolean {
        val trimmed = line.trim()
        return trimmed.startsWith("#") || trimmed.startsWith("//") || trimmed.startsWith(";")
    }

    fun parseLine(rawLine: String, lineNumber: Int = 1, defaultProtocol: ProxyProtocol? = null): ImportEntry {
        val trimmed = rawLine.trim()

        fun fail(reason: String, source: String = LogRedactor.redact(trimmed)) =
            ImportEntry(lineNumber, source, failure = reason)

        if (trimmed.isEmpty()) return fail("Nothing on this line.", "")
        if (trimmed.startsWith("#") || trimmed.startsWith("//") || trimmed.startsWith(";")) {
            return fail("Comment.", trimmed)
        }

        // `Label | spec`
        var label: String? = null
        var body = trimmed
        val pipe = trimmed.indexOf('|')
        if (pipe > 0) {
            val before = trimmed.substring(0, pipe).trim()
            val after = trimmed.substring(pipe + 1).trim()
            if (before.isNotEmpty() && after.isNotEmpty()) {
                label = before
                body = after
            }
        }

        val parsed = interpret(body, defaultProtocol)
        if (parsed.failure != null) return fail(parsed.failure, LogRedactor.redact(trimmed))

        val withName = parsed.copy(name = label ?: parsed.name)
        return withName.copy(
            lineNumber = lineNumber,
            redactedSource = redactLine(trimmed, withName.password)
        )
    }

    /** Masks the credential portion of a line for display. */
    fun redactLine(line: String, password: String?): String {
        if (password.isNullOrEmpty()) return LogRedactor.redact(line)
        return LogRedactor.redact(line.replace(password, LogRedactor.MASK))
    }

    // MARK: interpretation

    private data class Candidate(
        val host: String,
        val port: Int,
        val protocol: ProxyProtocol,
        val username: String?,
        val password: String?,
        val shape: String,
        val notes: List<String>,
        val hostFirst: Boolean,
        val name: String? = null,
        val failure: String? = null
    ) {
        val hostStrength: Int
            get() {
                val result = HostValidator.validate(host)
                if (!result.isValid) return 0
                return when (result.kind) {
                    is HostKind.Ipv4, is HostKind.Ipv6 -> 3
                    is HostKind.Hostname -> if (result.kind.name.contains('.')) 2 else 1
                    null -> 0
                }
            }

        val structuralScore: Int get() = hostStrength * 10
        val score: Int get() = structuralScore + if (hostFirst) 1 else 0
    }

    private fun interpret(raw: String, defaultProtocol: ProxyProtocol?): ImportEntry {
        var text = raw.trim().trim('"', '\'', '`', '“', '”', '‘', '’').trim()
        if (text.isEmpty()) return ImportEntry(0, "", failure = "Nothing on this line.")

        interpretWithScheme(text, defaultProtocol)?.let { return it }
        interpretJson(text, defaultProtocol)?.let { return it }
        interpretKeyValue(text, defaultProtocol)?.let { return it }

        val candidates = mutableListOf<Candidate>()
        candidates += interpretAtForms(text, defaultProtocol)
        candidates += interpretSeparatedForms(text, defaultProtocol)

        val best = candidates.maxByOrNull { it.score }
            ?: return ImportEntry(
                0, redactLine(text, null),
                failure = "Could not find a host and port here. Expected something like socks5://user:pass@host:1080, host:1080:user:pass, or host:1080."
            )

        val tied = candidates.any { it.shape != best.shape && it.structuralScore == best.structuralScore }
        val notes = best.notes.toMutableList()
        if (tied) {
            notes += "This line could be read either way round; ${best.shape} was assumed. Check the host after adding."
        }

        val hostValidation = HostValidator.validate(best.host)
        hostValidation.issues.firstOrNull { it.severity == Severity.ERROR }?.let {
            return ImportEntry(0, redactLine(text, best.password), failure = "Host problem: ${it.message}")
        }
        if (best.port !in PortValidator.RANGE) {
            return ImportEntry(0, redactLine(text, best.password), failure = "Port problem: ${best.port} is outside 1-65535")
        }

        return ImportEntry(
            lineNumber = 0,
            redactedSource = redactLine(text, best.password),
            host = hostValidation.sanitized,
            port = best.port,
            protocol = best.protocol,
            username = best.username,
            password = best.password,
            name = best.name,
            notes = notes + hostValidation.issues.filter { it.severity == Severity.WARNING }.map { it.message },
            isAmbiguous = tied
        )
    }

    private fun interpretWithScheme(text: String, defaultProtocol: ProxyProtocol?): ImportEntry? {
        val separator = text.indexOf("://")
        if (separator <= 0) return null

        val scheme = text.substring(0, separator).lowercase()
        var rest = text.substring(separator + 3)

        var fragmentName: String? = null
        val hash = rest.indexOf('#')
        if (hash >= 0) {
            val fragment = ShareLink.percentDecode(rest.substring(hash + 1))
            if (fragment.isNotBlank()) fragmentName = fragment
        }
        val cut = rest.indexOfFirst { it == '/' || it == '?' || it == '#' }
        if (cut >= 0) rest = rest.substring(0, cut)
        rest = rest.trim()

        if (rest.isEmpty()) {
            return ImportEntry(0, LogRedactor.redact(text), failure = "There is a scheme but no host after it.")
        }

        val schemeProtocol = when (scheme) {
            "socks5", "socks5h", "socks" -> ProxyProtocol.SOCKS5
            "http", "http-connect", "httpconnect", "connect" -> ProxyProtocol.HTTP_CONNECT
            "https", "https-connect", "httpsconnect" -> ProxyProtocol.HTTPS_CONNECT
            "socks4", "socks4a" -> return ImportEntry(
                0, LogRedactor.redact(text),
                failure = "\"$scheme\" proxies are not supported. Use SOCKS5, HTTP CONNECT or HTTPS CONNECT."
            )
            else -> null
        }

        val notes = mutableListOf<String>()
        val protocol = schemeProtocol ?: defaultProtocol ?: ProxyProtocol.SOCKS5
        if (schemeProtocol == null) notes += "Unrecognised scheme \"$scheme\"; ${protocol.displayName} was used instead."

        var userInfo: String? = null
        var authority = rest
        val at = rest.lastIndexOf('@')
        if (at >= 0) {
            userInfo = rest.substring(0, at)
            authority = rest.substring(at + 1)
        }

        val endpoint = splitHostPort(authority)
        if (endpoint == null) {
            // Say which part is wrong. "gateway.example.com:99999" is a host with a
            // port; the port is just outside the valid range, and reporting that as
            // "not a host with a port" would send the user looking in the wrong place.
            val colon = authority.lastIndexOf(':')
            val tail = if (colon > 0) authority.substring(colon + 1) else ""
            val failure = if (tail.isNotEmpty() && tail.all { it.isDigit() }) {
                "Port problem: $tail is outside 1-65535"
            } else {
                "\"$authority\" is not a host with a port"
            }
            return ImportEntry(0, LogRedactor.redact(text), failure = failure)
        }

        val port = endpoint.second ?: protocol.defaultPort.also {
            notes += "No port given, so $it was used — the usual port for ${protocol.displayName}."
        }
        if (port !in PortValidator.RANGE) {
            return ImportEntry(0, LogRedactor.redact(text), failure = "Port problem: $port is outside 1-65535")
        }

        var username: String? = null
        var password: String? = null
        if (!userInfo.isNullOrEmpty()) {
            val parts = userInfo.split(":", limit = 2)
            username = ShareLink.percentDecode(parts[0])
            if (parts.size > 1) password = ShareLink.percentDecode(parts[1])
        }

        val hostValidation = HostValidator.validate(endpoint.first)
        hostValidation.issues.firstOrNull { it.severity == Severity.ERROR }?.let {
            return ImportEntry(0, redactLine(text, password), failure = "Host problem: ${it.message}")
        }
        notes += hostValidation.issues.filter { it.severity == Severity.WARNING }.map { it.message }

        return ImportEntry(
            0, redactLine(text, password),
            host = hostValidation.sanitized, port = port, protocol = protocol,
            username = username, password = password, name = fragmentName, notes = notes
        )
    }

    /**
     * `{"host": …, "port": …, "username": …, "password": …}`, or an array of those,
     * or a wrapper object with a `proxies`/`servers`/`list` array inside it.
     *
     * Parsed with a real JSON reader rather than string surgery, so escaped quotes
     * and nested objects behave.
     */
    private fun interpretJson(text: String, defaultProtocol: ProxyProtocol?): ImportEntry? {
        val trimmed = text.trim()
        val looksLikeJson = (trimmed.startsWith("{") && trimmed.endsWith("}")) ||
            (trimmed.startsWith("[") && trimmed.endsWith("]"))
        if (!looksLikeJson) return null

        val parsed = runCatching { JSONTokener(trimmed).nextValue() }.getOrNull() ?: return null

        fun objectOf(value: Any?): JSONObject? = when (value) {
            is JSONObject -> value
            is JSONArray -> (0 until value.length()).firstNotNullOfOrNull { value.optJSONObject(it) }
            else -> null
        }

        val first = objectOf(parsed) ?: return null

        // A wrapper document, e.g. {"proxies":[{…}]}.
        val nested = objectOf(
            listOf("proxies", "servers", "list", "items", "data")
                .firstNotNullOfOrNull { first.opt(it) }
        )
        val record = nested ?: first

        fun field(vararg keys: String): String? = keys.firstNotNullOfOrNull { key ->
            record.optString(key).takeIf { it.isNotBlank() && it != "null" }
        }

        val rawHost = field("host", "hostname", "server", "ip", "address", "server_address")
            ?: return null

        val protocol = field("protocol", "proto", "type", "scheme", "proxy_type")?.let { name ->
            when (name.lowercase().replace('_', '-')) {
                "socks5", "socks", "socks5h" -> ProxyProtocol.SOCKS5
                "http", "http-connect", "connect", "httpconnect" -> ProxyProtocol.HTTP_CONNECT
                "https", "https-connect", "tls", "httpsconnect" -> ProxyProtocol.HTTPS_CONNECT
                else -> null
            }
        } ?: defaultProtocol ?: ProxyProtocol.SOCKS5

        val portText = field("port", "server_port", "proxy_port")
        val portValue = portText?.toIntOrNull()
        if (portText != null && (portValue == null || portValue !in PortValidator.RANGE)) {
            return ImportEntry(0, LogRedactor.redact(text), failure = "Port problem: $portText is outside 1-65535")
        }

        val hostValidation = HostValidator.validate(rawHost)
        hostValidation.issues.firstOrNull { it.severity == Severity.ERROR }?.let {
            return ImportEntry(0, LogRedactor.redact(text), failure = "Host problem: ${it.message}")
        }

        val notes = mutableListOf("Read as a JSON object.")
        if (portValue == null) notes += "No port given, so ${protocol.defaultPort} was used."
        notes += hostValidation.issues.filter { it.severity == Severity.WARNING }.map { it.message }

        return ImportEntry(
            0, LogRedactor.redact(text),
            host = hostValidation.sanitized,
            port = portValue ?: protocol.defaultPort,
            protocol = protocol,
            username = field("username", "user", "login", "userid"),
            password = field("password", "pass", "pwd", "passwd"),
            name = field("name", "tag", "label", "remark", "remarks"),
            notes = notes
        )
    }

    private fun interpretKeyValue(text: String, defaultProtocol: ProxyProtocol?): ImportEntry? {
        val knownKeys = setOf(
            "host", "hostname", "server", "ip", "address", "port", "username", "user",
            "userid", "login", "password", "pass", "passwd", "pwd", "protocol", "proto", "type", "scheme"
        )
        val fields = mutableMapOf<String, String>()

        // server:1.2.3.4:port:1080:username:u:password:p
        val colonTokens = text.split(":").map { it.trim() }
        if (colonTokens.size >= 4 && colonTokens.size % 2 == 0 && knownKeys.contains(colonTokens[0].lowercase())) {
            var i = 0
            while (i + 1 < colonTokens.size) {
                fields[colonTokens[i].lowercase()] = colonTokens[i + 1]
                i += 2
            }
        }
        if (fields.isEmpty()) {
            // `key=value` and `key = value`, including `host = 1.2.3.4  port = 1080`.
            // Splitting on whitespace first would turn "host =" into two tokens and
            // lose the pair entirely.
            PAIR.findAll(text).forEach { match ->
                val key = match.groupValues[1].lowercase()
                val value = match.groupValues[2].trim().trim('"', '\'', '`')
                if (value.isNotEmpty()) fields[key] = value
            }
        }

        fun first(vararg keys: String): String? = keys.firstNotNullOfOrNull { fields[it]?.takeIf { v -> v.isNotEmpty() } }

        val rawHost = first("host", "hostname", "server", "ip", "address") ?: return null
        val hostValidation = HostValidator.validate(rawHost)

        val protocolText = first("protocol", "proto", "type", "scheme")
        val protocol = protocolText?.let { name ->
            when (name.lowercase().replace('_', '-')) {
                "socks5", "socks", "socks5h" -> ProxyProtocol.SOCKS5
                "http", "http-connect", "connect", "httpconnect" -> ProxyProtocol.HTTP_CONNECT
                "https", "https-connect", "tls", "httpsconnect" -> ProxyProtocol.HTTPS_CONNECT
                else -> null
            }
        } ?: defaultProtocol ?: ProxyProtocol.SOCKS5

        val portText = first("port")
        val port = portText?.toIntOrNull()?.takeIf { it in PortValidator.RANGE } ?: protocol.defaultPort

        val notes = mutableListOf("Read as key=value pairs.")
        if (portText == null) notes += "No port given, so $port was used."
        notes += hostValidation.issues.filter { it.severity == Severity.WARNING }.map { it.message }

        return ImportEntry(
            0, LogRedactor.redact(text),
            host = hostValidation.sanitized, port = port, protocol = protocol,
            username = first("username", "user", "login", "userid"),
            password = first("password", "pass", "pwd", "passwd"),
            notes = notes
        )
    }

    private fun interpretAtForms(text: String, defaultProtocol: ProxyProtocol?): List<Candidate> {
        val results = mutableListOf<Candidate>()
        text.indices.filter { text[it] == '@' }.forEach { at ->
            val left = text.substring(0, at)
            val right = text.substring(at + 1)
            if (left.isEmpty() || right.isEmpty()) return@forEach

            splitHostPort(left)?.takeIf { it.second != null }?.let { (host, port) ->
                if (HostValidator.validate(host).isValid) {
                    val creds = right.split(":", limit = 2)
                    val username = ShareLink.percentDecode(creds[0])
                    if (username.isNotEmpty()) {
                        results += Candidate(
                            host, port!!, defaultProtocol ?: protocolForPort(port), username,
                            if (creds.size > 1) ShareLink.percentDecode(creds[1]) else null,
                            "host:port@user:pass", listOf("Read as host:port@username:password."), true
                        )
                    }
                }
            }

            splitHostPort(right)?.takeIf { it.second != null }?.let { (host, port) ->
                if (HostValidator.validate(host).isValid) {
                    val creds = left.split(":", limit = 2)
                    val username = ShareLink.percentDecode(creds[0])
                    if (username.isNotEmpty()) {
                        results += Candidate(
                            host, port!!, defaultProtocol ?: protocolForPort(port), username,
                            if (creds.size > 1) ShareLink.percentDecode(creds[1]) else null,
                            "user:pass@host:port", listOf("Read as username:password@host:port."), false
                        )
                    }
                }
            }
        }
        return results
    }

    private fun interpretSeparatedForms(text: String, defaultProtocol: ProxyProtocol?): List<Candidate> {
        val results = mutableListOf<Candidate>()
        val tokenSets = listOf(
            ":" to text.split(":"),
            " " to text.split(Regex("""[\s]+""")),
            "," to text.split(","),
            ";" to text.split(";")
        )

        for ((_, rawTokens) in tokenSets) {
            val tokens = rawTokens.map { it.trim() }.filter { it.isNotEmpty() }
            if (tokens.size < 2) continue

            if (tokens.size == 2) {
                val port = tokens[1].toIntOrNull()
                if (port != null && port in PortValidator.RANGE && HostValidator.validate(tokens[0]).isValid) {
                    results += Candidate(
                        tokens[0], port, defaultProtocol ?: protocolForPort(port), null, null,
                        "host:port", listOf("No credentials on this line."), true
                    )
                }
                continue
            }

            if (tokens.size < 4) continue

            tokens[1].toIntOrNull()?.takeIf { it in PortValidator.RANGE }?.let { port ->
                if (HostValidator.validate(tokens[0]).isValid) {
                    results += Candidate(
                        tokens[0], port, defaultProtocol ?: protocolForPort(port),
                        tokens[2].ifEmpty { null },
                        tokens.drop(3).joinToString(":").ifEmpty { null },
                        "host:port:user:pass", listOf("Read as host:port:username:password."), true
                    )
                }
            }

            tokens[3].toIntOrNull()?.takeIf { it in PortValidator.RANGE }?.let { port ->
                if (HostValidator.validate(tokens[2]).isValid) {
                    results += Candidate(
                        tokens[2], port, defaultProtocol ?: protocolForPort(port),
                        tokens[0].ifEmpty { null }, tokens[1].ifEmpty { null },
                        "user:pass:host:port", listOf("Read as username:password:host:port."), false
                    )
                }
            }
        }
        return results
    }

    /** Conservative: 443 is used by SOCKS5 providers as often as by TLS proxies. */
    fun protocolForPort(port: Int): ProxyProtocol = when (port) {
        1080, 1081 -> ProxyProtocol.SOCKS5
        3128, 8080, 8888 -> ProxyProtocol.HTTP_CONNECT
        else -> ProxyProtocol.SOCKS5
    }

    /** Splits `host:port`, `[v6]:port`, or a bare host. */
    fun splitHostPort(text: String): Pair<String, Int?>? {
        val value = text.trim()
        if (value.isEmpty()) return null

        if (value.startsWith("[")) {
            val close = value.indexOf(']')
            if (close < 0) return null
            val host = value.substring(1, close)
            if (!host.contains(':')) return null
            val remainder = value.substring(close + 1)
            if (remainder.isEmpty()) return (host to null)
            if (!remainder.startsWith(":")) return null
            val port = remainder.substring(1).toIntOrNull()
            return host to port?.takeIf { it in PortValidator.RANGE }
        }

        if (value.count { it == ':' } > 1) return value to null

        val colon = value.lastIndexOf(':')
        if (colon >= 0) {
            val host = value.substring(0, colon)
            val port = value.substring(colon + 1).toIntOrNull()
            if (host.isEmpty() || port == null || port !in PortValidator.RANGE) return null
            return host to port
        }

        return if (HostValidator.validate(value).isValid) value to null else null
    }
}
