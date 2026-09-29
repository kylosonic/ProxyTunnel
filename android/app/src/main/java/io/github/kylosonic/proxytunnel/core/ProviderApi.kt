package io.github.kylosonic.proxytunnel.core

import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets

/**
 * Fetches proxy credentials from a provider's API, for an account **you** own.
 *
 * ## The distinction this feature rests on
 *
 * This is the authorised version of "find me a proxy in country X". It talks to a
 * provider you have an account with, using an API key you generated, and it can only
 * ever return endpoints that provider has assigned to your account and is willing to
 * carry your traffic on. That is why it can exist:
 *
 * * nothing is scraped, and no third-party list is downloaded;
 * * the app never contacts a host you did not configure;
 * * every endpoint returned is one somebody has agreed to let you use, and is being
 *   paid for (a free tier included).
 *
 * The unauthorised version — crawling "free proxy list" sites and auto-connecting to
 * whatever is on them — is deliberately absent. Those lists are open proxies on
 * machines nobody offered you, and a meaningful share are honeypots published so the
 * traffic through them can be read. See `android/README.md`.
 *
 * ## Verification
 *
 * The Webshare endpoint, its `Authorization: Token` header, its `country_code_in`
 * filter and the field names below come from a working third-party implementation
 * ([ProxyProviders](https://github.com/dteather/proxyproviders)) and Webshare's own
 * API reference, not from guesswork. The parser is tested against that exact response
 * shape, including the pagination envelope and the fields a free plan omits.
 *
 * Nothing here is verified against a *live paid account* — that needs credentials this
 * repository does not have. What is verified is that the request this builds and the
 * response it parses match the documented API.
 */
object ProviderApi {

    /** A provider whose API this app knows how to read. */
    enum class Provider(
        val id: String,
        val displayName: String,
        /** Where the user generates their own key. Shown in the UI as a hint only. */
        val consoleHint: String,
        val supportsCountryFilter: Boolean,
        val protocol: ProxyProtocol
    ) {
        WEBSHARE(
            id = "webshare",
            displayName = "Webshare",
            consoleHint = "dashboard.webshare.io → API",
            supportsCountryFilter = true,
            // Their proxies are HTTP CONNECT. The bridge is what makes that usable
            // behind a SOCKS5-only tunnel engine.
            protocol = ProxyProtocol.HTTP_CONNECT
        );

        companion object {
            fun fromId(value: String?): Provider? = entries.firstOrNull { it.id == value }
        }
    }

    /** One endpoint the provider assigned to the account. */
    data class RemoteProxy(
        val host: String,
        val port: Int,
        val username: String?,
        val password: String?,
        val regionCode: String?,
        val city: String?,
        val providerId: String
    ) {
        /** A name a human can tell apart in a list. */
        fun suggestedName(): String {
            val place = listOfNotNull(
                RegionCatalog.displayName(regionCode),
                city?.takeIf { it.isNotBlank() }
            ).joinToString(" · ")
            return listOf(Provider.fromId(providerId)?.displayName ?: providerId, place)
                .filter { it.isNotBlank() }
                .joinToString(" — ")
        }

        /** Never contains credentials. */
        override fun toString(): String =
            "RemoteProxy(${ProxyProfile.formatEndpoint(host, port)}, region=${regionCode ?: "<none>"})"
    }

    sealed class Result {
        data class Success(val proxies: List<RemoteProxy>) : Result()
        data class Failure(val kind: Kind, val message: String, val suggestion: String? = null) : Result()

        enum class Kind { NOT_CONFIGURED, BAD_KEY, RATE_LIMITED, PLAN_LIMIT, NETWORK, UNREADABLE, EMPTY }
    }

    data class Configuration(
        val timeoutMillis: Int = 20_000,
        /** Overridden in tests, which point this at a loopback server. */
        val baseUrl: String = "https://proxy.webshare.io/api/v2"
    )

