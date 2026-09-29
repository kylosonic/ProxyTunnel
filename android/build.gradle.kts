// ---------------------------------------------------------------------------
//  Root Gradle build for the Android app.
//
//  This project is deliberately separate from the iOS one: it shares the
//  *interchange* with it (share links and the paste formats are identical), not
//  the code. The Swift core cannot run here, and rather than port a userspace
//  TCP/IP stack to Kotlin the Android app uses hev-socks5-tunnel, a purpose-built
//  tun2socks-over-SOCKS5 engine that explicitly supports Android and is used by
//  SocksTun and Orbot.
//
//  See android/README.md for why that choice was made and what it costs.
// ---------------------------------------------------------------------------

plugins {
    id("com.android.application") version "8.7.3" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.21" apply false
}
