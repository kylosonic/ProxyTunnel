package io.github.kylosonic.proxytunnel

import io.github.kylosonic.proxytunnel.core.RegionCatalog
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests for the location labels.
 *
 * The interesting case is the two-letter code. `in` is the English word "in", `us`
 * is a pronoun, `no` is a word, and `id`/`it`/`me` are all ordinary text — so a
 * naive case-insensitive code match would label a proxy "Proxy in Germany" as being
 * in India. These tests pin down the rule that prevents it.
 */
class RegionsTest {

    @Test
    fun `finds a country named by its full name`() {
        assertEquals("DE", RegionCatalog.guess("Proxy in Germany")?.code)
        assertEquals("NL", RegionCatalog.guess("Netherlands gateway")?.code)
    }

    @Test
    fun `the word in does not mean India`() {
        // The regression this whole two-pass design exists for.
        assertEquals("DE", RegionCatalog.guess("Proxy in Germany")?.code)
        assertEquals("FR", RegionCatalog.guess("cheap proxy in France")?.code)
        assertEquals("CA", RegionCatalog.guess("node in Canada")?.code)
    }

    @Test
    fun `a lowercase two letter code alone is not a location`() {
        // "us", "no", "in", "it" as ordinary words must not resolve.
        assertNull(RegionCatalog.guess("us"))
        assertNull(RegionCatalog.guess("no"))
        assertNull(RegionCatalog.guess("id"))
    }

    @Test
    fun `an uppercase two letter code is a location`() {
        assertEquals("US", RegionCatalog.guess("ProxyCheap US")?.code)
        assertEquals("SG", RegionCatalog.guess("SG gateway")?.code)
        assertEquals("NL", RegionCatalog.guess("NL")?.code)
        assertEquals("GB", RegionCatalog.guess("UK endpoint")?.code)
    }

    @Test
    fun `a bare lowercase code is left alone on purpose`() {
        // Deliberate false negative: "nl" could be the Dutch country code or a
        // fragment of something else, and a wrong country label is worse than no
        // label, because the location picker would route to the wrong place.
        assertNull(RegionCatalog.guess("nl"))
        assertNull(RegionCatalog.guess("de"))
    }

    @Test
    fun `a code glued to other characters is not a location`() {
        // Being conservative here is the point: a false label is worse than none,
        // because the location picker would then route you to the wrong country.
        assertNull(RegionCatalog.guess("sg1"))
        assertNull(RegionCatalog.guess("us-east-1"))
    }

    @Test
    fun `us inside russia does not match`() {
        assertEquals("RU", RegionCatalog.guess("russia")?.code)
    }

    @Test
    fun `a city alias resolves to its country`() {
        assertEquals("NL", RegionCatalog.guess("nl-amsterdam-01")?.code)
        assertEquals("JP", RegionCatalog.guess("tokyo fast")?.code)
        assertEquals("US", RegionCatalog.guess("node ashburn-3")?.code)
    }

    @Test
    fun `a long name wins over a short code in the same label`() {
        // "United States" and "US" both map to US; the interesting part is that the
        // matcher does not stop at the two-letter code and call it something else.
        assertEquals("US", RegionCatalog.guess("US East (United States)")?.code)
    }

    @Test
    fun `a full country name beats a code that appears earlier in the label`() {
        // "IN" is uppercase here, so code matching would say India; the country name
        // is checked first and says Germany. Names are more informative than codes.
        assertEquals("DE", RegionCatalog.guess("IN Germany")?.code)
    }

    @Test
    fun `null and blank input produce no region`() {
        assertNull(RegionCatalog.guess(null))
        assertNull(RegionCatalog.guess(""))
        assertNull(RegionCatalog.guess("   "))
    }

    @Test
    fun `a label with no country produces no region`() {
        assertNull(RegionCatalog.guess("my fast proxy"))
        assertNull(RegionCatalog.guess("203.0.113.9:1080"))
    }

    @Test
    fun `a code is turned into a display name`() {
        assertEquals("United States", RegionCatalog.displayName("US"))
        assertEquals("United States", RegionCatalog.displayName("us"))
        assertEquals("United Kingdom", RegionCatalog.displayName("GB"))
        assertNull(RegionCatalog.displayName(null))
        assertNull(RegionCatalog.displayName(""))
    }

    @Test
    fun `an unknown code is shown as itself rather than hidden`() {
        assertEquals("ZZ", RegionCatalog.displayName("ZZ"))
    }

    @Test
    fun `search matches names, codes and aliases`() {
        assertEquals(listOf("NL"), RegionCatalog.search("nether").map { it.code })
        assertEquals(listOf("NL"), RegionCatalog.search("NL").map { it.code })
        assertEquals(listOf("NL"), RegionCatalog.search("holland").map { it.code })
        assertTrue(RegionCatalog.search("").isEmpty())
        assertTrue(RegionCatalog.search("atlantis").isEmpty())
    }

    @Test
    fun `byCode is case insensitive and trims`() {
        assertEquals("FR", RegionCatalog.byCode(" fr ")?.code)
        assertNull(RegionCatalog.byCode("XX"))
        assertNull(RegionCatalog.byCode(null))
    }

    @Test
    fun `every catalogue entry is well formed and unique`() {
        val codes = RegionCatalog.all.map { it.code }
        assertEquals("codes must be unique", codes.size, codes.toSet().size)
        RegionCatalog.all.forEach { region ->
            assertEquals("${region.code} must be two uppercase letters", 2, region.code.length)
            assertEquals(region.code, region.code.uppercase())
            assertTrue("${region.code} needs a name", region.name.isNotBlank())
        }
    }

    @Test
    fun `no alias collides with another region`() {
        val seen = mutableMapOf<String, String>()
        RegionCatalog.all.forEach { region ->
            (listOf(region.name) + region.aliases).forEach { word ->
                val key = word.lowercase()
                val previous = seen.put(key, region.code)
                if (previous != null && previous != region.code) {
                    throw AssertionError("\"$word\" is claimed by both $previous and ${region.code}")
                }
            }
        }
    }
}
