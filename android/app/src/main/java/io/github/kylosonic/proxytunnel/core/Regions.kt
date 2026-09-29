package io.github.kylosonic.proxytunnel.core

/**
 * Country/region tagging for proxies you already own.
 *
 * ## What this is, and what it deliberately is not
 *
 * This is *not* a directory of free proxies and it does not discover or connect to
 * anything on its own. It does one narrow thing: it lets you label a proxy you
 * obtained yourself with the country its exit node is in, then pick a proxy by
 * typing a location instead of scrolling a list.
 *
 * That distinction matters. There is no such thing as a free residential proxy
 * pool that is legitimate to use: "free residential proxy lists" are, in practice,
 * open proxies on misconfigured machines, honeypots that log and rewrite traffic,
 * or botnet-adjacent SDKs that resell other people's bandwidth. Routing your
 * credentials through one is how accounts get stolen. So the app never fetches a
 * list. You supply the proxy; the app remembers where it is.
 *
 * The catalogue below exists only to recognise a place name in a label you pasted,
 * for example `ProxyCheap | US | New York`. It carries no endpoints.
 */
object RegionCatalog {

    data class Region(
        val code: String,
        val name: String,
        val aliases: List<String> = emptyList()
    ) {
        /** True when [query] names this region (code or name or alias, case-insensitive). */
        fun matches(query: String): Boolean {
            val needle = query.trim().lowercase()
            if (needle.isEmpty()) return false
            if (code.lowercase() == needle) return true
            if (name.lowercase() == needle) return true
            if (name.lowercase().startsWith(needle)) return true
            return aliases.any { it.lowercase() == needle }
        }
    }

    /**
     * A deliberately short list. It covers the countries that actually appear in
     * commercial proxy catalogues often enough to be worth recognising; anything
     * else can be typed by hand and is stored verbatim.
     */
    val all: List<Region> = listOf(
        Region("AR", "Argentina"),
        Region("AU", "Australia", listOf("sydney", "melbourne")),
        Region("AT", "Austria", listOf("vienna")),
        Region("BE", "Belgium", listOf("brussels")),
        Region("BR", "Brazil", listOf("sao paulo", "são paulo", "rio")),
        Region("BG", "Bulgaria", listOf("sofia")),
        Region("CA", "Canada", listOf("toronto", "montreal", "vancouver")),
        Region("CL", "Chile", listOf("santiago")),
        Region("CN", "China", listOf("beijing", "shanghai")),
        Region("CO", "Colombia", listOf("bogota", "bogotá")),
        Region("HR", "Croatia", listOf("zagreb")),
        Region("CZ", "Czechia", listOf("czech republic", "prague")),
        Region("DK", "Denmark", listOf("copenhagen")),
        Region("EG", "Egypt", listOf("cairo")),
        Region("EE", "Estonia", listOf("tallinn")),
        Region("FI", "Finland", listOf("helsinki")),
        Region("FR", "France", listOf("paris", "marseille")),
        Region("DE", "Germany", listOf("frankfurt", "berlin", "munich")),
        Region("GR", "Greece", listOf("athens")),
        Region("HK", "Hong Kong", listOf("hongkong", "hk")),
        Region("HU", "Hungary", listOf("budapest")),
        Region("IN", "India", listOf("mumbai", "bangalore", "bengaluru", "delhi")),
        Region("ID", "Indonesia", listOf("jakarta")),
        Region("IE", "Ireland", listOf("dublin")),
        Region("IL", "Israel", listOf("tel aviv")),
        Region("IT", "Italy", listOf("milan", "rome", "roma")),
        Region("JP", "Japan", listOf("tokyo", "osaka")),
        Region("KZ", "Kazakhstan", listOf("almaty")),
        Region("KE", "Kenya", listOf("nairobi")),
        Region("KR", "South Korea", listOf("korea", "seoul")),
        Region("LV", "Latvia", listOf("riga")),
        Region("LT", "Lithuania", listOf("vilnius")),
        Region("MY", "Malaysia", listOf("kuala lumpur")),
        Region("MX", "Mexico", listOf("mexico city")),
        Region("MD", "Moldova", listOf("chisinau", "chișinău")),
        Region("NL", "Netherlands", listOf("amsterdam", "holland")),
        Region("NZ", "New Zealand", listOf("auckland")),
        Region("NG", "Nigeria", listOf("lagos")),
        Region("NO", "Norway", listOf("oslo")),
        Region("PK", "Pakistan", listOf("karachi")),
        Region("PE", "Peru", listOf("lima")),
        Region("PH", "Philippines", listOf("manila")),
        Region("PL", "Poland", listOf("warsaw")),
        Region("PT", "Portugal", listOf("lisbon")),
        Region("RO", "Romania", listOf("bucharest")),
        Region("RU", "Russia", listOf("moscow", "st petersburg")),
        Region("SA", "Saudi Arabia", listOf("riyadh")),
        Region("RS", "Serbia", listOf("belgrade")),
        Region("SG", "Singapore"),
        Region("SK", "Slovakia", listOf("bratislava")),
        Region("ZA", "South Africa", listOf("johannesburg", "cape town")),
        Region("ES", "Spain", listOf("madrid", "barcelona")),
        Region("SE", "Sweden", listOf("stockholm")),
        Region("CH", "Switzerland", listOf("zurich", "zürich", "geneva")),
        Region("TW", "Taiwan", listOf("taipei")),
        Region("TH", "Thailand", listOf("bangkok")),
        Region("TR", "Turkey", listOf("türkiye", "istanbul")),
        Region("UA", "Ukraine", listOf("kyiv", "kiev")),
        Region("AE", "United Arab Emirates", listOf("uae", "dubai")),
        Region("GB", "United Kingdom", listOf("uk", "england", "london", "manchester")),
        Region("US", "United States", listOf("usa", "america", "new york", "los angeles", "chicago", "dallas", "seattle", "miami", "ashburn")),
        Region("VN", "Vietnam", listOf("hanoi"))
    )

