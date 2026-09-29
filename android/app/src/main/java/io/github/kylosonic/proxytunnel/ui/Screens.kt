package io.github.kylosonic.proxytunnel.ui

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.filled.PowerSettingsNew
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import io.github.kylosonic.proxytunnel.core.ProxyProfile
import io.github.kylosonic.proxytunnel.vpn.ProxyTunnelService
import kotlinx.coroutines.launch
import java.util.Locale

// ---------------------------------------------------------------------------
//  Root
// ---------------------------------------------------------------------------

private enum class Tab { CONNECT, PROXIES, SETTINGS }

@Composable
fun AppRoot(shareIntent: Intent? = null) {
    val context = LocalContext.current
    val viewModel: AppViewModel = viewModel()
    val state by viewModel.state.collectAsStateWithLifecycle()
    val tunnel by viewModel.tunnelStatus.collectAsStateWithLifecycle()

    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()

    var tab by remember { mutableStateOf(Tab.CONNECT) }
    var editing by remember { mutableStateOf<ProxyProfile?>(null) }
    var creating by remember { mutableStateOf(false) }
    var pasting by remember { mutableStateOf(false) }
    var exporting by remember { mutableStateOf<ProxyProfile?>(null) }
    var pickingLocation by remember { mutableStateOf(false) }
    var pendingShareText by remember { mutableStateOf<String?>(null) }

    // A socks5:// link handed over by another app opens the paste sheet with it
    // already filled in. Only the first delivery is consumed.
    LaunchedEffect(shareIntent) {
        shareIntent?.dataString?.takeIf { it.isNotBlank() }?.let {
            pendingShareText = it
            pasting = true
        }
    }

    state.message?.let { message ->
        LaunchedEffect(message) {
            snackbar.showSnackbar(message)
            viewModel.dismissMessage()
        }
    }

    Scaffold(
        snackbarHost = { SnackbarHost(snackbar) },
        bottomBar = {
            NavigationBar {
                NavigationBarItem(
                    selected = tab == Tab.CONNECT,
                    onClick = { tab = Tab.CONNECT },
                    icon = { Icon(Icons.Default.PowerSettingsNew, contentDescription = null) },
                    label = { Text("Connect") }
                )
                NavigationBarItem(
                    selected = tab == Tab.PROXIES,
                    onClick = { tab = Tab.PROXIES },
                    icon = { Icon(Icons.Default.Shield, contentDescription = null) },
                    label = { Text("Proxies") }
                )
                NavigationBarItem(
                    selected = tab == Tab.SETTINGS,
                    onClick = { tab = Tab.SETTINGS },
                    icon = { Icon(Icons.Default.Settings, contentDescription = null) },
                    label = { Text("About") }
                )
            }
        }
    ) { padding ->
        Box(Modifier.padding(padding).fillMaxSize()) {
            when (tab) {
                Tab.CONNECT -> ConnectScreen(
                    state = state,
                    tunnel = tunnel,
                    onDisconnect = { ProxyTunnelService.stop(context) },
                    onProbe = viewModel::probe,
                    onClearProbe = viewModel::clearProbe,
                    onPickLocation = { pickingLocation = true },
                    onManageProxies = { tab = Tab.PROXIES }
                )

                Tab.PROXIES -> ProxyListScreen(
                    state = state,
                    onFilter = viewModel::setLocationFilter,
                    onAdd = { creating = true },
                    onPaste = { pasting = true },
                    onEdit = { editing = it },
                    onDelete = viewModel::delete,
                    onSelect = viewModel::select,
                    onExport = { exporting = it },
                    onProbe = viewModel::probe
                )

                Tab.SETTINGS -> AboutScreen(onOpenProxies = { tab = Tab.PROXIES })
            }
        }
    }

    if (creating) {
        EditProxySheet(
            existing = null,
            onDismiss = { creating = false },
            onSave = { name, host, port, protocol, username, password, region, notes ->
                viewModel.save(null, name, host, port, protocol, username, password, region, notes)
                creating = false
            }
        )
    }

    editing?.let { profile ->
        EditProxySheet(
            existing = profile,
            onDismiss = { editing = null },
            onSave = { name, host, port, protocol, username, password, region, notes ->
                viewModel.save(profile, name, host, port, protocol, username, password, region, notes)
                editing = null
            }
        )
    }

    if (pasting) {
        PasteSheet(
            initialState = pendingShareText,
            viewModel = viewModel,
            onDismiss = {
                pasting = false
                pendingShareText = null
            }
        )
    }

    exporting?.let { profile ->
        ExportSheet(profile = profile, onDismiss = { exporting = null })
    }

    if (pickingLocation) {
        LocationPickerSheet(
            state = state,
            onDismiss = { pickingLocation = false },
            onChoose = { region ->
                // `null` is the explicit "any location" choice: clear the filter and
                // keep whatever proxy is already selected.
                if (region == null) {
                    viewModel.setLocationFilter("")
                } else {
                    val match = state.profiles.firstOrNull { it.regionCode == region.code }
                    if (match != null) {
                        viewModel.select(match)
                        viewModel.setLocationFilter(region.name)
                        scope.launch {
                            snackbar.showSnackbar("Selected “${match.name}” in ${region.name}.")
                        }
                    } else {
                        scope.launch {
                            snackbar.showSnackbar(
                                "No proxy is stored for ${region.name}. Add one you own, then pick it here."
                            )
                        }
                    }
                }
                pickingLocation = false
            }
        )
    }
}

