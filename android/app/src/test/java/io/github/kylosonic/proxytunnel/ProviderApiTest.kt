package io.github.kylosonic.proxytunnel

import io.github.kylosonic.proxytunnel.core.ProviderApi
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests for the provider API client.
 *
 * These run against a real HTTP server on loopback that answers with the documented
 * Webshare response shape, so they exercise the whole path: URL construction, the
 * `Authorization: Token` header, status handling, pagination and JSON parsing.
 */
class ProviderApiTest {

    private val provider = ProviderApi.Provider.WEBSHARE

    private fun oneProxy(
        address: String = "203.0.113.7",
        port: Int = 8080,
        country: String = "NL",
        city: String = "Amsterdam",
        username: String = "alice",
        password: String = "hunter2"
    ) = """
        {
          "id": 1,
          "username": "$username",
          "password": "$password",
          "proxy_address": "$address",
          "port": $port,
          "valid": true,
          "country_code": "$country",
          "city_name": "$city",
          "created_at": "2026-01-01T00:00:00Z"
        }
    """.trimIndent()

    private fun envelope(vararg items: String, next: String? = null) = """
        {
          "count": ${items.size},
          "next": ${if (next == null) "null" else "\"$next\""},
          "previous": null,
          "results": [${items.joinToString(",")}]
        }
    """.trimIndent()

    private fun configuration(server: FakeProviderServer, timeoutMillis: Int = 5_000) =
        ProviderApi.Configuration(timeoutMillis = timeoutMillis, baseUrl = server.baseUrl)

    // MARK: the happy path

    @Test
    fun `a country lookup sends the documented query and header, and parses the result`() {
        FakeProviderServer { _, _ -> 200 to envelope(oneProxy()) }.use { server ->
            val result = ProviderApi.fetch(provider, "secret-key", "NL", configuration(server))

            assertTrue(result.toString(), result is ProviderApi.Result.Success)
            val proxies = (result as ProviderApi.Result.Success).proxies
            assertEquals(1, proxies.size)

            val proxy = proxies[0]
            assertEquals("203.0.113.7", proxy.host)
            assertEquals(8080, proxy.port)
            assertEquals("alice", proxy.username)
            assertEquals("hunter2", proxy.password)
            assertEquals("NL", proxy.regionCode)
            assertEquals("Amsterdam", proxy.city)

            // The request the provider would actually receive.
            assertEquals(1, server.requests.size)
            val target = server.requests[0]
            assertTrue(target, target.startsWith("/api/v2/proxy/list?"))
            assertTrue(target, target.contains("mode=direct"))
            assertTrue(target, target.contains("page=1"))
            assertTrue(target, target.contains("page_size=100"))
            assertTrue(target, target.contains("country_code_in=NL"))
            assertEquals("Token secret-key", server.lastAuthorization)
        }
    }

    @Test
    fun `no country filter means no country_code_in parameter`() {
        FakeProviderServer { _, _ -> 200 to envelope(oneProxy()) }.use { server ->
            val result = ProviderApi.fetch(provider, "k", null, configuration(server))
            assertTrue(result is ProviderApi.Result.Success)
            assertFalse(server.requests[0].contains("country_code_in"))
        }
    }

    @Test
    fun `a country code is upper cased before it is sent`() {
        FakeProviderServer { _, _ -> 200 to envelope(oneProxy()) }.use { server ->
            ProviderApi.fetch(provider, "k", "nl", configuration(server))
            assertTrue(server.requests[0], server.requests[0].contains("country_code_in=NL"))
        }
    }

    @Test
    fun `a suggested name reads like something a person would recognise`() {
        FakeProviderServer { _, _ -> 200 to envelope(oneProxy()) }.use { server ->
            val result = ProviderApi.fetch(provider, "k", "NL", configuration(server))
            val proxy = (result as ProviderApi.Result.Success).proxies[0]
            assertEquals("Webshare — Netherlands · Amsterdam", proxy.suggestedName())
        }
    }

