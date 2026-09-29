package io.github.kylosonic.proxytunnel.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import io.github.kylosonic.proxytunnel.core.ImportEntry
import io.github.kylosonic.proxytunnel.core.LogRedactor
import io.github.kylosonic.proxytunnel.core.ProviderApi
import io.github.kylosonic.proxytunnel.core.ProxyCredential
import io.github.kylosonic.proxytunnel.core.ProxyImportParser
import io.github.kylosonic.proxytunnel.core.ProxyProfile
import io.github.kylosonic.proxytunnel.core.ProxyProtocol
import io.github.kylosonic.proxytunnel.core.ProxyProbe
import io.github.kylosonic.proxytunnel.core.RegionCatalog
import io.github.kylosonic.proxytunnel.data.ProfileStore
import io.github.kylosonic.proxytunnel.data.SecretStore
import io.github.kylosonic.proxytunnel.vpn.ProxyTunnelService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * All the state the screens render, in one place.
 *
 * The rule this class exists to enforce: the UI never holds a password. It hands
 * one to [save] or [importEntries], which push it straight into the Keystore, and
 * from then on the UI only ever sees [ProxyProfile.hasStoredPassword].
 */
class AppViewModel(application: Application) : AndroidViewModel(application) {

    private val store = ProfileStore(application)
    private val secrets = SecretStore(application)

    data class ProbeState(
        val runningProfileId: String? = null,
        val report: ProxyProbe.Report? = null,
        val forProfileId: String? = null
    )

    data class UiState(
        val profiles: List<ProxyProfile> = emptyList(),
        val selectedId: String? = null,
        val missingPasswords: Set<String> = emptySet(),
        val probe: ProbeState = ProbeState(),
        val message: String? = null,
        val locationFilter: String = "",
        /** Whether a provider API key is stored. The key itself never enters this state. */
        val providerHasKey: Boolean = false,
        val provider: ProviderUi = ProviderUi()
    ) {
        val selected: ProxyProfile? get() = profiles.firstOrNull { it.id == selectedId }

        /** Regions that at least one stored proxy claims, for the location picker. */
        val availableRegions: List<RegionCatalog.Region>
            get() = profiles.mapNotNull { RegionCatalog.byCode(it.regionCode) }.distinct()
                    .sortedBy { it.name }

        fun profilesMatching(query: String): List<ProxyProfile> {
            val needle = query.trim()
            if (needle.isEmpty()) return profiles
            return profiles.filter { profile ->
                profile.name.contains(needle, ignoreCase = true) ||
                    profile.host.contains(needle, ignoreCase = true) ||
                    profile.regionCode.equals(needle, ignoreCase = true) ||
                    (profile.regionName?.contains(needle, ignoreCase = true) ?: false) ||
                    RegionCatalog.search(needle).any { it.code == profile.regionCode }
            }
        }
    }

    /** The state of one provider lookup, kept separate so a failure cannot clear the list. */
    data class ProviderUi(
        val running: Boolean = false,
        val regionCode: String? = null,
        val result: ProviderApi.Result? = null,
        val addedNames: List<String> = emptyList()
    )

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state.asStateFlow()

    /** Live tunnel status, straight from the service. */
    val tunnelStatus: StateFlow<ProxyTunnelService.Status> = ProxyTunnelService.status

    init {
        refresh()
    }

    fun refresh() {
        viewModelScope.launch {
            val snapshot = withContext(Dispatchers.IO) {
                val profiles = store.all()
                val missing = profiles.filter { store.isMissingPassword(it) }.map { it.id }.toSet()
                val hasKey = runCatching {
                    !secrets.get(SecretStore.providerKey(ProviderApi.Provider.WEBSHARE.id)).isNullOrBlank()
                }.getOrDefault(false)
                Triple(profiles, store.selectedProfileId, missing) to hasKey
            }
            _state.value = _state.value.copy(
                profiles = snapshot.first.first,
                selectedId = snapshot.first.second,
                missingPasswords = snapshot.first.third,
                providerHasKey = snapshot.second
            )
        }
    }

    fun setLocationFilter(query: String) {
        _state.value = _state.value.copy(locationFilter = query)
    }

    fun dismissMessage() {
        _state.value = _state.value.copy(message = null)
    }

    fun select(profile: ProxyProfile) {
        store.select(profile.id)
        refresh()
    }

    fun delete(profile: ProxyProfile) {
        viewModelScope.launch {
            withContext(Dispatchers.IO) { store.delete(profile.id) }
            refresh()
        }
    }