/**
 * `VpnService.prepare()` is the only consent Android requires.
 *
 * Nothing is ever started behind the user's back: [ConnectScreen] shows the system
 * dialog, waits for `RESULT_OK`, and only then asks the service to start. Declining
 * leaves the tunnel off entirely.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ConnectScreen(
    state: AppViewModel.UiState,
    tunnel: ProxyTunnelService.Status,
    onDisconnect: () -> Unit,
    onProbe: (ProxyProfile) -> Unit,
    onClearProbe: () -> Unit,
    onPickLocation: () -> Unit,
    onManageProxies: () -> Unit
) {
    val context = LocalContext.current
    var deniedNotice by remember { mutableStateOf(false) }
    val consentLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        val profile = state.selected
        if (result.resultCode == Activity.RESULT_OK && profile != null) {
            ProxyTunnelService.start(context, profile.id)
        } else {
            deniedNotice = true
        }
    }
    val notificationLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { /* The tunnel works either way; the notification is just less visible. */ }

    val selected = state.selected
    val running = tunnel.state == ProxyTunnelService.State.RUNNING ||
        tunnel.state == ProxyTunnelService.State.STARTING
    val blockedReason = when {
        selected == null -> "No proxy is selected. Add one on the Proxies tab."
        !selected.protocol.supportsTunnelUpstream ->
            "${selected.protocol.displayName} cannot be the tunnel upstream — the engine speaks SOCKS5. " +
                "Use it for the connection test or export instead."
        selected.id in state.missingPasswords ->
            "The stored password for this proxy is gone (it is dropped if you reinstall or clear app data). " +
                "Open the proxy and type it again."
        else -> null
    }

    Column(Modifier.fillMaxSize()) {
        TopAppBar(title = { Text("ProxyTunnel") })

        Column(
            Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            StatusCard(tunnel = tunnel, selected = selected, blockedReason = blockedReason)

            if (deniedNotice) {
                NoticeCard(
                    tone = StatusColors.bad,
                    title = "VPN permission was declined",
                    body = "Android needs your approval once before any app can create a VPN interface. " +
                        "Tap Connect again and choose OK. Nothing is tunnelled until you do."
                )
            }

            LocationRow(
                state = state,
                onPickLocation = onPickLocation,
                onManageProxies = onManageProxies
            )

            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                if (running) {
                    Button(
                        onClick = onDisconnect,
                        modifier = Modifier.weight(1f),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = MaterialTheme.colorScheme.error,
                            contentColor = MaterialTheme.colorScheme.onError
                        )
                    ) {
                        Icon(Icons.Default.PowerSettingsNew, contentDescription = null)
                        Spacer(Modifier.width(8.dp))
                        Text("Disconnect")
                    }
                } else {
                    Button(
                        onClick = {
                            val profile = selected ?: return@Button
                            if (profile.id in state.missingPasswords) return@Button
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                notificationLauncher.launch(android.Manifest.permission.POST_NOTIFICATIONS)
                            }
                            val consent = VpnService.prepare(context)
                            if (consent == null) {
                                ProxyTunnelService.start(context, profile.id)
                            } else {
                                consentLauncher.launch(consent)
                            }
                        },
                        enabled = blockedReason == null,
                        modifier = Modifier.weight(1f)
                    ) {
                        Icon(Icons.Default.PowerSettingsNew, contentDescription = null)
                        Spacer(Modifier.width(8.dp))
                        Text("Connect")
                    }
                }
                OutlinedButton(
                    onClick = { selected?.let(onProbe) },
                    enabled = selected != null && state.probe.runningProfileId == null,
                    modifier = Modifier.weight(1f)
                ) {
                    Icon(Icons.Default.Speed, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text("Test proxy")
                }
            }

            ProbeCard(state = state, onClear = onClearProbe)

            if (running) {
                Text(
                    "Traffic counters come from the engine itself, so a number above zero means " +
                        "packets really did traverse the tunnel.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Spacer(Modifier.height(16.dp))
        }
    }
}