    @Test
    fun `a suggested name copes with a missing city`() {
        FakeProviderServer { _, _ -> 200 to envelope(oneProxy(city = "null")) }.use { server ->
            val result = ProviderApi.fetch(provider, "k", "NL", configuration(server))
            val proxy = (result as ProviderApi.Result.Success).proxies[0]
            assertNull(proxy.city)
            assertEquals("Webshare — Netherlands", proxy.suggestedName())
        }
    }

    @Test
    fun `a proxy with no country still lists, named by what is known about it`() {
        FakeProviderServer { _, _ -> 200 to envelope(oneProxy(country = "")) }.use { server ->
            val result = ProviderApi.fetch(provider, "k", null, configuration(server))
            val proxy = (result as ProviderApi.Result.Success).proxies[0]
            assertNull(proxy.regionCode)
            // No country, but the city is known and naming it is more useful than not.
            assertEquals("Webshare — Amsterdam", proxy.suggestedName())
        }
    }

    @Test
    fun `a remote proxy never prints its password`() {
        FakeProviderServer { _, _ -> 200 to envelope(oneProxy()) }.use { server ->
            val result = ProviderApi.fetch(provider, "k", "NL", configuration(server))
            val proxy = (result as ProviderApi.Result.Success).proxies[0]
            assertFalse(proxy.toString().contains("hunter2"))
            assertFalse(proxy.toString().contains("alice"))
            assertTrue(proxy.toString().contains("203.0.113.7:8080"))
        }
    }

    // MARK: the empty state the user asked for

    @Test
    fun `nothing in that country is reported plainly, with no sales pitch`() {
        FakeProviderServer { _, _ -> 200 to envelope() }.use { server ->
            val result = ProviderApi.fetch(provider, "k", "JP", configuration(server))

            assertTrue(result is ProviderApi.Result.Failure)
            val failure = result as ProviderApi.Result.Failure
            assertEquals(ProviderApi.Result.Kind.EMPTY, failure.kind)
            assertEquals("Your Webshare account has no proxies in Japan.", failure.message)
            // Deliberately absent: no upgrade hint, no pricing, no "try another plan".
            assertNull(failure.suggestion)
        }
    }

    @Test
    fun `an account with no proxies at all is reported plainly too`() {
        FakeProviderServer { _, _ -> 200 to envelope() }.use { server ->
            val result = ProviderApi.fetch(provider, "k", null, configuration(server))
            val failure = result as ProviderApi.Result.Failure
            assertEquals(ProviderApi.Result.Kind.EMPTY, failure.kind)
            assertEquals("Your Webshare account has no proxies on it.", failure.message)
            assertNull(failure.suggestion)
        }
    }

    // MARK: failures

    @Test
    fun `a rejected key is reported as a bad key, and the key is not echoed`() {
        FakeProviderServer { _, _ -> 401 to """{"detail":"Invalid token"}""" }.use { server ->
            val result = ProviderApi.fetch(provider, "super-secret", "NL", configuration(server))
            val failure = result as ProviderApi.Result.Failure
            assertEquals(ProviderApi.Result.Kind.BAD_KEY, failure.kind)
            assertTrue(failure.message, failure.message.contains("401"))
            assertFalse(failure.message, failure.message.contains("super-secret"))
            assertFalse(failure.suggestion!!, failure.suggestion!!.contains("super-secret"))
        }
    }

    @Test
    fun `rate limiting is reported as such`() {
        FakeProviderServer { _, _ -> 429 to """{"detail":"throttled"}""" }.use { server ->
            val result = ProviderApi.fetch(provider, "k", "NL", configuration(server))
            val failure = result as ProviderApi.Result.Failure
            assertEquals(ProviderApi.Result.Kind.RATE_LIMITED, failure.kind)
            assertTrue(failure.suggestion!!, failure.suggestion!!.contains("Wait"))
        }
    }