    private val byCode: Map<String, Region> = all.associateBy { it.code }

    fun byCode(code: String?): Region? = code?.let { byCode[it.trim().uppercase()] }

    /** `US` -> `United States`, an unknown code -> the code itself. */
    fun displayName(code: String?): String? {
        if (code.isNullOrBlank()) return null
        return byCode(code)?.name ?: code
    }

    /** Matches a whole word, so `us` never matches inside `russia` or a base64 blob. */
    private fun wordPattern(needle: String, ignoreCase: Boolean): Regex = Regex(
        "(?<![A-Za-z0-9])" + Regex.escape(needle) + "(?![A-Za-z0-9])",
        if (ignoreCase) setOf(RegexOption.IGNORE_CASE) else emptySet()
    )

    /**
     * Finds a region named in free text, or null.
     *
     * Two passes, because the two kinds of name have opposite failure modes:
     *
     * 1. Long names and city aliases are matched case-insensitively, longest first,
     *    so `United States` beats `US` and `Netherlands` beats `NL`.
     * 2. Two-letter codes are matched **case-sensitively against capitals**, as a
     *    whole word. Proxy labels write them as `US`, `SG`, `NL`; matching them
     *    case-insensitively would make the English word "in" resolve to India and
     *    turn `Proxy in Germany` into a lie about where it exits.
     */
    fun guess(text: String?): Region? {
        if (text.isNullOrBlank()) return null

        val words = all.flatMap { region ->
            buildList {
                add(region.name)
                addAll(region.aliases)
            }.map { region to it }
        }.sortedByDescending { (_, needle) -> needle.length }

        for ((region, needle) in words) {
            if (wordPattern(needle, ignoreCase = true).containsMatchIn(text)) return region
        }

        for (region in all) {
            if (wordPattern(region.code, ignoreCase = false).containsMatchIn(text)) return region
        }
        return null
    }

    /** Regions matching a search box query, for the picker. Unknown text returns empty. */
    fun search(query: String): List<Region> {
        val needle = query.trim()
        if (needle.isEmpty()) return emptyList()
        return all.filter { it.matches(needle) }
    }
}
