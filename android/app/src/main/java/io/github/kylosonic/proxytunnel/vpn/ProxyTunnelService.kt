package io.github.kylosonic.proxytunnel.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import hev.htproxy.TProxyService
import io.github.kylosonic.proxytunnel.MainActivity
import io.github.kylosonic.proxytunnel.R
import io.github.kylosonic.proxytunnel.core.HevConfig
import io.github.kylosonic.proxytunnel.core.ProxyProtocol
import io.github.kylosonic.proxytunnel.core.ProxyProfile
import io.github.kylosonic.proxytunnel.data.ProfileStore
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File
import kotlin.concurrent.thread

/**
 * The packet tunnel.
 *
 * ## Why this is so much shorter than the iOS equivalent
 *
 * On iOS the extension is handed raw IP packets and has to terminate TCP itself;
 * that is where the userspace TCP/IP stack in `Packages/ProxyTunnelCore` comes
 * from. Android is the same shape — `VpnService.Builder.establish()` hands back a
 * `ParcelFileDescriptor` on a tun interface — but the engine that turns those
 * packets into a SOCKS5 stream is supplied by hev-socks5-tunnel, a purpose-built
 * C library that explicitly supports Android and is used by SocksTun and Orbot.
 *
 * ## No entitlement, no account
 *
 * `VpnService` needs the user's consent through `VpnService.prepare()`, and
 * nothing else. There is no paid-programme requirement, no provisioning profile
 * and no expiry — the wall this project hit on iOS simply does not exist here.
 *
 * ## Loop avoidance
 *
 * `addDisallowedApplication(packageName)` takes this app out of its own tunnel, so
 * the socket that carries traffic to the SOCKS5 proxy cannot be routed back into
 * the tunnel. That is the Android-native equivalent of the excluded routes the iOS
 * extension has to install by hand, and it is considerably harder to get wrong.
 */
class ProxyTunnelService : VpnService() {

    enum class State { STOPPED, STARTING, RUNNING, STOPPING, FAILED }

    data class Status(
        val state: State = State.STOPPED,
        val profileName: String? = null,
        val upstream: String? = null,
        val bytesIn: Long = 0,
        val bytesOut: Long = 0,
        val packetsIn: Long = 0,
        val packetsOut: Long = 0,
        val failure: String? = null
    )

    private var tun: ParcelFileDescriptor? = null
    private var configFile: File? = null
    private var tunnelThread: Thread? = null
    private var statsThread: Thread? = null

