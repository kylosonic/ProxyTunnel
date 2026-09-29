package io.github.kylosonic.proxytunnel.core

/**
 * Host, port and whole-profile validation.
 *
 * A direct port of the Swift validators, deliberately kept behaviour-compatible
 * so that a proxy accepted on one platform is accepted on the other. The messages
 * are the same too, because they were written to be actionable.
 */

enum class Severity { ERROR, WARNING }

data class ValidationIssue(
    val field: Field,
    val severity: Severity,
    val message: String
) {
    enum class Field { NAME, HOST, PORT, PROTOCOL, USERNAME, PASSWORD, NOTES, GENERAL }

    companion object {
        fun error(field: Field, message: String) = ValidationIssue(field, Severity.ERROR, message)
        fun warning(field: Field, message: String) = ValidationIssue(field, Severity.WARNING, message)
    }
}

class ValidationReport(val issues: List<ValidationIssue> = emptyList()) {
    val errors: List<ValidationIssue> get() = issues.filter { it.severity == Severity.ERROR }
    val warnings: List<ValidationIssue> get() = issues.filter { it.severity == Severity.WARNING }
    val isValid: Boolean get() = errors.isEmpty()

    fun firstError(field: ValidationIssue.Field): ValidationIssue? =
        issues.firstOrNull { it.field == field && it.severity == Severity.ERROR }

    fun firstMessage(field: ValidationIssue.Field): String? =
        issues.firstOrNull { it.field == field }?.message

    val summary: String
        get() = if (issues.isEmpty()) "OK" else issues.joinToString("; ") { "${it.severity.name.lowercase()}: ${it.field.name.lowercase()}: ${it.message}" }
}

/** What kind of thing the user typed into the host field. */
sealed class HostKind {
    data class Ipv4(val address: String) : HostKind()
    data class Ipv6(val address: String) : HostKind()
    data class Hostname(val name: String) : HostKind()

    val isLiteral: Boolean get() = this !is Hostname
}

object Sanitizer {
    /** Trim, and drop zero-width and bidi controls that could spoof a host. */
    fun clean(raw: String): String {
        val builder = StringBuilder()
        for (ch in raw) {
            val code = ch.code
            val zeroWidthOrBidi = (code in 0x200B..0x200F) || (code in 0x202A..0x202E) ||
                (code in 0x2060..0x206F) || code == 0xFEFF
            if (!zeroWidthOrBidi) builder.append(ch)
        }
        return builder.toString().trim()
    }

    fun containsControlCharacters(text: String): Boolean =
        text.any { it.code < 0x20 || it.code in 0x7F..0x9F }
}

object HostValidator {
    const val MAX_HOSTNAME_LENGTH = 253
    const val MAX_LABEL_LENGTH = 63

    private val IPV4 = Regex("""^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$""")
    private val IPV6 = Regex("""^[0-9A-Fa-f:]+$""")

    data class Result(val sanitized: String, val kind: HostKind?, val issues: List<ValidationIssue>) {
        val isValid: Boolean get() = issues.none { it.severity == Severity.ERROR }
    }