    /**
     * Creates or updates a profile.
     *
     * @param password `null` keeps whatever is stored; an empty string clears it.
     */
    fun save(
        existing: ProxyProfile?,
        name: String,
        host: String,
        port: Int,
        protocol: ProxyProtocol,
        username: String?,
        password: String?,
        regionCode: String?,
        notes: String?
    ) {
        viewModelScope.launch {
            withContext(Dispatchers.IO) {
                if (existing == null) {
                    store.add(
                        name = name, host = host, port = port, protocol = protocol,
                        username = username, password = password,
                        regionCode = regionCode, notes = notes
                    )
                } else {
                    store.update(
                        existing.copy(
                            name = name, host = host, port = port, protocol = protocol,
                            username = username?.takeIf { it.isNotEmpty() },
                            regionCode = regionCode, notes = notes
                        ),
                        password
                    )
                }
            }
            refresh()
            _state.value = _state.value.copy(
                message = if (existing == null) "Saved “$name”." else "Updated “$name”."
            )
        }
    }

    // MARK: import

    data class ImportPreview(
        val entries: List<ImportEntry>,
        val excluded: Set<Int> = emptySet()
    ) {
        val ready: List<ImportEntry> get() = entries.filter { it.isReady && it.lineNumber !in excluded }
        val rejected: List<ImportEntry> get() = entries.filter { !it.isReady }
        val blank: Int get() = entries.size - ready.size - rejected.size
    }

    /**
     * Parses pasted text into a preview. Nothing is stored yet — the sheet shows
     * what was understood and the user confirms.
     */
    fun previewImport(text: String, defaultProtocol: ProxyProtocol?): ImportPreview =
        ImportPreview(ProxyImportParser.parse(text, defaultProtocol))

    /**
     * Commits a preview.
     *
     * @param skipExisting drops entries whose `host:port` is already stored.
     * @return a sentence describing what happened, safe to show in the UI.
     */
    fun importEntries(
        preview: ImportPreview,
        namePrefix: String,
        skipExisting: Boolean,
        onDone: (String) -> Unit
    ) {
        viewModelScope.launch {
            val outcome = withContext(Dispatchers.IO) {
                val existing = store.all().map { "${it.host}:${it.port}" to it }.toMap()
                var added = 0
                var skipped = 0
                var incomplete = 0
                val failures = mutableListOf<String>()

                for (entry in preview.ready) {
                    val host = entry.host ?: continue
                    val port = entry.port ?: continue
                    val key = "$host:$port"
                    if (skipExisting && existing.containsKey(key)) {
                        skipped++
                        continue
                    }
                    // A pasted password that is really a placeholder ("", "-", "none")
                    // would be worse than no password, so it is dropped.
                    val password = entry.password?.takeIf { it.isNotBlank() && it !in PLACEHOLDERS }
                    val label = listOfNotNull(
                        namePrefix.takeIf { it.isNotBlank() },
                        entry.name?.takeIf { it.isNotBlank() } ?: host
                    ).joinToString(" ").trim()

                    val region = RegionCatalog.guess(entry.name ?: entry.redactedSource)
                        ?: RegionCatalog.guess(label)

                    runCatching {
                        store.add(
                            name = label,
                            host = host,
                            port = port,
                            protocol = entry.protocol,
                            username = entry.username?.takeIf { it.isNotBlank() },
                            password = password,
                            regionCode = region?.code
                        )
                    }.onSuccess {
                        added++
                    }.onFailure { error ->
                        incomplete++
                        failures += "${entry.displayEndpoint}: ${error.message ?: error.javaClass.simpleName}"
                    }
                }
                ImportOutcome(added, skipped, incomplete, failures)
            }

            refresh()
            val summary = buildString {
                append("Added $outcome.added ${plural(outcome.added, "proxy", "proxies")}.")
                if (outcome.skipped > 0) append(" Skipped ${outcome.skipped} already stored.")
                if (outcome.incomplete > 0) append(" ${outcome.incomplete} could not be saved.")
            }
            _state.value = _state.value.copy(message = summary)
            onDone(summary)
        }
    }

    private data class ImportOutcome(
        val added: Int,
        val skipped: Int,
        val incomplete: Int,
        val failures: List<String>
    )

    // MARK: connectivity test

    fun probe(profile: ProxyProfile) {
        if (_state.value.probe.runningProfileId != null) return
        _state.value = _state.value.copy(probe = ProbeState(runningProfileId = profile.id))

        viewModelScope.launch {
            val report = withContext(Dispatchers.IO) {
                val password = store.password(profile.id)
                val credential = if (profile.usesAuthentication && password != null) {
                    ProxyCredential(profile.username ?: "", password)
                } else {
                    null
                }
                ProxyProbe.run(profile, credential)
            }
            _state.value = _state.value.copy(
                probe = ProbeState(runningProfileId = null, report = report, forProfileId = profile.id)
            )
        }
    }