@Composable
private fun StatusCard(
    tunnel: ProxyTunnelService.Status,
    selected: ProxyProfile?,
    blockedReason: String?
) {
    val (label, color) = when (tunnel.state) {
        ProxyTunnelService.State.RUNNING -> "Connected" to StatusColors.good
        ProxyTunnelService.State.STARTING -> "Connecting…" to StatusColors.warn
        ProxyTunnelService.State.STOPPING -> "Disconnecting…" to StatusColors.warn
        ProxyTunnelService.State.FAILED -> "Failed" to StatusColors.bad
        ProxyTunnelService.State.STOPPED -> "Not connected" to StatusColors.neutral
    }

    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier
                        .size(10.dp)
                        .background(color, RoundedCornerShape(5.dp))
                )
                Spacer(Modifier.width(8.dp))
                Text(label, style = MaterialTheme.typography.titleMedium, color = color)
            }

            val name = tunnel.profileName ?: selected?.name
            val endpoint = tunnel.upstream ?: selected?.displayEndpoint
            if (name != null) {
                Text(name, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            }
            if (endpoint != null) {
                Text(
                    endpoint,
                    style = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            selected?.regionName?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }

            tunnel.failure?.let {
                Text(it, style = MaterialTheme.typography.bodyMedium, color = StatusColors.bad)
            }
            blockedReason?.let {
                Text(it, style = MaterialTheme.typography.bodyMedium, color = StatusColors.warn)
            }

            if (tunnel.bytesIn > 0 || tunnel.bytesOut > 0 || tunnel.packetsIn > 0) {
                HorizontalDivider(Modifier.padding(vertical = 4.dp))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Counter("Down", formatBytes(tunnel.bytesIn), "${tunnel.packetsIn} pkt")
                    Counter("Up", formatBytes(tunnel.bytesOut), "${tunnel.packetsOut} pkt")
                }
            }
        }
    }
}