    fun validate(raw: String): Result {
        val issues = mutableListOf<ValidationIssue>()
        var text = Sanitizer.clean(raw)

        if (text.isEmpty()) {
            return Result("", null, listOf(ValidationIssue.error(ValidationIssue.Field.HOST, "Host is required.")))
        }

        if (Sanitizer.containsControlCharacters(text)) {
            issues += ValidationIssue.error(ValidationIssue.Field.HOST, "Host contains control characters.")
            text = text.filter { it.code >= 0x20 && it.code !in 0x7F..0x9F }
        }

        // Embedded credentials.
        val at = text.lastIndexOf('@')
        if (at > 0) {
            val userInfo = text.substring(0, at)
            // Never repeat what was typed before the '@'. It is usually a password,
            // and this message is rendered in the UI and can end up in a log.
            val description = if (userInfo.contains(':')) {
                "they look like a username and password"
            } else {
                "\"${LogRedactor.maskUsername(userInfo)}\" looks like a username"
            }
            issues += ValidationIssue.error(
                ValidationIssue.Field.HOST,
                "Remove the text before the @ from the host — $description. " +
                    "Enter the username and password in their own fields."
            )
            text = text.substring(at + 1)
        }

        // URL scheme.
        val schemeIndex = text.indexOf("://")
        if (schemeIndex > 0) {
            val scheme = text.substring(0, schemeIndex).lowercase()
            issues += ValidationIssue.warning(
                ValidationIssue.Field.HOST,
                "Removed the \"$scheme://\" prefix. The protocol is chosen in the Protocol field; the host is stored on its own."
            )
            text = text.substring(schemeIndex + 3)
        }

        // Path / query.
        val slash = text.indexOf('/')
        if (slash >= 0) {
            issues += ValidationIssue.warning(
                ValidationIssue.Field.HOST,
                "Removed the path \"/${text.substring(slash + 1)}\" from the host."
            )
            text = text.substring(0, slash)
        }
        val query = text.indexOfFirst { it == '?' || it == '#' }
        if (query >= 0) {
            text = text.substring(0, query)
            issues += ValidationIssue.warning(ValidationIssue.Field.HOST, "Removed the query string from the host.")
        }

        if (text.any { it == ' ' || it == '\t' }) {
            issues += ValidationIssue.error(ValidationIssue.Field.HOST, "Host must not contain spaces.")
            text = text.replace(" ", "").replace("\t", "")
        }

        // Bracketed IPv6.
        var bracketed = false
        if (text.startsWith("[") && text.endsWith("]") && text.length > 2) {
            bracketed = true
            text = text.substring(1, text.length - 1)
        }

        // A port inside the host field. Only a single colon, so IPv6 is untouched.
        if (!bracketed && text.count { it == ':' } == 1) {
            val colon = text.indexOf(':')
            val maybePort = text.substring(colon + 1)
            if (maybePort.isNotEmpty() && maybePort.toIntOrNull() != null) {
                issues += ValidationIssue.error(
                    ValidationIssue.Field.HOST,
                    "Host must not include a port. Put $maybePort in the Port field and keep the host as \"${text.substring(0, colon)}\"."
                )
                text = text.substring(0, colon)
            }
        }

        if (text.isEmpty()) {
            issues += ValidationIssue.error(ValidationIssue.Field.HOST, "Host is required.")
            return Result("", null, issues)
        }

        // IPv4 literal.
        IPV4.matchEntire(text)?.let { match ->
            val octets = (1..4).map { match.groupValues[it].toInt() }
            if (octets.all { it in 0..255 }) {
                val canonical = octets.joinToString(".")
                if (canonical == "0.0.0.0") {
                    issues += ValidationIssue.error(ValidationIssue.Field.HOST, "$canonical is not a usable proxy address.")
                } else if (octets[0] == 127) {
                    issues += ValidationIssue.warning(
                        ValidationIssue.Field.HOST,
                        "$canonical is the local loopback address. Inside the tunnel this points at your own device, not at a proxy."
                    )
                } else if (octets[0] == 169 && octets[1] == 254) {
                    issues += ValidationIssue.warning(
                        ValidationIssue.Field.HOST,
                        "$canonical is a link-local address; it is only reachable on the local network and cannot be used from cellular."
                    )
                }
                return Result(canonical, HostKind.Ipv4(canonical), issues)
            }
            issues += ValidationIssue.error(
                ValidationIssue.Field.HOST,
                "\"$text\" is not a valid IPv4 address. Check the octets (each must be 0-255)."
            )
            return Result(text, null, issues)
        }

        // IPv6 literal.
        if (text.contains(':')) {
            if (isIpv6Literal(text)) {
                return Result(text, HostKind.Ipv6(text), issues)
            }
            issues += ValidationIssue.error(ValidationIssue.Field.HOST, "\"$text\" is not a valid IPv6 address.")
            return Result(text, null, issues)
        }

        // Something that looks like a broken IPv4 literal.
        if (text.all { it.isDigit() || it == '.' } && text.contains('.')) {
            issues += ValidationIssue.error(
                ValidationIssue.Field.HOST,
                "\"$text\" is not a valid IPv4 address. Check the octets (each must be 0-255)."
            )
            return Result(text, null, issues)
        }

        // Host name.
        val lowered = text.lowercase()
        if (lowered.length > MAX_HOSTNAME_LENGTH) {
            issues += ValidationIssue.error(ValidationIssue.Field.HOST, "Host name is longer than $MAX_HOSTNAME_LENGTH characters.")
        }
        if (lowered.contains("..")) {
            issues += ValidationIssue.error(ValidationIssue.Field.HOST, "Host name contains an empty label (\"..\").")
        }

        val labels = lowered.split(".")
        for (label in labels.filter { it.isNotEmpty() }) {
            if (label.length > MAX_LABEL_LENGTH) {
                issues += ValidationIssue.error(ValidationIssue.Field.HOST, "The label \"$label\" is longer than $MAX_LABEL_LENGTH characters.")
            }
            if (label.startsWith("-") || label.endsWith("-")) {
                issues += ValidationIssue.error(ValidationIssue.Field.HOST, "The label \"$label\" must not start or end with a hyphen.")
            }
            val allowed = label.all { it.isLetterOrDigit() || it == '-' }
            if (!allowed) {
                if (label.contains('_')) {
                    issues += ValidationIssue.warning(
                        ValidationIssue.Field.HOST,
                        "The label \"$label\" contains an underscore, which is not valid in a DNS host name but is sometimes used by internal proxies."
                    )
                } else if (label.any { it.code > 127 }) {
                    issues += ValidationIssue.warning(
                        ValidationIssue.Field.HOST,
                        "The label \"$label\" contains non-ASCII characters. DNS will need it in punycode (xn--) form on some networks."
                    )
                } else {
                    issues += ValidationIssue.error(ValidationIssue.Field.HOST, "The label \"$label\" contains characters that are not allowed in a host name.")
                }
            }
        }

        if (labels.count { it.isNotEmpty() } == 1) {
            issues += ValidationIssue.warning(
                ValidationIssue.Field.HOST,
                "Single-label host names only resolve on networks that provide a local search domain. If this is a public proxy, enter its full name."
            )
        }
        if (lowered.endsWith(".local")) {
            issues += ValidationIssue.warning(
                ValidationIssue.Field.HOST,
                "\".local\" names are resolved with multicast DNS on the local network and cannot be reached through a remote proxy."
            )
        }
        if (lowered == "localhost") {
            issues += ValidationIssue.warning(ValidationIssue.Field.HOST, "\"localhost\" refers to the phone itself, not to a remote proxy.")
        }

        return Result(lowered, HostKind.Hostname(lowered), issues)
    }

