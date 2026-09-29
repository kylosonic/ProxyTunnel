package io.github.kylosonic.proxytunnel.core

/**
 * The proxy protocols this app can speak.
 *
 * Only SOCKS5 gets the full tunnel treatment, because that is the only protocol
 * hev-socks5-tunnel speaks. HTTP CONNECT and HTTPS CONNECT are supported for the
 * connectivity test and for export, and the UI says plainly that they cannot be
 * used as the tunnel's upstream.
 */
enum class ProxyProtocol(val wireName: String, val displayName: String, val defaultPort: Int) {
    SOCKS5("socks5", "SOCKS5", 1080),
    HTTP_CONNECT("http-connect", "HTTP CONNECT", 8080),
    HTTPS_CONNECT("https-connect", "HTTPS CONNECT", 443);

    val supportsTunnelUpstream: Boolean get() = this == SOCKS5

    val usesTls: Boolean get() = this == HTTPS_CONNECT

    /** Remote name resolution: all three let the proxy resolve the name. */
    val supportsRemoteNameResolution: Boolean get() = true

    companion object {
        fun fromWireName(value: String?): ProxyProtocol? =
            entries.firstOrNull { it.wireName.equals(value, ignoreCase = true) }
    }
}

/** A username/password pair, in memory only. */
data class ProxyCredential(val username: String, val password: String) {
    /** Never contains the password. Safe for logs. */
    override fun toString(): String = "ProxyCredential(${LogRedactor.maskUsername(username)}:${LogRedactor.MASK})"
}

/**
 * A configured proxy.
 *
 * There is deliberately no field that *could* hold a password: the profile is
 * plain metadata, and the secret lives in [io.github.kylosonic.proxytunnel.data.SecretStore].
 */
data class ProxyProfile(
    val id: String,
    val name: String,
    val host: String,
    val port: Int,
    val protocol: ProxyProtocol,
    val username: String? = null,
    val hasStoredPassword: Boolean = false,
    val isEnabled: Boolean = true,
    val regionCode: String? = null,
    val notes: String? = null
) {
    val usesAuthentication: Boolean get() = !username.isNullOrEmpty()

    val displayEndpoint: String get() = formatEndpoint(host, port)

    /** `United States` for a known code, the code itself for anything typed by hand. */
    val regionName: String? get() = RegionCatalog.displayName(regionCode)

    /** One line that is safe to log. */
    val redactedSummary: String
        get() = "ProxyProfile(id=${id.take(8)}…, name=\"$name\", endpoint=$displayEndpoint, " +
            "protocol=${protocol.wireName}, region=${regionCode ?: "<none>"}, " +
            "user=${LogRedactor.maskUsername(username)}, " +
            "hasPassword=$hasStoredPassword, enabled=$isEnabled)"

    override fun toString(): String = redactedSummary

    companion object {
        fun formatEndpoint(host: String, port: Int): String =
            if (host.contains(":") && !host.startsWith("[")) "[$host]:$port" else "$host:$port"
    }
}

/** Central place for every "do not log this" rule. */
object LogRedactor {
    const val MASK = "••••••"

    fun maskUsername(username: String?): String {
        if (username.isNullOrEmpty()) return "<none>"
        if (username.length <= 2) return "•".repeat(username.length)
        return "${username.first()}•••${username.last()}"
    }

    private val rules = listOf(
        Regex("""(?i)\b((?:proxy-)?authorization)\s*:\s*[^\r\n]*""") to "$1: $MASK",
        // `user:pass@` in any context, with or without a scheme in front of it. The
        // earlier version of this rule required "//" before the credentials, which
        // left a bare "alice:hunter2@host" line unmasked when it failed to parse.
        Regex("""[^/\s:@]+:[^/\s@]+(?=@)""") to MASK,
        Regex("""(?i)\b(password|passwd|pwd|secret|token|apikey|api_key)\b\s*[:=]\s*("[^"]*"|'[^']*'|[^\s,;&]+)""") to "$1=$MASK",
        Regex("""(?i)\b(username|user)\b\s*[:=]\s*("[^"]*"|'[^']*'|[^\s,;&]+)""") to "$1=$MASK"
    )

    /** Scrub anything credential-shaped out of a message before it is stored. */
    fun redact(message: String): String =
        rules.fold(message) { text, (pattern, replacement) -> pattern.replace(text, replacement) }
}
