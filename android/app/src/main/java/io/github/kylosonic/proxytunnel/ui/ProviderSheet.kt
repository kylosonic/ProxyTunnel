package io.github.kylosonic.proxytunnel.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.CloudDownload
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.kylosonic.proxytunnel.core.ProviderApi
import io.github.kylosonic.proxytunnel.core.RegionCatalog

/**
 * "Type a location, get a proxy" — scoped to a provider you have an account with.
 *
 * The app never scrapes a proxy list and never auto-connects to an endpoint nobody
 * offered you. What it does instead is ask a provider you are a customer of, with a
 * key you generated, which of *your* proxies are in the country you typed. That is
 * the only version of this feature that can exist honestly, and it is the one here.
 *
 * The key field is write-only: it goes to the Keystore and is never read back into
 * the UI, not even masked.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProviderSheet(
    viewModel: AppViewModel,
    state: AppViewModel.UiState,
    initialRegion: String?,
    onDismiss: () -> Unit
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val provider = ProviderApi.Provider.WEBSHARE

    var apiKey by remember { mutableStateOf("") }
    var query by remember { mutableStateOf(initialRegion ?: "") }
    var editingKey by remember { mutableStateOf(!state.providerHasKey) }

    val lookup = state.provider
    val resolvedRegion = remember(query) {
        RegionCatalog.search(query).firstOrNull()
            ?: RegionCatalog.byCode(query)?.let { RegionCatalog.byCode(it.code) }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            Modifier
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Text("Find a proxy by location", style = MaterialTheme.typography.titleLarge)
            Text(
                "Asks ${provider.displayName}, the provider on your account, which of your proxies " +
                    "are in the country you type. Nothing is scraped and no other host is contacted.",
                style = MaterialTheme.typography.bodyMedium
            )

            // MARK: API key
            Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.CloudDownload, contentDescription = null)
                        Spacer(Modifier.width(8.dp))
                        Text(
                            if (state.providerHasKey) "API key stored" else "No API key yet",
                            style = MaterialTheme.typography.titleSmall
                        )
                    }

                    if (!editingKey) {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            TextButton(onClick = { editingKey = true }) { Text("Replace key") }
                            TextButton(onClick = {
                                viewModel.saveProviderKey(provider, "")
                                editingKey = true
                            }) { Text("Remove") }
                        }
                    } else {
                        OutlinedTextField(
                            value = apiKey,
                            onValueChange = { apiKey = it },
                            label = { Text("${provider.displayName} API key") },
                            singleLine = true,
                            visualTransformation = PasswordVisualTransformation(),
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                            supportingText = {
                                Text("Create one at ${provider.consoleHint}. Stored in the Keystore, never shown again.")
                            },
                            modifier = Modifier.fillMaxWidth()
                        )
                        Button(
                            onClick = {
                                viewModel.saveProviderKey(provider, apiKey)
                                apiKey = ""
                                editingKey = false
                            },
                            enabled = apiKey.isNotBlank(),
                            modifier = Modifier.fillMaxWidth()
                        ) { Text("Save key") }
                    }

                    Text(
                        "A free ${provider.displayName} account is enough. Their proxies are " +
                            "${provider.protocol.displayName}, which this app puts behind the tunnel with a " +
                            "local SOCKS5 bridge — no SOCKS5 plan needed.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }

            // MARK: location
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                label = { Text("Country") },
                placeholder = { Text("Netherlands") },
                singleLine = true,
                isError = query.isNotBlank() && resolvedRegion == null,
                supportingText = {
                    Text(
                        if (query.isNotBlank() && resolvedRegion == null) {
                            "Type a country name, or a two-letter code in capitals."
                        } else {
                            resolvedRegion?.let { "Looking in ${it.name}." } ?: "Leave blank for every country."
                        }
                    )
                },
                modifier = Modifier.fillMaxWidth()
            )

            Button(
                onClick = { viewModel.lookup(provider, resolvedRegion?.code) },
                enabled = !lookup.running && state.providerHasKey && (query.isBlank() || resolvedRegion != null),
                modifier = Modifier.fillMaxWidth()
            ) {
                Icon(Icons.Default.CloudDownload, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text(if (query.isBlank()) "Fetch all my proxies" else "Fetch my proxies in this country")
            }

            if (!state.providerHasKey) {
                Text(
                    "Save an API key first.",
                    style = MaterialTheme.typography.bodySmall,
                    color = StatusColors.warn
                )
            }

            // MARK: result
            if (lookup.running) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.height(18.dp).width(18.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(12.dp))
                    Text("Asking ${provider.displayName}…")
                }
            }

            when (val result = lookup.result) {
                is ProviderApi.Result.Success -> {
                    HorizontalDivider()
                    Text(
                        "${result.proxies.size} ${if (result.proxies.size == 1) "proxy" else "proxies"} found",
                        style = MaterialTheme.typography.titleSmall
                    )
                    result.proxies.take(25).forEach { proxy ->
                        ListItem(
                            headlineContent = {
                                Text(proxy.suggestedName(), maxLines = 1, overflow = TextOverflow.Ellipsis)
                            },
                            supportingContent = {
                                Text(
                                    "${proxy.host}:${proxy.port} · ${provider.protocol.displayName}" +
                                        if (proxy.username != null) " · auth" else "",
                                    style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace)
                                )
                            },
                            leadingContent = {
                                Icon(Icons.Default.Place, contentDescription = null)
                            }
                        )
                    }
                    if (result.proxies.size > 25) {
                        Text(
                            "…and ${result.proxies.size - 25} more, all included.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    Button(
                        onClick = {
                            viewModel.addFetched(result.proxies) { onDismiss() }
                        },
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Icon(Icons.Default.CheckCircle, contentDescription = null)
                        Spacer(Modifier.width(8.dp))
                        Text("Add and select")
                    }
                    Text(
                        "Credentials from the provider go straight into the Keystore. They are never " +
                            "shown here.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }

                is ProviderApi.Result.Failure -> {
                    HorizontalDivider()
                    Card(
                        colors = CardDefaults.cardColors(
                            containerColor = if (result.kind == ProviderApi.Result.Kind.EMPTY) {
                                MaterialTheme.colorScheme.surfaceVariant
                            } else {
                                StatusColors.bad.copy(alpha = 0.16f)
                            }
                        )
                    ) {
                        Column(Modifier.padding(12.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(
                                    if (result.kind == ProviderApi.Result.Kind.EMPTY) Icons.Default.Place
                                    else Icons.Default.Error,
                                    contentDescription = null,
                                    tint = if (result.kind == ProviderApi.Result.Kind.EMPTY) {
                                        MaterialTheme.colorScheme.onSurfaceVariant
                                    } else {
                                        StatusColors.bad
                                    }
                                )
                                Spacer(Modifier.width(8.dp))
                                Text(
                                    result.message,
                                    style = MaterialTheme.typography.bodyMedium
                                )
                            }
                            // A suggestion is deliberately absent for an empty result:
                            // when there is nothing in that country, the app says so and
                            // stops. No upsell, no pricing, no guessing.
                            result.suggestion?.let { hint ->
                                Spacer(Modifier.height(4.dp))
                                Text(
                                    hint,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    }
                }

                null -> Unit
            }

            Text(
                "This app will not search the open internet for free proxies. Lists advertised that way " +
                    "are open proxies on machines nobody offered you, and a real share of them are " +
                    "honeypots published so the traffic through them can be read.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}
