package io.github.kylosonic.proxytunnel.ui

import android.content.Intent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CloudDownload
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.kylosonic.proxytunnel.core.HostValidator
import io.github.kylosonic.proxytunnel.core.PortValidator
import io.github.kylosonic.proxytunnel.core.ProxyCredential
import io.github.kylosonic.proxytunnel.core.ProxyProfile
import io.github.kylosonic.proxytunnel.core.ProxyProtocol
import io.github.kylosonic.proxytunnel.core.RegionCatalog
import io.github.kylosonic.proxytunnel.core.Severity
import io.github.kylosonic.proxytunnel.core.ShareLink
import io.github.kylosonic.proxytunnel.data.ProfileStore
import org.json.JSONObject

/** Replaces the password with a mask, and does nothing at all when there is none. */
private fun mask(text: String, password: String?): String =
    if (password.isNullOrEmpty()) text else text.replace(password, "••••••")

// ---------------------------------------------------------------------------
//  Add / edit
// ---------------------------------------------------------------------------

/**
 * The add/edit form.
 *
 * Two deliberate behaviours worth knowing about:
 *
 * * The password field starts empty on an existing profile and there is no way to
 *   read the stored one back out. Leaving it empty keeps what is stored; typing
 *   something replaces it; the explicit switch clears it. The UI never holds a
 *   secret it did not just receive.
 * * Validation runs on the same [HostValidator] and [PortValidator] the tunnel and
 *   the importer use, so the form cannot accept something the engine would reject.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EditProxySheet(
    existing: ProxyProfile?,
    onDismiss: () -> Unit,
    onSave: (
        name: String,
        host: String,
        port: Int,
        protocol: ProxyProtocol,
        username: String?,
        password: String?,
        regionCode: String?,
        notes: String?
    ) -> Unit
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    var name by remember { mutableStateOf(existing?.name ?: "") }
    var host by remember { mutableStateOf(existing?.host ?: "") }
    var port by remember {
        mutableStateOf((existing?.port ?: ProxyProtocol.SOCKS5.defaultPort).toString())
    }
    var protocol by remember { mutableStateOf(existing?.protocol ?: ProxyProtocol.SOCKS5) }
    var username by remember { mutableStateOf(existing?.username ?: "") }
    var password by remember { mutableStateOf("") }
    var regionQuery by remember { mutableStateOf(existing?.regionName ?: "") }
    var regionCode by remember { mutableStateOf(existing?.regionCode) }
    var notes by remember { mutableStateOf(existing?.notes ?: "") }
    var removePassword by remember { mutableStateOf(false) }
    var touched by remember { mutableStateOf(false) }

    val hostCheck = HostValidator.validate(host)
    val portCheck = PortValidator.validate(port, protocol)
    val hostError = hostCheck.issues.firstOrNull { it.severity == Severity.ERROR }
    val portError = portCheck.issues.firstOrNull { it.severity == Severity.ERROR }
    val canSave = hostError == null && portError == null &&
        portCheck.value != null && name.isNotBlank()

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            Modifier
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Text(
                if (existing == null) "Add a proxy" else "Edit proxy",
                style = MaterialTheme.typography.titleLarge
            )

            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text("Name") },
                placeholder = { Text("ProxyCheap US") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )

            OutlinedTextField(
                value = host,
                onValueChange = { host = it; touched = true },
                label = { Text("Host or IP") },
                placeholder = { Text("gateway.example.com") },
                singleLine = true,
                isError = touched && hostError != null,
                supportingText = (hostError?.message.takeIf { touched })?.let { { Text(it) } },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                modifier = Modifier.fillMaxWidth()
            )

            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = port,
                    onValueChange = { port = it.filter(Char::isDigit).take(5); touched = true },
                    label = { Text("Port") },
                    singleLine = true,
                    isError = touched && portError != null,
                    supportingText = (portError?.message.takeIf { touched })?.let { { Text(it) } },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.weight(1f)
                )
                OutlinedTextField(
                    value = regionQuery,
                    onValueChange = {
                        regionQuery = it
                        regionCode = RegionCatalog.search(it).firstOrNull()?.code
                            ?: RegionCatalog.byCode(it)?.code
                    },
                    label = { Text("Country") },
                    placeholder = { Text("United States") },
                    singleLine = true,
                    isError = regionQuery.isNotBlank() && regionCode == null,
                    supportingText = {
                        Text(
                            when {
                                regionCode == null && regionQuery.isNotBlank() ->
                                    "Not recognised. Start typing a country name and the first match is used."
                                regionCode != null ->
                                    "Used by the location filter. It is your label, not a lookup."
                                else -> "Optional. Lets you pick this proxy by location."
                            }
                        )
                    },
                    modifier = Modifier.weight(1f)
                )
            }

            Text("Protocol", style = MaterialTheme.typography.labelLarge)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                ProxyProtocol.entries.forEach { candidate ->
                    FilterChip(
                        selected = protocol == candidate,
                        onClick = {
                            protocol = candidate
                            port = candidate.defaultPort.toString()
                        },
                        label = { Text(candidate.displayName) }
                    )
                }
            }
            if (!protocol.supportsTunnelUpstream) {
                Text(
                    "Only SOCKS5 can carry the tunnel. ${protocol.displayName} can still be tested and " +
                        "exported, so storing it is not wasted.",
                    style = MaterialTheme.typography.bodySmall,
                    color = StatusColors.warn
                )
            }

            OutlinedTextField(
                value = username,
                onValueChange = { username = it },
                label = { Text("Username (optional)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )

            OutlinedTextField(
                value = password,
                onValueChange = { password = it },
                label = {
                    Text(
                        if (existing?.hasStoredPassword == true) "New password (leave blank to keep)"
                        else "Password (optional)"
                    )
                },
                singleLine = true,
                enabled = !removePassword,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                supportingText = {
                    Text("Kept in the Android Keystore, not in the app's JSON.")
                },
                modifier = Modifier.fillMaxWidth()
            )

            if (existing?.hasStoredPassword == true) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Switch(checked = removePassword, onCheckedChange = { removePassword = it })
                    Spacer(Modifier.width(12.dp))
                    Text("Remove the stored password", style = MaterialTheme.typography.bodyMedium)
                }
            }

            OutlinedTextField(
                value = notes,
                onValueChange = { notes = it },
                label = { Text("Notes (optional)") },
                minLines = 2,
                modifier = Modifier.fillMaxWidth()
            )

            Spacer(Modifier.height(4.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedButton(onClick = onDismiss, modifier = Modifier.weight(1f)) { Text("Cancel") }
                Button(
                    onClick = {
                        touched = true
                        if (!canSave) return@Button
                        val finalPassword = when {
                            removePassword -> ""
                            password.isNotEmpty() -> password
                            else -> null
                        }
                        onSave(
                            name.trim(),
                            hostCheck.sanitized,
                            portCheck.value ?: protocol.defaultPort,
                            protocol,
                            username.trim().takeIf { it.isNotEmpty() },
                            finalPassword,
                            regionCode,
                            notes.trim().takeIf { it.isNotEmpty() }
                        )
                    },
                    enabled = canSave,
                    modifier = Modifier.weight(1f)
                ) { Text("Save") }
            }
        }
    }
}

// ---------------------------------------------------------------------------
//  Paste import
// ---------------------------------------------------------------------------

/** How many preview rows to draw. A pasted file can be long; the count is still exact. */
private const val PREVIEW_ROWS = 40