    fun clearProbe() {
        _state.value = _state.value.copy(probe = ProbeState())
    }

    // MARK: provider lookup

    /**
     * Fetches the account's proxies from the provider, narrowed to [regionCode].
     *
     * Only ever called because the user asked: no polling, no background refresh. That
     * is deliberate — providers throttle or disapprove accounts that hammer their list
     * endpoint, and the app has no reason to.
     */
    fun lookup(provider: ProviderApi.Provider, regionCode: String?) {
        if (_state.value.provider.running) return
        _state.value = _state.value.copy(
            provider = ProviderUi(running = true, regionCode = regionCode)
        )

        viewModelScope.launch {
            val outcome = withContext(Dispatchers.IO) {
                val key = runCatching { secrets.get(SecretStore.providerKey(provider.id)) }.getOrNull()
                if (key.isNullOrBlank()) {
                    ProviderApi.Result.Failure(
                        ProviderApi.Result.Kind.NOT_CONFIGURED,
                        "No ${provider.displayName} API key is stored.",
                        "Paste one above. It is kept in the Android Keystore, like your proxy passwords."
                    )
                } else {
                    ProviderApi.fetch(provider, key, regionCode)
                }
            }
            _state.value = _state.value.copy(
                provider = ProviderUi(running = false, regionCode = regionCode, result = outcome)
            )
        }
    }

    fun saveProviderKey(provider: ProviderApi.Provider, key: String) {
        viewModelScope.launch {
            withContext(Dispatchers.IO) {
                runCatching {
                    if (key.isBlank()) {
                        secrets.remove(SecretStore.providerKey(provider.id))
                    } else {
                        secrets.put(SecretStore.providerKey(provider.id), key.trim())
                    }
                }
            }
            refresh()
            _state.value = _state.value.copy(
                message = if (key.isBlank()) {
                    "Removed the ${provider.displayName} API key."
                } else {
                    "Saved the ${provider.displayName} API key to the Keystore."
                }
            )
        }
    }

    fun clearProviderResult() {
        _state.value = _state.value.copy(provider = ProviderUi())
    }

    /**
     * Stores every fetched proxy, skipping any whose host and port are already saved,
     * and selects the first new one so Connect does the obvious thing.
     *
     * The passwords come from the provider's response and go straight into the
     * Keystore; they are never placed in UI state and never logged.
     */
    fun addFetched(proxies: List<ProviderApi.RemoteProxy>, onDone: (String) -> Unit) {
        viewModelScope.launch {
            val outcome = withContext(Dispatchers.IO) {
                val existing = store.all().map { "${it.host}:${it.port}" }.toSet()
                var added = 0
                var skipped = 0
                var failed = 0
                var firstId: String? = null

                for (proxy in proxies) {
                    if ("${proxy.host}:${proxy.port}" in existing) {
                        skipped++
                        continue
                    }
                    val provider = ProviderApi.Provider.fromId(proxy.providerId)
                    runCatching {
                        val profile = store.add(
                            name = proxy.suggestedName(),
                            host = proxy.host,
                            port = proxy.port,
                            protocol = provider?.protocol ?: ProxyProtocol.HTTP_CONNECT,
                            username = proxy.username,
                            password = proxy.password,
                            regionCode = proxy.regionCode
                        )
                        if (firstId == null) firstId = profile.id
                        added++
                    }.onFailure { failed++ }
                }

                if (firstId != null) store.select(firstId)
                Triple(added, skipped, failed)
            }

            refresh()
            val summary = buildString {
                append("Added ${outcome.first} ${if (outcome.first == 1) "proxy" else "proxies"}.")
                if (outcome.second > 0) append(" Skipped ${outcome.second} already stored.")
                if (outcome.third > 0) append(" ${outcome.third} could not be saved.")
            }
            _state.value = _state.value.copy(message = summary)
            onDone(summary)
        }
    }

    /** A one-line, credential-free description of the last failure, for the log. */
    fun describeFailure(): String? = _state.value.probe.report?.let { report ->
        report.failureMessage?.let { LogRedactor.redact(it) }
    }

    private companion object {
        val PLACEHOLDERS = setOf("-", "none", "null", "n/a", "na", "x", "***")

        fun plural(count: Int, one: String, many: String) = if (count == 1) one else many
    }
}
