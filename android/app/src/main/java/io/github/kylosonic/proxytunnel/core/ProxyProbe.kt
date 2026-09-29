package io.github.kylosonic.proxytunnel.core

import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.charset.StandardCharsets

/**
 * The "Test connection" feature: a real end-to-end check that the proxy works.
 *
 * Opens the proxy, asks it to CONNECT to a well-known plain-HTTP host, sends one
 * request through the resulting tunnel, and reports the egress IP the origin
 * server saw. That last value is the proof — it is served by the far end, so if it
 * comes back the proxy really did relay a TCP stream.
 *
 * Plain HTTP on purpose: the check should involve as little machinery as
 * possible, and it needs no TLS-through-tunnel implementation.
 */
object ProxyProbe {

    data class Report(
        val resolvedAddresses: List<String> = emptyList(),
        val dialedAddress: String? = null,
        val handshakeSummary: String? = null,
        val httpStatus: Int? = null,
        val egressIP: String? = null,
        val totalMillis: Long = 0,
        val failureKind: String? = null,
        val failureMessage: String? = null,
        val failureSuggestion: String? = null
    ) {
        val isSuccess: Boolean get() = failureKind == null && httpStatus != null

        val summaryLines: List<String>
            get() {
                val lines = mutableListOf<String>()
                lines += if (resolvedAddresses.isEmpty()) "Proxy host: not resolved"
                else "Proxy host resolved to ${resolvedAddresses.joinToString(", ")}"
                dialedAddress?.let { lines += "TCP connect to $it: OK" }
                handshakeSummary?.let { lines += "Proxy handshake: $it" }
                httpStatus?.let { lines += "HTTP request through the proxy: status $it" }
                egressIP?.let { lines += "Traffic exited via $it" }
                failureMessage?.let { lines += "FAILED — $it" }
                return lines
            }
    }

    data class Configuration(
        val checkHost: String = "api.ipify.org",
        val checkPort: Int = 80,
        val checkPath: String = "/",
        val timeoutMillis: Int = 15_000,
        val resolvedAddresses: List<String>? = null
    )