    @Test
    fun `a plan that does not include the API is reported as a plan limit`() {
        FakeProviderServer { _, _ -> 402 to """{"detail":"upgrade"}""" }.use { server ->
            val result = ProviderApi.fetch(provider, "k", "NL", configuration(server))
            assertEquals(ProviderApi.Result.Kind.PLAN_LIMIT, (result as ProviderApi.Result.Failure).kind)
        }
    }

    @Test
    fun `a redirect is refused rather than followed with the key attached`() {
        FakeProviderServer { _, _ -> 302 to "" }.use { server ->
            val result = ProviderApi.fetch(provider, "k", "NL", configuration(server))
            val failure = result as ProviderApi.Result.Failure
            assertEquals(ProviderApi.Result.Kind.NETWORK, failure.kind)
            assertTrue(failure.message, failure.message.contains("302"))
            assertTrue(failure.suggestion!!, failure.suggestion!!.contains("different host"))
            // Exactly one request: nothing followed the Location header.
            assertEquals(1, server.requests.size)
        }
    }

    @Test
    fun `an unconfigured key fails before any network call is made`() {
        FakeProviderServer { _, _ -> 200 to envelope(oneProxy()) }.use { server ->
            val result = ProviderApi.fetch(provider, "   ", "NL", configuration(server))
            val failure = result as ProviderApi.Result.Failure
            assertEquals(ProviderApi.Result.Kind.NOT_CONFIGURED, failure.kind)
            assertTrue(failure.message, failure.message.contains("No API key"))
            assertEquals(0, server.requests.size)
        }
    }

    @Test
    fun `a server that is down is reported as a network problem`() {
        val port = TestNet.closedPort()
        val result = ProviderApi.fetch(
            provider, "k", "NL",
            ProviderApi.Configuration(timeoutMillis = 3_000, baseUrl = "http://${TestNet.LOOPBACK}:$port/api/v2")
        )
        val failure = result as ProviderApi.Result.Failure
        assertEquals(ProviderApi.Result.Kind.NETWORK, failure.kind)
    }

    @Test
    fun `a server that never answers times out instead of hanging`() {
        java.net.ServerSocket(0, 5, java.net.InetAddress.getByName(TestNet.LOOPBACK)).use { silent ->
            val started = System.currentTimeMillis()
            val result = ProviderApi.fetch(
                provider, "k", "NL",
                ProviderApi.Configuration(
                    timeoutMillis = 1_000,
                    baseUrl = "http://${TestNet.LOOPBACK}:${silent.localPort}/api/v2"
                )
            )
            val elapsed = System.currentTimeMillis() - started
            assertEquals(ProviderApi.Result.Kind.NETWORK, (result as ProviderApi.Result.Failure).kind)
            assertTrue("took ${elapsed}ms", elapsed < 8_000)
        }
    }

    @Test
    fun `a body that is not json is reported as unreadable`() {
        FakeProviderServer { _, _ -> 200 to "<html>maintenance</html>" }.use { server ->
            val result = ProviderApi.fetch(provider, "k", "NL", configuration(server))
            val failure = result as ProviderApi.Result.Failure
            assertEquals(ProviderApi.Result.Kind.UNREADABLE, failure.kind)
            assertTrue(failure.message, failure.message.contains("not JSON"))
        }
    }

    @Test
    fun `a json body with no results array is reported as unreadable`() {
        FakeProviderServer { _, _ -> 200 to """{"detail":"changed"}""" }.use { server ->
            val result = ProviderApi.fetch(provider, "k", "NL", configuration(server))
            val failure = result as ProviderApi.Result.Failure
            assertEquals(ProviderApi.Result.Kind.UNREADABLE, failure.kind)
            assertTrue(failure.message, failure.message.contains("results"))
        }
    }

    // MARK: resilience

