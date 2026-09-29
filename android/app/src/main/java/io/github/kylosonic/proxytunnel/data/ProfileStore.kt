package io.github.kylosonic.proxytunnel.data

import android.content.Context
import io.github.kylosonic.proxytunnel.core.ProxyProfile
import io.github.kylosonic.proxytunnel.core.ProxyProtocol
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

/**
 * Persistence for proxy profiles.
 *
 * Same split as the iOS app: plain metadata in a JSON file, the password in the
 * platform's secure store ([SecretStore], backed by the Android Keystore). The
 * [ProxyProfile] type has no password field, so there is no way for a secret to
 * reach the JSON by accident.
 */
class ProfileStore(context: Context) {

    private val file = File(context.filesDir, "profiles.json")
    private val secrets = SecretStore(context)

    @Volatile
    private var document: JSONObject = JSONObject()

    init {
        load()
    }

    private fun load() {
        document = runCatching {
            if (file.exists()) JSONObject(file.readText()) else JSONObject()
        }.getOrElse { JSONObject() }
    }

    private fun persist() {
        runCatching { file.writeText(document.toString(2)) }
    }

    // MARK: reading

    fun all(): List<ProxyProfile> {
        val array = document.optJSONArray(KEY_PROFILES) ?: return emptyList()
        return (0 until array.length()).mapNotNull { index ->
            array.optJSONObject(index)?.let { decode(it) }
        }
    }

    fun find(id: String): ProxyProfile? = all().firstOrNull { it.id == id }

    val selectedProfileId: String?
        get() = document.optString(KEY_SELECTED, "").takeIf { it.isNotEmpty() }

    val selectedProfile: ProxyProfile?
        get() = selectedProfileId?.let { find(it) }

    fun password(profileId: String): String? = secrets.get(SecretStore.passwordKey(profileId))

    // MARK: writing

    fun add(
        name: String,
        host: String,
        port: Int,
        protocol: ProxyProtocol,
        username: String?,
        password: String?,
        regionCode: String? = null,
        notes: String? = null,
        id: String = UUID.randomUUID().toString()
    ): ProxyProfile {
        val profile = ProxyProfile(
            id = id,
            name = name,
            host = host,
            port = port,
            protocol = protocol,
            username = username,
            hasStoredPassword = !password.isNullOrEmpty(),
            regionCode = regionCode,
            notes = notes
        )
        if (!password.isNullOrEmpty()) secrets.put(SecretStore.passwordKey(id), password)

        val array = document.optJSONArray(KEY_PROFILES) ?: JSONArray()
        array.put(encode(profile))
        document.put(KEY_PROFILES, array)
        if (document.optString(KEY_SELECTED).isEmpty()) document.put(KEY_SELECTED, id)
        persist()
        return profile
    }

    /**
     * - Parameter password: `null` keeps whatever is stored; an empty string
     *   deletes it.
     */
    fun update(profile: ProxyProfile, password: String?) {
        val array = document.optJSONArray(KEY_PROFILES) ?: return
        var updated = profile

        when {
            password == null -> Unit
            password.isEmpty() -> {
                secrets.remove(SecretStore.passwordKey(profile.id))
                updated = profile.copy(hasStoredPassword = false)
            }
            else -> {
                secrets.put(SecretStore.passwordKey(profile.id), password)
                updated = profile.copy(hasStoredPassword = true)
            }
        }

        for (index in 0 until array.length()) {
            val item = array.optJSONObject(index) ?: continue
            if (item.optString("id") == profile.id) {
                array.put(index, encode(updated))
                break
            }
        }
        document.put(KEY_PROFILES, array)
        persist()
    }

    fun delete(id: String) {
        val array = document.optJSONArray(KEY_PROFILES) ?: return
        val kept = JSONArray()
        for (index in 0 until array.length()) {
            val item = array.optJSONObject(index) ?: continue
            if (item.optString("id") != id) kept.put(item)
        }
        document.put(KEY_PROFILES, kept)
        secrets.remove(SecretStore.passwordKey(id))
        if (selectedProfileId == id) {
            document.put(KEY_SELECTED, kept.optJSONObject(0)?.optString("id") ?: "")
        }
        persist()
    }

    fun select(id: String?) {
        document.put(KEY_SELECTED, id ?: "")
        persist()
    }

    /** True when the profile claims a password that is no longer in the Keystore. */
    fun isMissingPassword(profile: ProxyProfile): Boolean =
        profile.hasStoredPassword && secrets.get(SecretStore.passwordKey(profile.id)) == null

    // MARK: json

    private fun encode(profile: ProxyProfile): JSONObject = JSONObject().apply {
        put("id", profile.id)
        put("name", profile.name)
        put("host", profile.host)
        put("port", profile.port)
        put("protocol", profile.protocol.wireName)
        profile.username?.let { put("username", it) }
        put("hasStoredPassword", profile.hasStoredPassword)
        put("isEnabled", profile.isEnabled)
        profile.regionCode?.let { put("regionCode", it) }
        profile.notes?.let { put("notes", it) }
    }

    private fun decode(json: JSONObject): ProxyProfile = ProxyProfile(
        id = json.optString("id", UUID.randomUUID().toString()),
        name = json.optString("name", "Proxy"),
        host = json.optString("host"),
        port = json.optInt("port", 1080),
        protocol = ProxyProtocol.fromWireName(json.optString("protocol")) ?: ProxyProtocol.SOCKS5,
        username = json.optString("username").takeIf { it.isNotEmpty() },
        hasStoredPassword = json.optBoolean("hasStoredPassword", false),
        isEnabled = json.optBoolean("isEnabled", true),
        regionCode = json.optString("regionCode").takeIf { it.isNotEmpty() },
        notes = json.optString("notes").takeIf { it.isNotEmpty() }
    )

    private companion object {
        const val KEY_PROFILES = "profiles"
        const val KEY_SELECTED = "selectedProfileId"
    }
}