    /**
     * Lists the account's proxies, optionally narrowed to one country.
     *
     * @param regionCode an ISO 3166-1 alpha-2 code from [RegionCatalog], or null for all.
     */
    fun fetch(
        provider: Provider,
        apiKey: String,
        regionCode: String? = null,
        configuration: Configuration = Configuration()
    ): Result {
        if (apiKey.isBlank()) {
            return Result.Failure(
                Result.Kind.NOT_CONFIGURED,
                "No API key is stored for ${provider.displayName}.",
                "Add one under Proxies ▸ provider settings."
            )
        }
        if (regionCode != null && !provider.supportsCountryFilter) {
            return Result.Failure(
                Result.Kind.UNREADABLE,
                "${provider.displayName} cannot filter by country through its API.",
                "Fetch the whole list, then pick the country from your proxies."
            )
        }

        val collected = mutableListOf<RemoteProxy>()
        var page = 1
        // A free plan has ten proxies; a paid one can have thousands. Ten pages of a
        // hundred is a hard stop so a pagination bug cannot spin forever.
        val maxPages = 10

        while (page <= maxPages) {
            val url = buildListUrl(provider, configuration, regionCode, page)
            val response = when (val attempt = get(url, apiKey, configuration)) {
                is HttpOutcome.Success -> attempt.body
                is HttpOutcome.Failure -> return attempt.result
            }

            val parsed = runCatching { JSONTokener(response).nextValue() }.getOrNull()

            // org.json is lenient: an HTML maintenance page parses as a bare string
            // rather than throwing. Anything that is not an object or an array is not a
            // document, and saying "not JSON" is more useful than "unexpected shape".
            val root = when (parsed) {
                is JSONObject -> parsed
                is JSONArray -> JSONObject().put("results", parsed)
                else -> return Result.Failure(
                    Result.Kind.UNREADABLE,
                    "${provider.displayName} returned something that is not JSON.",
                    "If this repeats, the provider may have changed their API."
                )
            }

            val results = root.optJSONArray("results")
                ?: return Result.Failure(
                    Result.Kind.UNREADABLE,
                    "The response had no \"results\" array.",
                    "The provider's API may have changed."
                )

            for (index in 0 until results.length()) {
                val item = results.optJSONObject(index) ?: continue
                decode(item, provider)?.let { collected += it }
            }

            val hasNext = root.opt("next") != null && root.opt("next").toString() != "null"
            if (!hasNext) break
            page++
        }

        return if (collected.isEmpty()) {
            Result.Failure(
                Result.Kind.EMPTY,
                if (regionCode == null) {
                    "Your ${provider.displayName} account has no proxies on it."
                } else {
                    "Your ${provider.displayName} account has no proxies in ${RegionCatalog.displayName(regionCode)}."
                },
                // The plain empty state, on purpose: no upsell, no pricing, no guess.
                null
            )
        } else {
            Result.Success(collected)
        }
    }

    // MARK: request

    private fun buildListUrl(
        provider: Provider,
        configuration: Configuration,
        regionCode: String?,
        page: Int
    ): String {
        val base = configuration.baseUrl.trimEnd('/')
        val params = mutableListOf(
            "mode=direct",
            "page=$page",
            "page_size=100"
        )
        if (regionCode != null && provider.supportsCountryFilter) {
            params += "country_code_in=" + java.net.URLEncoder.encode(regionCode.uppercase(), "UTF-8")
        }
        return "$base/proxy/list?" + params.joinToString("&")
    }

    private sealed class HttpOutcome {
        data class Success(val body: String) : HttpOutcome()
        data class Failure(val result: Result) : HttpOutcome()
    }