@Composable
private fun Counter(label: String, value: String, detail: String) {
    Column {
        Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, style = MaterialTheme.typography.titleMedium)
        Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun NoticeCard(tone: Color, title: String, body: String) {
    Card(colors = CardDefaults.cardColors(containerColor = tone.copy(alpha = 0.14f))) {
        Row(Modifier.padding(12.dp)) {
            Icon(Icons.Default.Warning, contentDescription = null, tint = tone)
            Spacer(Modifier.width(10.dp))
            Column {
                Text(title, style = MaterialTheme.typography.titleSmall, color = tone)
                Text(body, style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

@Composable
private fun LocationRow(
    state: AppViewModel.UiState,
    onPickLocation: () -> Unit,
    onManageProxies: () -> Unit
) {
    val filter = state.locationFilter
    val matches = state.profilesMatching(filter)
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.Place, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Column(Modifier.weight(1f)) {
                    Text("Location", style = MaterialTheme.typography.labelLarge)
                    Text(
                        if (filter.isBlank()) "Any — using the selected proxy"
                        else "$filter · ${matches.size} matching ${if (matches.size == 1) "proxy" else "proxies"}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                TextButton(onClick = onPickLocation) { Text("Choose") }
            }
            Text(
                "This filters the proxies you have stored by the country you labelled them with. " +
                    "It does not look anything up online.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            if (matches.isEmpty() && filter.isNotBlank()) {
                TextButton(onClick = onManageProxies) { Text("Add a proxy for this location") }
            }
        }
    }
}

@Composable
private fun ProbeCard(state: AppViewModel.UiState, onClear: () -> Unit) {
    val probe = state.probe
    probe.runningProfileId?.let {
        Card {
            Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                Spacer(Modifier.width(12.dp))
                Text("Testing the proxy end to end…")
            }
        }
        return
    }

    val report = probe.report ?: return
    val tone = if (report.isSuccess) StatusColors.good else StatusColors.bad
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    if (report.isSuccess) Icons.Default.CheckCircle else Icons.Default.Error,
                    contentDescription = null, tint = tone
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    if (report.isSuccess) "Proxy works" else "Proxy test failed",
                    style = MaterialTheme.typography.titleSmall, color = tone
                )
                Spacer(Modifier.weight(1f))
                TextButton(onClick = onClear) { Text("Hide") }
            }
            report.summaryLines.forEach {
                Text(
                    "• $it",
                    style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace)
                )
            }
            report.failureSuggestion?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Text(
                "Took ${report.totalMillis} ms",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

// ---------------------------------------------------------------------------
//  Proxy list
// ---------------------------------------------------------------------------

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ProxyListScreen(
    state: AppViewModel.UiState,
    onFilter: (String) -> Unit,
    onAdd: () -> Unit,
    onPaste: () -> Unit,
    onEdit: (ProxyProfile) -> Unit,
    onDelete: (ProxyProfile) -> Unit,
    onSelect: (ProxyProfile) -> Unit,
    onExport: (ProxyProfile) -> Unit,
    onProbe: (ProxyProfile) -> Unit
) {
    var pendingDelete by remember { mutableStateOf<ProxyProfile?>(null) }
    val visible = state.profilesMatching(state.locationFilter)

    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text("Proxies") },
            actions = {
                IconButton(onClick = onPaste) {
                    Icon(Icons.Default.ContentPaste, contentDescription = "Paste proxies")
                }
                IconButton(onClick = onAdd) {
                    Icon(Icons.Default.Add, contentDescription = "Add a proxy")
                }
            }
        )

        OutlinedTextField(
            value = state.locationFilter,
            onValueChange = onFilter,
            label = { Text("Filter by location, name or host") },
            singleLine = true,
            trailingIcon = {
                if (state.locationFilter.isNotEmpty()) {
                    TextButton(onClick = { onFilter("") }) { Text("Clear") }
                }
            },
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
        )

        if (state.profiles.isEmpty()) {
            EmptyProxies(onAdd = onAdd, onPaste = onPaste)
            return@Column
        }

        if (visible.isEmpty()) {
            Text(
                "Nothing matches “${state.locationFilter}”. Nothing was looked up online — this only " +
                    "searches the proxies you have stored.",
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(16.dp)
            )
            return@Column
        }

        LazyColumn(contentPadding = PaddingValues(vertical = 8.dp)) {
            items(visible, key = { it.id }) { profile ->
                ProxyRow(
                    profile = profile,
                    isSelected = profile.id == state.selectedId,
                    isMissingPassword = profile.id in state.missingPasswords,
                    isTesting = state.probe.runningProfileId == profile.id,
                    onSelect = { onSelect(profile) },
                    onEdit = { onEdit(profile) },
                    onDelete = { pendingDelete = profile },
                    onExport = { onExport(profile) },
                    onProbe = { onProbe(profile) }
                )
            }
        }
    }

    pendingDelete?.let { profile ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Delete “${profile.name}”?") },
            text = { Text("The stored password is deleted with it. This cannot be undone.") },
            confirmButton = {
                TextButton(onClick = {
                    onDelete(profile)
                    pendingDelete = null
                }) { Text("Delete") }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) { Text("Cancel") }
            }
        )
    }
}

