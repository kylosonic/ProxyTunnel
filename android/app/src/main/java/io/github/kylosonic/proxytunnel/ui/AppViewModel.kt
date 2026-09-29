package io.github.kylosonic.proxytunnel.ui

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import io.github.kylosonic.proxytunnel.core.ImportEntry
import io.github.kylosonic.proxytunnel.core.LogRedactor
import io.github.kylosonic.proxytunnel.core.ProxyCredential
import io.github.kylosonic.proxytunnel.core.ProxyImportParser
import io.github.kylosonic.proxytunnel.core.ProxyProfile
import io.github.kylosonic.proxytunnel.core.ProxyProtocol
import io.github.kylosonic.proxytunnel.core.ProxyProbe
import io.github.kylosonic.proxytunnel.core.RegionCatalog
import io.github.kylosonic.proxytunnel.data.ProfileStore
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
        val locationFilter: String = ""
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
                Triple(profiles, store.selectedProfileId, missing)
            }
            _state.value = _state.value.copy(
                profiles = snapshot.first,
                selectedId = snapshot.second,
                missingPasswords = snapshot.third
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

    /** A one-line, credential-free description of the last failure, for the log. */
    fun describeFailure(): String? = _state.value.probe.report?.let { report ->
        report.failureMessage?.let { LogRedactor.redact(it) }
    }

    private companion object {
        val PLACEHOLDERS = setOf("-", "none", "null", "n/a", "na", "x", "***")

        fun plural(count: Int, one: String, many: String) = if (count == 1) one else many
    }
}