    fun run(
        profile: ProxyProfile,
        credential: ProxyCredential?,
        configuration: Configuration = Configuration()
    ): Report {
        val started = System.currentTimeMillis()
        fun elapsed() = System.currentTimeMillis() - started

        // Local validation first, so an obviously broken profile never touches the
        // network.
        val hostCheck = HostValidator.validate(profile.host)
        hostCheck.issues.firstOrNull { it.severity == Severity.ERROR }?.let {
            return Report(
                totalMillis = elapsed(), failureKind = "invalidHost",
                failureMessage = "Invalid proxy host", failureSuggestion = it.message
            )
        }
        if (profile.port !in PortValidator.RANGE) {
            return Report(
                totalMillis = elapsed(), failureKind = "invalidPort",
                failureMessage = "Invalid port: ${profile.port} is outside 1-65535"
            )
        }

        val addresses = configuration.resolvedAddresses?.takeIf { it.isNotEmpty() }
            ?: runCatching { java.net.InetAddress.getByName(profile.host).hostAddress?.let { listOf(it) } ?: emptyList() }
                .getOrElse {
                    return Report(
                        totalMillis = elapsed(), failureKind = "proxyUnreachable",
                        failureMessage = "Proxy host not found: could not resolve \"${profile.host}\"",
                        failureSuggestion = "Check the host name and your internet connection."
                    )
                }

        val target = addresses.first()

        val socket = Socket()
        try {
            socket.tcpNoDelay = true
            socket.connect(InetSocketAddress(target, profile.port), configuration.timeoutMillis)
            socket.soTimeout = configuration.timeoutMillis

            val handshake = when (profile.protocol) {
                ProxyProtocol.SOCKS5 -> socks5Handshake(
                    socket, profile, credential, target, configuration.checkHost, configuration.checkPort
                )
                ProxyProtocol.HTTP_CONNECT, ProxyProtocol.HTTPS_CONNECT ->
                    // The probe deliberately does not wrap the proxy link in TLS.
                    // Testing an HTTPS proxy needs a trusted certificate, and the
                    // tunnel's upstream is SOCKS5 anyway; the UI says so.
                    httpConnectHandshake(
                        socket, credential, configuration.checkHost, configuration.checkPort
                    )
            }

            val request = (
                "GET ${configuration.checkPath.ifEmpty { "/" }} HTTP/1.1\r\n" +
                    "Host: ${configuration.checkHost}\r\n" +
                    "User-Agent: ${HttpConnect.DEFAULT_USER_AGENT}\r\n" +
                    "Accept: */*\r\n" +
                    "Connection: close\r\n\r\n"
                ).toByteArray(StandardCharsets.ISO_8859_1)

            socket.getOutputStream().write(request)
            socket.getOutputStream().flush()

            val response = readUntilClosed(socket.getInputStream(), 16 * 1024)
            val terminator = HttpConnect.findHeadTerminator(response)
            if (terminator < 0) {
                return Report(
                    resolvedAddresses = addresses, dialedAddress = target, handshakeSummary = handshake,
                    totalMillis = elapsed(), failureKind = "proxyUnreachable",
                    failureMessage = "Unreadable response: the proxy relayed data but not a valid HTTP response (${response.size} bytes)",
                    failureSuggestion = "Some proxies inject their own error pages or block port 80. The tunnel itself still works if the handshake above succeeded."
                )
            }

            val head = String(response, 0, terminator, StandardCharsets.ISO_8859_1)
            val status = head.lineSequence().firstOrNull()
                ?.split(" ")?.getOrNull(1)?.toIntOrNull()
            val body = String(response, terminator, response.size - terminator, StandardCharsets.UTF_8).trim()

            return Report(
                resolvedAddresses = addresses,
                dialedAddress = target,
                handshakeSummary = handshake,
                httpStatus = status,
                egressIP = extractIP(body),
                totalMillis = elapsed()
            )
        } catch (e: java.net.SocketTimeoutException) {
            return Report(
                resolvedAddresses = addresses, dialedAddress = target,
                totalMillis = elapsed(), failureKind = "connectionTimeout",
                failureMessage = "The proxy (${profile.displayEndpoint}) did not respond in time",
                failureSuggestion = "The port may be blocked by your carrier, or the proxy may be offline. Try another network."
            )
        } catch (e: java.net.ConnectException) {
            return Report(
                resolvedAddresses = addresses, dialedAddress = target,
                totalMillis = elapsed(), failureKind = "proxyUnreachable",
                failureMessage = "Connection refused — nothing is listening on ${profile.displayEndpoint}",
                failureSuggestion = "Check the port and confirm the proxy is running."
            )
        } catch (e: java.net.UnknownHostException) {
            return Report(
                totalMillis = elapsed(), failureKind = "proxyUnreachable",
                failureMessage = "Proxy host not found: ${e.message}"
            )
        } catch (e: Socks5.Socks5Exception) {
            return Report(
                resolvedAddresses = addresses, dialedAddress = target,
                totalMillis = elapsed(), failureKind = "badServerResponse",
                failureMessage = e.message ?: "the proxy misbehaved",
                failureSuggestion = "Make sure the protocol selected matches what the server speaks."
            )
        } catch (e: Exception) {
            return Report(
                resolvedAddresses = addresses, dialedAddress = target,
                totalMillis = elapsed(), failureKind = "internalError",
                failureMessage = "${e.javaClass.simpleName}: ${e.message}"
            )
        } finally {
            runCatching { socket.close() }
        }
    }