@Composable
private fun ProxyRow(
    profile: ProxyProfile,
    isSelected: Boolean,
    isMissingPassword: Boolean,
    isTesting: Boolean,
    onSelect: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
    onExport: () -> Unit,
    onProbe: () -> Unit
) {
    var menu by remember { mutableStateOf(false) }

    ListItem(
        headlineContent = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (isSelected) {
                    Icon(
                        Icons.Default.CheckCircle,
                        contentDescription = "Selected",
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(16.dp)
                    )
                    Spacer(Modifier.width(6.dp))
                }
                Text(profile.name, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        },
        supportingContent = {
            Column {
                Text(
                    profile.displayEndpoint,
                    style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace)
                )
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(profile.protocol.displayName, style = MaterialTheme.typography.labelSmall)
                    profile.regionName?.let {
                        Text("· $it", style = MaterialTheme.typography.labelSmall)
                    }
                    if (profile.usesAuthentication) {
                        Text("· auth", style = MaterialTheme.typography.labelSmall)
                    }
                    if (isMissingPassword) {
                        Text(
                            "· password missing",
                            style = MaterialTheme.typography.labelSmall,
                            color = StatusColors.bad
                        )
                    }
                }
            }
        },
        trailingContent = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (isTesting) {
                    CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(8.dp))
                }
                IconButton(onClick = onSelect) {
                    Icon(
                        Icons.Default.CheckCircle,
                        contentDescription = "Use this proxy",
                        tint = if (isSelected) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                Box {
                    IconButton(onClick = { menu = true }) {
                        Icon(Icons.Default.MoreVert, contentDescription = "More actions")
                    }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        DropdownMenuItem(
                            text = { Text("Edit") },
                            leadingIcon = { Icon(Icons.Default.Edit, contentDescription = null) },
                            onClick = { menu = false; onEdit() }
                        )
                        DropdownMenuItem(
                            text = { Text("Test connection") },
                            leadingIcon = { Icon(Icons.Default.Speed, contentDescription = null) },
                            onClick = { menu = false; onProbe() }
                        )
                        DropdownMenuItem(
                            text = { Text("Export / share") },
                            leadingIcon = { Icon(Icons.Default.IosShare, contentDescription = null) },
                            onClick = { menu = false; onExport() }
                        )
                        DropdownMenuItem(
                            text = { Text("Delete") },
                            leadingIcon = { Icon(Icons.Default.Delete, contentDescription = null) },
                            onClick = { menu = false; onDelete() }
                        )
                    }
                }
            }
        },
        colors = ListItemDefaults.colors(
            containerColor = if (isSelected) MaterialTheme.colorScheme.surfaceVariant
            else Color.Transparent
        )
    )
    HorizontalDivider()
}