    @Volatile
    private var stopping = false

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopTunnel()
                return START_NOT_STICKY
            }
            ACTION_START, null -> {
                // A null intent means the system restarted us, which for a VPN it
                // does after a crash — start with the last profile so Always-on VPN
                // keeps working.
                val profileId = intent?.getStringExtra(EXTRA_PROFILE_ID)
                    ?: ProfileStore(this).selectedProfileId
                if (profileId == null) {
                    publish(Status(state = State.FAILED, failure = "No proxy profile selected."))
                    stopSelf()
                    return START_NOT_STICKY
                }
                startTunnel(profileId)
                return START_STICKY
            }
        }
        return START_NOT_STICKY
    }

    /** The user revoked consent from system settings, or another VPN took over. */
    override fun onRevoke() {
        stopTunnel()
        super.onRevoke()
    }

    override fun onDestroy() {
        if (!stopping) stopTunnel()
        super.onDestroy()
    }

    // MARK: start

    private fun startTunnel(profileId: String) {
        if (status.value.state == State.RUNNING || status.value.state == State.STARTING) return
        publish(Status(state = State.STARTING))

        val store = ProfileStore(this)
        val profile = store.find(profileId)
        if (profile == null) {
            fail("That proxy profile no longer exists.")
            return
        }
        if (profile.protocol != ProxyProtocol.SOCKS5) {
            // Worth saying plainly rather than letting the engine fail obscurely:
            // hev-socks5-tunnel speaks SOCKS5 only.
            fail("The tunnel upstream must be SOCKS5. \"${profile.name}\" is ${profile.protocol.displayName}.")
            return
        }

        val password = store.password(profile.id)
        if (profile.usesAuthentication && password == null) {
            fail("No password is stored for \"${profile.name}\". Re-enter it in the proxy's settings.")
            return
        }

        startForeground(NOTIFICATION_ID, buildNotification(profile.name, "Starting…"))

        val builder = Builder()
            .setMtu(HevConfig.DEFAULT_MTU)
            .addAddress(HevConfig.TUN_IPV4, HevConfig.TUN_IPV4_PREFIX)
            .addRoute("0.0.0.0", 0)
            .addAddress(HevConfig.TUN_IPV6, HevConfig.TUN_IPV6_PREFIX)
            .addRoute("::", 0)
            .setSession("ProxyTunnel — ${profile.name}")

        // The resolvers advertised to apps. The tunnel does not terminate DNS
        // itself: hev relays UDP through the SOCKS5 association, so queries reach
        // the proxy's egress rather than the carrier's resolver, which is the same
        // leak-avoidance property the iOS tunnel provides.
        listOf("1.1.1.1", "1.0.0.1").forEach { builder.addDnsServer(it) }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }

        // Take this app out of its own tunnel. Without this the socket carrying
        // traffic to the proxy would be routed into the tunnel, and the tunnel
        // would never come up.
        runCatching { builder.addDisallowedApplication(packageName) }

        val descriptor = try {
            builder.establish()
        } catch (e: Exception) {
            fail("Could not establish the tunnel interface: ${e.message}")
            return
        }

        if (descriptor == null) {
            fail("Android refused to establish the tunnel. VPN permission was probably not granted.")
            return
        }
        tun = descriptor

        val config = try {
            writeConfig(profile, password)
        } catch (e: Exception) {
            fail("Could not write the tunnel configuration: ${e.message}")
            return
        }
        configFile = config

        // TProxyStartService blocks until the tunnel stops, so it gets its own
        // thread. It is the engine's documented contract.
        tunnelThread = thread(name = "hev-socks5-tunnel", isDaemon = true) {
            val result = runCatching {
                TProxyService.TProxyStartService(config.absolutePath, descriptor.fd)
            }
            val problem = result.exceptionOrNull()
            if (problem != null) {
                Log.e(TAG, "tunnel engine threw", problem)
                fail("The tunnel engine failed: ${problem.message}")
                return@thread
            }
            if (result.getOrNull() == false && !stopping) {
                fail("The tunnel engine could not start. Check the proxy address and credentials.")
            }
        }

        publish(
            Status(
                state = State.RUNNING,
                profileName = profile.name,
                upstream = profile.displayEndpoint
            )
        )
        startForeground(NOTIFICATION_ID, buildNotification(profile.name, "Connected to ${profile.displayEndpoint}"))
        startStatsPolling()
    }

    /**
     * Writes the engine's configuration.
     *
     * Written with owner-only permissions into the app's private directory, and
     * deleted on stop: it is the one place on Android where the password touches
     * the filesystem, because the engine takes a path rather than a buffer.
     */
    private fun writeConfig(profile: ProxyProfile, password: String?): File {
        val file = File(filesDir, HevConfig.FILE_NAME)
        val text = HevConfig.yaml(
            host = profile.host,
            port = profile.port,
            username = profile.username,
            password = password
        )
        file.writeText(text)
        runCatching {
            file.setReadable(false, false)
            file.setReadable(true, true)
            file.setWritable(false, false)
            file.setWritable(true, true)
        }
        return file
    }

    // MARK: stop

    private fun stopTunnel() {
        if (stopping) return
        stopping = true
        publish(status.value.copy(state = State.STOPPING))

        runCatching { TProxyService.TProxyStopService() }
        tunnelThread?.let { runCatching { it.join(2_000) } }
        tunnelThread = null
        statsThread = null

        runCatching { tun?.close() }
        tun = null

        // The config holds the password, so it goes as soon as the tunnel does.
        runCatching { configFile?.delete() }
        configFile = null

        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        }
        publish(Status(state = State.STOPPED))
        stopping = false
        stopSelf()
    }

    private fun fail(message: String) {
        Log.e(TAG, "tunnel failure: $message")
        publish(Status(state = State.FAILED, failure = message))
        runCatching { tun?.close() }
        tun = null
        runCatching { configFile?.delete() }
        configFile = null
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) stopForeground(STOP_FOREGROUND_REMOVE)
            else {
                @Suppress("DEPRECATION") stopForeground(true)
            }
        }
        stopSelf()
    }

    // MARK: statistics

    private fun startStatsPolling() {
        statsThread = thread(name = "hev-stats", isDaemon = true) {
            while (!stopping && !Thread.currentThread().isInterrupted) {
                val stats = runCatching { TProxyService.TProxyGetStats() }.getOrNull()
                if (stats != null && stats.size >= 4) {
                    publish(
                        status.value.copy(
                            packetsOut = stats[0],
                            bytesOut = stats[1],
                            packetsIn = stats[2],
                            bytesIn = stats[3]
                        )
                    )
                }
                runCatching { Thread.sleep(1_000) }
            }
        }
    }

    // MARK: notification

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.notification_channel_name),
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = getString(R.string.notification_channel_description)
            setShowBadge(false)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun buildNotification(profileName: String, detail: String): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, ProxyTunnelService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.notification_title, profileName))
            .setContentText(detail)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(open)
            .addAction(
                Notification.Action.Builder(null, getString(R.string.disconnect), stop).build()
            )
            .setOngoing(true)
            .build()
    }

    // MARK: plumbing

    private fun publish(newStatus: Status) {
        _status.value = newStatus
    }

    companion object {
        private const val TAG = "ProxyTunnelService"
        private const val CHANNEL_ID = "proxytunnel.vpn"
        private const val NOTIFICATION_ID = 4711

        const val ACTION_START = "io.github.kylosonic.proxytunnel.START"
        const val ACTION_STOP = "io.github.kylosonic.proxytunnel.STOP"
        const val EXTRA_PROFILE_ID = "profileId"

        private val _status = MutableStateFlow(Status())

        /** Observable tunnel state, so the UI shows what the service is doing rather than guessing. */
        val status: StateFlow<Status> = _status.asStateFlow()

        fun start(context: Context, profileId: String) {
            val intent = Intent(context, ProxyTunnelService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_PROFILE_ID, profileId)
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            val intent = Intent(context, ProxyTunnelService::class.java).setAction(ACTION_STOP)
            context.startService(intent)
        }
    }
}