    /** Numeric IPv6 validation without pulling in a networking library. */
    fun isIpv6Literal(text: String): Boolean {
        if (text.count { it == ':' } < 2) return false
        if (!IPV6.matches(text)) return false

        val doubleColon = text.indexOf("::")
        if (text.indexOf("::", doubleColon + 1) >= 0) return false

        val groups = if (doubleColon >= 0) {
            val head = text.substring(0, doubleColon)
            val tail = text.substring(doubleColon + 2)
            val headParts = if (head.isEmpty()) emptyList() else head.split(":")
            val tailParts = if (tail.isEmpty()) emptyList() else tail.split(":")
            if (headParts.any { it.isEmpty() } || tailParts.any { it.isEmpty() }) return false
            headParts + tailParts
        } else {
            val parts = text.split(":")
            if (parts.any { it.isEmpty() }) return false
            parts
        }

        if (groups.size > 8) return false
        if (doubleColon < 0 && groups.size != 8) return false
        if (doubleColon >= 0 && groups.size >= 8) return false

        // A dotted-quad tail may occupy the last two groups.
        var hexGroups = groups
        if (groups.isNotEmpty() && groups.last().contains('.')) {
            val quad = groups.last().split(".")
            if (quad.size != 4 || quad.any { it.toIntOrNull()?.let { v -> v in 0..255 } != true }) return false
            hexGroups = groups.dropLast(1)
        }
        return hexGroups.all { it.length <= 4 && it.all { c -> c.isDigit() || c.lowercaseChar() in 'a'..'f' } }
    }
}

object PortValidator {
    val RANGE = 1..65535

    data class Result(val sanitized: String, val value: Int?, val issues: List<ValidationIssue>) {
        val isValid: Boolean get() = issues.none { it.severity == Severity.ERROR }
    }

    fun validate(raw: String, protocol: ProxyProtocol? = null): Result {
        val issues = mutableListOf<ValidationIssue>()
        val text = Sanitizer.clean(raw)

        if (text.isEmpty()) {
            return Result("", null, listOf(ValidationIssue.error(ValidationIssue.Field.PORT, "Port is required.")))
        }
        if (!text.all { it.isDigit() && it.code < 128 }) {
            return Result(text, null, listOf(ValidationIssue.error(ValidationIssue.Field.PORT, "Port must contain digits only.")))
        }
        val value = text.toIntOrNull()
            ?: return Result(text, null, listOf(ValidationIssue.error(ValidationIssue.Field.PORT, "Port is not a valid number.")))
        if (value !in RANGE) {
            return Result(
                text, null,
                listOf(ValidationIssue.error(ValidationIssue.Field.PORT, "Port must be between ${RANGE.first} and ${RANGE.last}."))
            )
        }

        if (value < 1024) {
            issues += ValidationIssue.warning(
                ValidationIssue.Field.PORT,
                "Ports below 1024 are reserved for well-known services. Make sure $value is really your proxy's port."
            )
        }

        if (protocol != null) {
            val mismatched = when (protocol) {
                ProxyProtocol.SOCKS5 -> value == 80 || value == 443 || value == 8080
                ProxyProtocol.HTTP_CONNECT -> value == 1080 || value == 1081
                ProxyProtocol.HTTPS_CONNECT -> value == 1080 || value == 8080
            }
            if (mismatched) {
                issues += ValidationIssue.warning(
                    ValidationIssue.Field.PORT,
                    "$value is unusual for ${protocol.displayName} (the usual port is ${protocol.defaultPort}). Double-check that the protocol and port match what your provider gave you."
                )
            }
        }

        return Result(value.toString(), value, issues)
    }
}