@Composable
private fun EmptyProxies(onAdd: () -> Unit, onPaste: () -> Unit) {
    Column(
        Modifier
            .fillMaxSize()
            .padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Icon(
            Icons.Default.Shield,
            contentDescription = null,
            modifier = Modifier.size(48.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(Modifier.height(12.dp))
        Text("No proxies yet", style = MaterialTheme.typography.titleMedium)
        Spacer(Modifier.height(6.dp))
        Text(
            "Add one you own — from a provider you pay for, from a trial, or a SOCKS5 endpoint running " +
                "on your own machine or server.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(Modifier.height(16.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(onClick = onAdd) {
                Icon(Icons.Default.Add, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("Add")
            }
            OutlinedButton(onClick = onPaste) {
                Icon(Icons.Default.ContentPaste, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("Paste")
            }
        }
    }
}

// ---------------------------------------------------------------------------
//  About
// ---------------------------------------------------------------------------

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AboutScreen(onOpenProxies: () -> Unit) {
    Column(Modifier.fillMaxSize()) {
        TopAppBar(title = { Text("About") })
        Column(
            Modifier
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Card {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Why this runs on Android", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "Android's VpnService needs the user's consent and nothing else: no developer " +
                            "account, no provisioning profile, no seven-day expiry. That is why the same " +
                            "idea that is blocked on iOS by Apple's Network Extension entitlement works " +
                            "here with a plain debug-signed APK.",
                        style = MaterialTheme.typography.bodyMedium
                    )
                }
            }

            Card {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("What the tunnel does", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "hev-socks5-tunnel reads IP packets from the tun interface Android hands over " +
                            "and forwards them through your SOCKS5 proxy, with UDP and DNS relayed over " +
                            "the same SOCKS5 association. TCP and UDP both leave via the proxy's egress " +
                            "rather than your carrier's resolver.",
                        style = MaterialTheme.typography.bodyMedium
                    )
                    Text(
                        "This app's own traffic is excluded from the tunnel with " +
                            "addDisallowedApplication, so the connection to the proxy cannot loop back " +
                            "into the tunnel.",
                        style = MaterialTheme.typography.bodyMedium
                    )
                }
            }

            Card {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Get a kill switch", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "Android's own settings do this better than an app can: Settings → Network & " +
                            "internet → VPN → ProxyTunnel → Always-on VPN, and enable “Block connections " +
                            "without VPN”. With both on, no traffic leaves the device when the tunnel is " +
                            "down.",
                        style = MaterialTheme.typography.bodyMedium
                    )
                }
            }

            Card {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Where to get a proxy", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "This app never fetches a proxy list, and it will not search for “free residential " +
                            "proxies”. Those lists are made of open proxies on strangers' machines, " +
                            "honeypots that read and rewrite what you send, or SDKs that resell other " +
                            "people's bandwidth — none of which is safe to put credentials through.",
                        style = MaterialTheme.typography.bodyMedium
                    )
                    Text(
                        "Legitimate options: the provider you already pay for, a paid or trial plan from " +
                            "a residential-proxy vendor, a free tier from a datacentre-proxy vendor, or a " +
                            "SOCKS5 endpoint you run yourself (Tor's SOCKS port, an SSH -D tunnel, a small " +
                            "VPS). Any of those can be pasted in and labelled with its country.",
                        style = MaterialTheme.typography.bodyMedium
                    )
                    AssistChip(onClick = onOpenProxies, label = { Text("Open my proxies") })
                }
            }

            Card {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Honest limits", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "• The tunnel upstream must be SOCKS5. HTTP CONNECT and HTTPS CONNECT work for " +
                            "the connection test and for export, but the engine cannot use them.\n" +
                            "• The generated engine config is the one place the password touches disk. It " +
                            "lives in app-private storage, owner-only, and is deleted when the tunnel stops.\n" +
                            "• Proxies are only ever labelled by country because you labelled them. The app " +
                            "does not verify where a proxy actually exits.",
                        style = MaterialTheme.typography.bodyMedium
                    )
                }
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}

// ---------------------------------------------------------------------------
//  Small helpers
// ---------------------------------------------------------------------------

internal fun formatBytes(bytes: Long): String {
    if (bytes < 1024) return "$bytes B"
    val units = listOf("KiB", "MiB", "GiB", "TiB")
    var value = bytes.toDouble() / 1024
    var index = 0
    while (value >= 1024 && index < units.lastIndex) {
        value /= 1024
        index++
    }
    return String.format(Locale.US, "%.1f %s", value, units[index])
}