    private fun get(url: String, apiKey: String, configuration: Configuration): HttpOutcome {
        var connection: HttpURLConnection? = null
        return try {
            connection = (URL(url).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = configuration.timeoutMillis
                readTimeout = configuration.timeoutMillis
                setRequestProperty("Authorization", "Token $apiKey")
                setRequestProperty("Accept", "application/json")
                // The key is a bearer credential; never follow a redirect that could
                // hand it to another host.
                instanceFollowRedirects = false
            }

            val code = connection.responseCode
            when {
                code in 200..299 -> {
                    val body = connection.inputStream.bufferedReader(StandardCharsets.UTF_8).use { it.readText() }
                    HttpOutcome.Success(body)
                }
                code == 401 || code == 403 -> HttpOutcome.Failure(
                    Result.Failure(
                        Result.Kind.BAD_KEY,
                        "The provider rejected the API key (HTTP $code).",
                        "Generate a fresh key in your provider dashboard and paste it again."
                    )
                )
                code == 429 -> HttpOutcome.Failure(
                    Result.Failure(
                        Result.Kind.RATE_LIMITED,
                        "The provider is rate-limiting this key (HTTP 429).",
                        "Wait a minute. The app fetches only when you ask it to, so this should be rare."
                    )
                )
                code == 402 || code == 451 -> HttpOutcome.Failure(
                    Result.Failure(
                        Result.Kind.PLAN_LIMIT,
                        "The provider refused the request for this plan (HTTP $code).",
                        "Your plan may not include API access."
                    )
                )
                code in 300..399 -> HttpOutcome.Failure(
                    Result.Failure(
                        Result.Kind.NETWORK,
                        "The provider redirected the request (HTTP $code), which was not followed.",
                        "An API key should not be sent to a different host."
                    )
                )
                else -> HttpOutcome.Failure(
                    Result.Failure(
                        Result.Kind.UNREADABLE,
                        "The provider answered HTTP $code.",
                        null
                    )
                )
            }
        } catch (e: java.net.SocketTimeoutException) {
            HttpOutcome.Failure(
                Result.Failure(
                    Result.Kind.NETWORK,
                    "The provider did not answer in time.",
                    "Check your connection and try again."
                )
            )
        } catch (e: java.net.UnknownHostException) {
            HttpOutcome.Failure(
                Result.Failure(
                    Result.Kind.NETWORK,
                    "The provider's API host could not be resolved.",
                    "Check your connection."
                )
            )
        } catch (e: IOException) {
            HttpOutcome.Failure(
                Result.Failure(
                    Result.Kind.NETWORK,
                    "Could not reach the provider: ${LogRedactor.redact(e.message ?: e.javaClass.simpleName)}",
                    null
                )
            )
        } finally {
            runCatching { connection?.disconnect() }
        }
    }

    // MARK: parsing

    private fun decode(item: JSONObject, provider: Provider): RemoteProxy? {
        val host = item.optString("proxy_address").takeIf { it.isNotBlank() }
            ?: item.optString("host").takeIf { it.isNotBlank() }
            ?: return null
        val port = item.optInt("port", 0)
        if (port !in PortValidator.RANGE) return null

        val validated = HostValidator.validate(host)
        if (validated.issues.any { it.severity == Severity.ERROR }) return null

        val region = item.optString("country_code").takeIf { it.isNotBlank() }
            ?.let { RegionCatalog.byCode(it)?.code ?: it.uppercase().take(2) }

        return RemoteProxy(
            host = validated.sanitized,
            port = port,
            username = item.optString("username").takeIf { it.isNotBlank() },
            password = item.optString("password").takeIf { it.isNotBlank() },
            regionCode = region,
            city = item.optString("city_name").takeIf { it.isNotBlank() && it != "null" },
            providerId = provider.id
        )
    }

    /** A credential-free description of a fetch, for diagnostics. */
    fun describe(provider: Provider, regionCode: String?, found: Int): String =
        "${provider.displayName}: ${if (regionCode == null) "all countries" else RegionCatalog.displayName(regionCode)} " +
            "→ $found ${if (found == 1) "proxy" else "proxies"}"
}