    private fun socks5Handshake(
        socket: Socket,
        profile: ProxyProfile,
        credential: ProxyCredential?,
        target: String,
        destinationHost: String,
        destinationPort: Int
    ): String {
        val input = socket.getInputStream()
        val output = socket.getOutputStream()

        output.write(Socks5.greeting(Socks5.defaultMethods(credential != null)))
        output.flush()

        val method = Socks5.parseMethodSelection(readExactly(input, 2))
        when (method) {
            Socks5.METHOD_NONE -> Unit
            Socks5.METHOD_USER_PASSWORD -> {
                val creds = credential ?: throw Socks5.Socks5Exception("the proxy requires authentication but this profile has no username")
                output.write(Socks5.userPasswordRequest(creds.username, creds.password))
                output.flush()
                Socks5.parseUserPasswordResponse(readExactly(input, 2))
            }
            Socks5.METHOD_NO_ACCEPTABLE -> throw Socks5.Socks5Exception(
                if (credential == null) "the proxy requires authentication but this profile has no username"
                else "the proxy rejected every authentication method offered"
            )
            else -> throw Socks5.Socks5Exception("unsupported authentication method 0x%02x".format(method))
        }

        output.write(Socks5.request(Socks5.CMD_CONNECT, destinationHost, destinationPort))
        output.flush()

        // The reply is variable length, so read the four-byte header then the rest.
        val header = readExactly(input, 4)
        val atyp = header[3]
        val rest = when (atyp) {
            Socks5.ATYP_IPV4 -> readExactly(input, 6)
            Socks5.ATYP_IPV6 -> readExactly(input, 18)
            Socks5.ATYP_DOMAIN -> {
                val length = readExactly(input, 1)[0].toInt() and 0xFF
                readExactly(input, length + 2)
            }
            else -> throw Socks5.Socks5Exception("unknown address type 0x%02x".format(atyp))
        }
        val reply = Socks5.parseReply(header + rest)
        if (reply.code != 0) {
            throw Socks5.Socks5Exception("the proxy refused the connection (${Socks5.replyName(reply.code)})")
        }
        return "SOCKS5 CONNECT to $destinationHost:$destinationPort succeeded"
    }

    private fun httpConnectHandshake(
        socket: Socket,
        credential: ProxyCredential?,
        destinationHost: String,
        destinationPort: Int
    ): String {
        val input = socket.getInputStream()
        val output = socket.getOutputStream()

        output.write(HttpConnect.request(destinationHost, destinationPort, credential))
        output.flush()

        val buffer = java.io.ByteArrayOutputStream()
        while (HttpConnect.findHeadTerminator(buffer.toByteArray()) < 0) {
            val chunk = input.read()
            if (chunk < 0) throw Socks5.Socks5Exception("the proxy closed the connection during the CONNECT handshake")
            buffer.write(chunk)
            if (buffer.size() > 32 * 1024) throw Socks5.Socks5Exception("the proxy sent more than 32 KiB without completing the handshake")
        }

        val response = HttpConnect.parseResponseHead(buffer.toByteArray())
        if (!response.isSuccess) {
            if (response.isAuthenticationChallenge) {
                throw Socks5.Socks5Exception(
                    if (credential == null) "the proxy requires authentication but this profile has no username"
                    else "the proxy rejected the username or password"
                )
            }
            throw Socks5.Socks5Exception("the proxy refused the connection (${response.summary})")
        }
        return "HTTP CONNECT to $destinationHost:$destinationPort succeeded"
    }

    private fun readExactly(input: InputStream, count: Int): ByteArray {
        val buffer = ByteArray(count)
        var read = 0
        while (read < count) {
            val n = input.read(buffer, read, count - read)
            if (n < 0) throw Socks5.IncompleteException(count - read)
            read += n
        }
        return buffer
    }

    private fun readUntilClosed(input: InputStream, limit: Int): ByteArray {
        val buffer = java.io.ByteArrayOutputStream()
        val chunk = ByteArray(4096)
        while (buffer.size() < limit) {
            // A plain try/catch rather than runCatching + getOrElse { break }: a break
            // inside an inline lambda needs an opt-in the compiler does not grant by
            // default, and a socket reset here is an ordinary end of stream anyway.
            val n = try {
                input.read(chunk)
            } catch (e: Exception) {
                -1
            }
            if (n < 0) break
            buffer.write(chunk, 0, n)
        }
        return buffer.toByteArray()
    }

    /** Extracts a plausible IP from a tiny text body, as api.ipify.org serves. */
    fun extractIP(body: String): String? {
        val text = body.trim()
        if (text.isEmpty()) return null
        val candidate = text.split(Regex("""[\s]+""")).firstOrNull() ?: text
        return if (HostValidator.validate(candidate).kind?.isLiteral == true) candidate else text.take(80)
    }
}
