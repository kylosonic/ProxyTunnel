package io.github.kylosonic.proxytunnel.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val Accent = Color(0xFF5C8CFF)
private val AccentDark = Color(0xFF2F5FD0)
private val Danger = Color(0xFFFF5C68)
private val Warning = Color(0xFFFFB454)
private val Success = Color(0xFF43C59E)

/** Status colours the screens share, so "running" looks the same everywhere. */
object StatusColors {
    val good = Success
    val warn = Warning
    val bad = Danger
    val neutral = Color(0xFF8892A6)
}

private val DarkScheme = darkColorScheme(
    primary = Accent,
    onPrimary = Color(0xFF06122B),
    primaryContainer = AccentDark,
    onPrimaryContainer = Color(0xFFE6EDFF),
    secondary = Success,
    onSecondary = Color(0xFF04211A),
    error = Danger,
    onError = Color(0xFF2A0509),
    background = Color(0xFF0B0E15),
    onBackground = Color(0xFFE8ECF4),
    surface = Color(0xFF121724),
    onSurface = Color(0xFFE8ECF4),
    surfaceVariant = Color(0xFF1C2333),
    onSurfaceVariant = Color(0xFFA9B3C6),
    outline = Color(0xFF39415A)
)

private val LightScheme = lightColorScheme(
    primary = AccentDark,
    secondary = Color(0xFF1F8A6C),
    error = Color(0xFFB3261E)
)

@Composable
fun ProxyTunnelTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit
) {
    MaterialTheme(
        colorScheme = if (darkTheme) DarkScheme else LightScheme,
        content = content
    )
}
