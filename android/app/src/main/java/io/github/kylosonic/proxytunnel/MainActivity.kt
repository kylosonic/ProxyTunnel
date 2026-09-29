package io.github.kylosonic.proxytunnel

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.kylosonic.proxytunnel.ui.AppRoot
import io.github.kylosonic.proxytunnel.ui.ProxyTunnelTheme
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * The only activity.
 *
 * It does three things: hosts the Compose tree, and forwards a `socks5://` link
 * from another app into the paste importer — both on a cold start and when the app
 * is already running, which is why the intent goes through a flow rather than being
 * read once.
 */
class MainActivity : ComponentActivity() {

    private val incoming = MutableStateFlow<Intent?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        incoming.value = intent

        setContent {
            ProxyTunnelTheme {
                val shareIntent by incoming.collectAsStateWithLifecycle()
                AppRoot(shareIntent = shareIntent)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        incoming.value = intent
    }
}