    @Test
    fun `one malformed entry does not discard the good ones`() {
        val broken = """{"username":"a","password":"b","proxy_address":"203.0.113.7","port":99999}"""
        val noHost = """{"username":"a","password":"b","port":8080}"""
        val good = oneProxy(address = "198.51.100.4", port = 3128, country = "DE", city = "Berlin")

        FakeProviderServer { _, _ -> 200 to envelope(broken, noHost, good) }.use { server ->
            val result = ProviderApi.fetch(provider, "k", null, configuration(server))
            val proxies = (result as ProviderApi.Result.Success).proxies
            assertEquals(1, proxies.size)
            assertEquals("198.51.100.4", proxies[0].host)
            assertEquals("DE", proxies[0].regionCode)
        }
    }

    @Test
    fun `pagination follows next until it is null`() {
        val server = FakeProviderServer { target, _ ->
            if (target.contains("page=2")) {
                200 to envelope(oneProxy(address = "198.51.100.9"), next = null)
            } else {
                200 to envelope(oneProxy(address = "203.0.113.7"), next = "https://proxy.webshare.io/api/v2/proxy/list?page=2")
            }
        }
        server.use {
            val result = ProviderApi.fetch(provider, "k", null, configuration(server))
            val proxies = (result as ProviderApi.Result.Success).proxies
            assertEquals(2, proxies.size)
            assertEquals(listOf("203.0.113.7", "198.51.100.9"), proxies.map { it.host })
            assertEquals(2, server.requests.size)
            assertTrue(server.requests[1].contains("page=2"))
        }
    }

    @Test
    fun `pagination stops at a hard cap instead of looping forever`() {
        // A provider that always says there is another page must not spin.
        FakeProviderServer { _, _ ->
            200 to envelope(oneProxy(), next = "https://proxy.webshare.io/api/v2/proxy/list?page=999")
        }.use { server ->
            val result = ProviderApi.fetch(provider, "k", null, configuration(server))
            assertTrue(result is ProviderApi.Result.Success)
            assertEquals(10, server.requests.size)
        }
    }

    @Test
    fun `a national provider code that is not in our catalogue is kept as typed`() {
        FakeProviderServer { _, _ -> 200 to envelope(oneProxy(country = "ZZ")) }.use { server ->
            val result = ProviderApi.fetch(provider, "k", null, configuration(server))
            val proxy = (result as ProviderApi.Result.Success).proxies[0]
            // Not silently dropped, and not mistaken for a country we know.
            assertEquals("ZZ", proxy.regionCode)
        }
    }

    @Test
    fun `a lower case country code from the provider is normalised`() {
        FakeProviderServer { _, _ -> 200 to envelope(oneProxy(country = "nl")) }.use { server ->
            val result = ProviderApi.fetch(provider, "k", null, configuration(server))
            val proxy = (result as ProviderApi.Result.Success).proxies[0]
            assertEquals("NL", proxy.regionCode)
            assertEquals("Netherlands", io.github.kylosonic.proxytunnel.core.RegionCatalog.displayName(proxy.regionCode))
        }
    }

    @Test
    fun `the provider id round trips`() {
        assertEquals(ProviderApi.Provider.WEBSHARE, ProviderApi.Provider.fromId("webshare"))
        assertNull(ProviderApi.Provider.fromId("nope"))
        assertNull(ProviderApi.Provider.fromId(null))
        assertTrue(ProviderApi.Provider.WEBSHARE.supportsCountryFilter)
        // Their plans are HTTP CONNECT, which is exactly why the bridge exists.
        assertEquals(
            io.github.kylosonic.proxytunnel.core.ProxyProtocol.HTTP_CONNECT,
            ProviderApi.Provider.WEBSHARE.protocol
        )
    }

    @Test
    fun `the diagnostic line names the country and the count`() {
        val line = ProviderApi.describe(provider, "NL", 3)
        assertTrue(line, line.contains("Webshare"))
        assertTrue(line, line.contains("Netherlands"))
        assertTrue(line, line.contains("3 proxies"))
        assertTrue(ProviderApi.describe(provider, null, 1).contains("all countries"))
    }
}