/**
 * The paste importer.
 *
 * Parsing and storing are separate steps: the preview shows what was understood,
 * line by line, and nothing is written until the user confirms. Lines the parser
 * could not read are listed as such rather than silently dropped, because
 * "9 of 10 imported" is information the user needs.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PasteSheet(
    initialState: String?,
    viewModel: AppViewModel,
    onDismiss: () -> Unit
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val clipboard = LocalClipboardManager.current

    var text by remember { mutableStateOf(initialState ?: "") }
    var defaultProtocol by remember { mutableStateOf<ProxyProtocol?>(null) }
    var namePrefix by remember { mutableStateOf("") }
    var skipExisting by remember { mutableStateOf(true) }
    var excluded by remember { mutableStateOf(emptySet<Int>()) }
    var previewing by remember { mutableStateOf(false) }

    val preview = remember(text, defaultProtocol, previewing) {
        if (previewing) viewModel.previewImport(text, defaultProtocol) else null
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            Modifier
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Text("Paste proxies", style = MaterialTheme.typography.titleLarge)

            if (preview == null) {
                Text("One proxy per line, or a whole exported list.", style = MaterialTheme.typography.bodyMedium)

                Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)) {
                    Text(
                        """
                        socks5://user:pass@host:1080
                        host:1080:user:pass
                        user:pass@host:1080
                        host:1080
                        host = 1.2.3.4  port = 1080  user = me  pass = s3cret
                        {"host":"1.2.3.4","port":1080,"username":"me","password":"s3cret"}
                        ProxyCheap US | socks5://user:pass@host:1080
                        """.trimIndent(),
                        style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                        modifier = Modifier.padding(12.dp)
                    )
                }
                Text(
                    "A #fragment at the end of a share link becomes the name, and a country named in " +
                        "that name or label is remembered as the proxy's location.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )

                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it },
                    label = { Text("Proxies") },
                    minLines = 6,
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 160.dp)
                )

                OutlinedButton(onClick = {
                    clipboard.getText()?.text?.let { text = it }
                }) {
                    Icon(Icons.Default.ContentCopy, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text("Paste from clipboard")
                }

                Text("Assume this protocol when a line does not say", style = MaterialTheme.typography.labelLarge)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(
                        selected = defaultProtocol == null,
                        onClick = { defaultProtocol = null },
                        label = { Text("Detect") }
                    )
                    ProxyProtocol.entries.forEach { candidate ->
                        FilterChip(
                            selected = defaultProtocol == candidate,
                            onClick = { defaultProtocol = candidate },
                            label = { Text(candidate.displayName) }
                        )
                    }
                }

                Button(
                    onClick = { previewing = true },
                    enabled = text.isNotBlank(),
                    modifier = Modifier.fillMaxWidth()
                ) { Text("Preview") }
            } else {
                val ready = preview.ready
                val rejected = preview.rejected

                Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)) {
                    Column(Modifier.padding(12.dp)) {
                        Text(
                            "${ready.size} ready · ${rejected.size} unreadable",
                            style = MaterialTheme.typography.titleSmall
                        )
                        Text(
                            if (rejected.isEmpty()) "Nothing was dropped."
                            else "Unreadable lines are listed below and will not be imported.",
                            style = MaterialTheme.typography.bodySmall
                        )
                    }
                }

                ready.take(PREVIEW_ROWS).forEach { entry ->
                    val checked = entry.lineNumber !in excluded
                    val guess = RegionCatalog.guess(entry.name ?: entry.redactedSource)
                    ListItem(
                        headlineContent = {
                            Text(
                                entry.name ?: entry.host.orEmpty(),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        },
                        supportingContent = {
                            Column {
                                Text(
                                    entry.displayEndpoint,
                                    style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace)
                                )
                                Text(
                                    buildString {
                                        append(entry.protocol.displayName)
                                        guess?.let { append(" · ${it.name}") }
                                        if (!entry.username.isNullOrEmpty()) append(" · auth")
                                    },
                                    style = MaterialTheme.typography.labelSmall
                                )
                            }
                        },
                        leadingContent = {
                            Checkbox(
                                checked = checked,
                                onCheckedChange = { on ->
                                    excluded = if (on) excluded - entry.lineNumber
                                    else excluded + entry.lineNumber
                                }
                            )
                        }
                    )
                }
                if (ready.size > PREVIEW_ROWS) {
                    Text(
                        "…and ${ready.size - PREVIEW_ROWS} more, all included.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }

                rejected.forEach { entry ->
                    ListItem(
                        headlineContent = {
                            Text(
                                entry.redactedSource,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace)
                            )
                        },
                        supportingContent = {
                            Text(
                                entry.failure ?: "not understood",
                                style = MaterialTheme.typography.labelSmall,
                                color = StatusColors.warn
                            )
                        },
                        leadingContent = {
                            Icon(Icons.Default.Error, contentDescription = null, tint = StatusColors.warn)
                        }
                    )
                }

                OutlinedTextField(
                    value = namePrefix,
                    onValueChange = { namePrefix = it },
                    label = { Text("Prefix for imported names (optional)") },
                    placeholder = { Text("ProxyCheap") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )

                Row(verticalAlignment = Alignment.CenterVertically) {
                    Switch(checked = skipExisting, onCheckedChange = { skipExisting = it })
                    Spacer(Modifier.width(12.dp))
                    Text("Skip proxies I already have", style = MaterialTheme.typography.bodyMedium)
                }

                Text(
                    "Passwords from the pasted text go straight into the Keystore. The preview above never " +
                        "shows them.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )

                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    OutlinedButton(
                        onClick = { previewing = false },
                        modifier = Modifier.weight(1f)
                    ) { Text("Back") }
                    Button(
                        onClick = {
                            viewModel.importEntries(preview, namePrefix, skipExisting) { onDismiss() }
                        },
                        enabled = ready.isNotEmpty(),
                        modifier = Modifier.weight(1f)
                    ) { Text("Add ${ready.size}") }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
//  Export
// ---------------------------------------------------------------------------

/**
 * Export and share.
 *
 * The exported text contains the password in the clear, because a share link
 * without it does not work. That is why the warning cannot be dismissed, why the
 * toggle exists, and why the value is masked until it is deliberately revealed.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ExportSheet(profile: ProxyProfile, onDismiss: () -> Unit) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current

    var includePassword by remember { mutableStateOf(true) }
    var reveal by remember { mutableStateOf(false) }
    var copied by remember { mutableStateOf(false) }

    val password = remember(profile.id) {
        runCatching { ProfileStore(context).password(profile.id) }.getOrNull()
    }
    val credential = if (profile.usesAuthentication) {
        ProxyCredential(profile.username.orEmpty(), password.orEmpty())
    } else {
        null
    }

    // Three shapes of the same proxy. A full client configuration is deliberately
    // not generated: this app has no opinion about your client's routing rules, and
    // emitting a half-config that silently drops other outbounds would be worse
    // than emitting none.
    val shareLink = remember(profile, credential, includePassword) {
        ShareLink.format(profile, credential, includePassword = includePassword)
    }
    val plainFields = remember(profile, credential, includePassword) {
        buildString {
            appendLine("name = ${profile.name}")
            appendLine("protocol = ${profile.protocol.displayName}")
            appendLine("host = ${profile.host}")
            appendLine("port = ${profile.port}")
            if (!profile.username.isNullOrEmpty()) appendLine("username = ${profile.username}")
            if (includePassword && !password.isNullOrEmpty()) appendLine("password = $password")
            profile.regionCode?.let { appendLine("country = ${RegionCatalog.displayName(it)}") }
            profile.notes?.let { appendLine("notes = $it") }
        }.trim()
    }
    // Built with JSONObject rather than string interpolation: a password containing
    // a quote or a backslash would otherwise produce text that is not valid JSON.
    val jsonOutbound = remember(profile, credential, includePassword) {
        JSONObject().apply {
            put("type", if (profile.protocol == ProxyProtocol.SOCKS5) "socks" else "http")
            put("tag", profile.name)
            put("server", profile.host)
            put("server_port", profile.port)
            if (!profile.username.isNullOrEmpty()) {
                put("username", profile.username)
                if (includePassword && !password.isNullOrEmpty()) put("password", password)
            }
            if (profile.protocol == ProxyProtocol.SOCKS5) put("version", "5")
            if (profile.protocol.usesTls) {
                put("tls", JSONObject().put("enabled", true).put("server_name", profile.host))
            }
        }.toString(2)
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            Modifier
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Text("Export “${profile.name}”", style = MaterialTheme.typography.titleLarge)

            Card(colors = CardDefaults.cardColors(containerColor = StatusColors.warn.copy(alpha = 0.16f))) {
                Row(Modifier.padding(12.dp)) {
                    Icon(Icons.Default.Warning, contentDescription = null, tint = StatusColors.warn)
                    Spacer(Modifier.width(10.dp))
                    Text(
                        "This text contains the proxy password in plain form. Anything you share it with, " +
                            "or any app you share it to, can read it. Turn the password off if you only " +
                            "need the address.",
                        style = MaterialTheme.typography.bodySmall
                    )
                }
            }

            Row(verticalAlignment = Alignment.CenterVertically) {
                Switch(checked = includePassword, onCheckedChange = { includePassword = it; reveal = false })
                Spacer(Modifier.width(12.dp))
                Text("Include the password", style = MaterialTheme.typography.bodyMedium)
            }

            ExportBlock(
                title = "Share link",
                body = if (reveal || !includePassword) shareLink else mask(shareLink, password)
            )
            if (!password.isNullOrEmpty()) {
                TextButton(onClick = { reveal = !reveal }) {
                    Text(if (reveal) "Hide the password" else "Reveal the password")
                }
            }

            ExportBlock(
                title = "Plain fields",
                body = if (reveal || !includePassword) plainFields else mask(plainFields, password)
            )
            ExportBlock(
                title = "sing-box outbound",
                body = if (reveal || !includePassword) jsonOutbound else mask(jsonOutbound, password)
            )

            Text(
                "One outbound is exported, not a whole client configuration — your client's routing " +
                    "rules are yours to write.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            HorizontalDivider()

            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedButton(
                    onClick = {
                        clipboard.setText(AnnotatedString(shareLink))
                        copied = true
                    },
                    modifier = Modifier.weight(1f)
                ) {
                    Icon(Icons.Default.ContentCopy, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text(if (copied) "Copied" else "Copy link")
                }
                Button(
                    onClick = {
                        val intent = Intent(Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_SUBJECT, profile.name)
                            putExtra(Intent.EXTRA_TEXT, "$shareLink\n\n$plainFields\n\n$jsonOutbound")
                        }
                        runCatching {
                            context.startActivity(Intent.createChooser(intent, "Share proxy"))
                        }
                    },
                    modifier = Modifier.weight(1f)
                ) {
                    Icon(Icons.Default.IosShare, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text("Share")
                }
            }
        }
    }
}

@Composable
private fun ExportBlock(title: String, body: String) {
    Text(title, style = MaterialTheme.typography.labelLarge)
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)) {
        Text(
            body,
            style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp)
        )
    }
}

// ---------------------------------------------------------------------------
//  Location
// ---------------------------------------------------------------------------

/**
 * Pick a location from the countries your stored proxies claim.
 *
 * This is the honest version of "type a location and connect": the app searches the
 * list you built, never the internet. When nothing matches it says so — and offers the
 * one thing that is legitimate, which is asking a provider you already have an account
 * with whether they have a proxy there.
 *
 * @param onChoose the chosen region, or `null` for "any location".
 * @param onLookupFromProvider opens the provider lookup, pre-filled with the query.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LocationPickerSheet(
    state: AppViewModel.UiState,
    onDismiss: () -> Unit,
    onLookupFromProvider: (String) -> Unit,
    onChoose: (RegionCatalog.Region?) -> Unit
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var query by remember { mutableStateOf("") }

    val stored = state.availableRegions
    val storedCodes = stored.map { it.code }.toSet()
    val filtered = if (query.isBlank()) stored else stored.filter { it.matches(query) }
    val suggestions = remember(query, storedCodes) {
        if (query.isBlank()) emptyList()
        else RegionCatalog.search(query).filter { it.code !in storedCodes }.take(8)
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            Modifier
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Text("Choose a location", style = MaterialTheme.typography.titleLarge)

            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                label = { Text("Country or city") },
                placeholder = { Text("Netherlands") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )

            Text(
                "Only the proxies you have stored are searched. Nothing is fetched from the internet.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            if (filtered.isNotEmpty()) {
                Text("You have proxies in", style = MaterialTheme.typography.labelLarge)
                filtered.forEach { region ->
                    val count = state.profiles.count { it.regionCode == region.code }
                    ListItem(
                        headlineContent = { Text(region.name) },
                        supportingContent = {
                            Text(
                                state.profiles.firstOrNull { it.regionCode == region.code }
                                    ?.let { "${it.name} · ${it.displayEndpoint}" }
                                    .orEmpty(),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        },
                        leadingContent = { Icon(Icons.Default.Place, contentDescription = null) },
                        trailingContent = {
                            Text(
                                "$count ${if (count == 1) "proxy" else "proxies"}",
                                style = MaterialTheme.typography.labelSmall
                            )
                        }
                    )
                }
            } else {
                Card(colors = CardDefaults.cardColors(containerColor = StatusColors.warn.copy(alpha = 0.16f))) {
                    Column(Modifier.padding(12.dp)) {
                        Text(
                            if (query.isBlank()) "No stored proxy has a country label yet."
                            else "You have no stored proxy in “$query”.",
                            style = MaterialTheme.typography.titleSmall
                        )
                        Spacer(Modifier.height(4.dp))
                        // A plain empty state, as asked for: no pricing, no upsell. If a
                        // provider account exists, the one legitimate next step is offered;
                        // otherwise the app says nothing is available and stops.
                        Text(
                            if (state.providerHasKey) {
                                "The app will not search the open internet for free proxies. It can ask " +
                                    "the provider you have an account with whether they have one there."
                            } else {
                                "The app will not search the open internet for free proxies, and no " +
                                    "provider account is set up to ask. Nothing is available for this " +
                                    "location."
                            },
                            style = MaterialTheme.typography.bodySmall
                        )
                    }
                }

                if (query.isNotBlank()) {
                    OutlinedButton(
                        onClick = { onLookupFromProvider(query) },
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Icon(Icons.Default.CloudDownload, contentDescription = null)
                        Spacer(Modifier.width(8.dp))
                        Text(
                            if (state.providerHasKey) "Look up “$query” on your provider account"
                            else "Set up a provider account to look this up"
                        )
                    }
                }
            }

            if (suggestions.isNotEmpty()) {
                Text("Recognised, but nothing stored", style = MaterialTheme.typography.labelLarge)
                suggestions.forEach { region ->
                    ListItem(
                        headlineContent = { Text(region.name) },
                        supportingContent = {
                            Text(
                                "Add a proxy that exits here and it will be found by this name.",
                                style = MaterialTheme.typography.bodySmall
                            )
                        }
                    )
                }
            }

            HorizontalDivider()

            OutlinedButton(
                onClick = { onChoose(null) },
                modifier = Modifier.fillMaxWidth()
            ) { Text("Any location") }
        }
    }
}
