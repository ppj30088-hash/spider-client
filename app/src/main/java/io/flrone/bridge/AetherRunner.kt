package io.flrone.bridge

import android.content.Context
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ktx.app
import io.nekohasekai.sagernet.outbound.types.Socks
import java.io.File
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.Socket
import java.net.URL

/**
 * The Aether helper: a bundled native binary (CluvexStudio/Aether, v2.4.0) that
 * finds a reachable route by itself and exposes it as a local SOCKS5 proxy.
 *
 * The app itself never speaks MASQUE or WireGuard here: Aether does that, and
 * the core only sees an ordinary SOCKS5 outbound at 127.0.0.1:1819 — the
 * Aether profile [AetherProfiles] creates. So this object owns exactly one
 * thing: the helper process. Start it before the core comes up, stop it after
 * the core goes down. Everything else (config, VPN, UI) is the existing
 * machinery working on the Aether profile like any other SOCKS profile.
 *
 * The binary ships per ABI as `libaether.so` in the APK's jniLibs, which the
 * installer extracts to the native library dir (legacy packaging is on, so the
 * files are deflated at install time).
 *
 * The helper runs as a child process of this app, so it shares this UID.
 * That is why the tunnel must never capture this app (see VpnService):
 * the helper's own traffic would enter the tunnel, where the core sends it
 * to its default outbound — the helper's own SOCKS proxy — and loop
 * forever, which is exactly how registration retried endlessly while no
 * traffic flowed.
 */
object AetherRunner {

    /** The SOCKS5 listener Aether opens (its default; passed explicitly too). */
    const val SOCKS_HOST = "127.0.0.1"
    const val SOCKS_PORT = 1819

    /** Aether's own name for the profile it routes through, also the group name. */
    const val PROFILE_NAME = "Aether"

    /**
     * How long a start may take: the first run registers a WARP device and
     * then scans for a route, which on a slow network is tens of seconds.
     * The UI shows "starting" for this whole window, so it must be generous
     * rather than exact.
     */
    private const val START_TIMEOUT_MS = 120_000L
    private const val STOP_GRACE_MS = 3_000L
    private const val LOG_TAIL_LINES = 8

    /**
     * What proves the route: a tiny Cloudflare endpoint that answers HTTP
     * 200 with no body to speak of, fetched through the helper's own proxy.
     * Each attempt is bounded so a proxy that accepts and never answers
     * fails fast instead of hanging the start.
     */
    private const val VALIDATE_HOST = "www.cloudflare.com"
    private const val VALIDATE_PATH = "/cdn-cgi/trace"
    private const val VALIDATE_TIMEOUT_MS = 8_000
    private const val VALIDATE_RETRY_MS = 2_000L

    /** The watchdog re-checks the route this often while connected. */
    private const val WATCHDOG_INTERVAL_MS = 15_000L
    /** Consecutive failed checks before the watchdog rescans. */
    private const val WATCHDOG_MAX_FAILURES = 2

    @Volatile
    private var process: Process? = null

    @Volatile
    private var startedAtMs: Long = 0L

    @Volatile
    private var watchdogThread: Thread? = null

    @Volatile
    private var watchdogStop = false

    /** The private dir: identity files and the log. */
    fun dataDir(context: Context = app): File = File(context.filesDir, "aether").apply { mkdirs() }

    private fun logFile(context: Context = app): File = File(dataDir(context), "aether.log")

    /** True when the helper process is alive, whatever the port says. */
    fun isProcessAlive(): Boolean = process?.isAlive == true

    /** True when something answers on the helper's SOCKS5 port. */
    fun isPortOpen(): Boolean = try {
        Socket().use { it.connect(InetSocketAddress(SOCKS_HOST, SOCKS_PORT), 500) }
        true
    } catch (_: Exception) {
        false
    }

    /** True when the helper is up and its proxy answers: the connected state. */
    fun isConnected(): Boolean = isProcessAlive() && isPortOpen()

    /**
     * True when a real request crosses the helper's SOCKS5 proxy and comes
     * back HTTP 200: the route behind the proxy actually moves traffic. A
     * port that answers only proves the listener is up — the helper opens
     * it before any route exists, and a gateway can answer the handshake
     * and still drop every byte. The request is plain HTTP through the
     * tunnel, so no TLS is involved, and the host is resolved by the proxy
     * (remote DNS), not on the phone.
     */
    private fun isRouteWorking(): Boolean {
        return try {
            val proxy = Proxy(Proxy.Type.SOCKS, InetSocketAddress(SOCKS_HOST, SOCKS_PORT))
            val conn = URL("http://$VALIDATE_HOST$VALIDATE_PATH").openConnection(proxy) as HttpURLConnection
            conn.connectTimeout = VALIDATE_TIMEOUT_MS
            conn.readTimeout = VALIDATE_TIMEOUT_MS
            conn.requestMethod = "GET"
            conn.instanceFollowRedirects = false
            val ok = conn.responseCode == HttpURLConnection.HTTP_OK
            conn.disconnect()
            ok
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Whether [profile] is the Aether profile: the stored id first, and the
     * shape of the profile (SOCKS at 127.0.0.1:1819 named Aether) as a fallback
     * for a database that lost the stored id.
     */
    fun isAetherProfile(profile: ProxyEntity): Boolean {
        if (profile.id > 0L && profile.id == DataStore.aetherProfileId) return true
        val outbound = profile.outbound
        return outbound is Socks && outbound.server == SOCKS_HOST &&
            outbound.serverPort == SOCKS_PORT && profile.name == PROFILE_NAME
    }

    /** The native service path's hook: start the helper only for an Aether start. */
    fun startIfNeeded(context: Context = app, profile: ProxyEntity) {
        if (isAetherProfile(profile)) start(context)
    }

    /**
     * Starts the helper unless it is already up. Blocks (on the caller's IO
     * thread) until a real request crosses the proxy and comes back HTTP 200
     * or the start times out; throws with the helper's last log lines when
     * it dies or never passes traffic. A port that answers is not enough:
     * the helper opens its listener before any route exists, and the core
     * and the VPN come up the moment this returns, so returning early would
     * put the VPN up over a helper that is still registering and scanning —
     * and, before the app was excluded from its own tunnel, its traffic
     * looped back into itself. The process table is only locked for the
     * hand-over, never for the wait, so the UI's status polls keep answering
     * while a start scans.
     *
     * The invocation is hardened for strict networks (Aether's own guide
     * prescribes each of these for Iran): HTTP/2 over TCP instead of
     * QUIC/UDP, fragment the TLS ClientHello so SNI-based resets do not kill
     * the WARP API calls, the heaviest MASQUE obfuscation profile, and a
     * scan that only trusts a gateway after a real HTTP request crossed it —
     * the plain balanced scan trusted gateways on a handshake, which is how
     * a dead route looked "connected" while no traffic flowed. [freshScan]
     * also ignores the cached last-working gateway and scans from scratch.
     */
    fun start(context: Context = app, freshScan: Boolean = false): Map<String, Any?> {
        val proc: Process
        val startMs: Long
        synchronized(this) {
            if (isConnected()) {
                startWatchdog()
                return statusMap(alreadyRunning = true)
            }
            stopLocked()
            // Something else is already answering on the helper's port: a
            // second helper cannot bind there, and waiting for traffic
            // through a stranger's proxy would only time out confusingly.
            if (isPortOpen()) {
                error("Aether could not start: port $SOCKS_PORT is already in use by another app. Stop that app (or restart the phone) and try again.")
            }
            val binary = resolveBinary(context)
            val dir = dataDir(context)
            val log = logFile(context)
            val command = buildList {
                add(binary.absolutePath)
                add("--masque")
                add("--h2")
                add("--fragment")
                add("--noize"); add("gfw")
                add("--scan"); add("ironclad")
                add("--startup-secs"); add("90")
                add("--validate-secs"); add("20")
                if (freshScan) add("--no-quick-reconnect")
                add("--bind"); add("$SOCKS_HOST:$SOCKS_PORT")
                add("--config"); add(File(dir, "aether.toml").absolutePath)
                add("--masque-config"); add(File(dir, "aether-masque.toml").absolutePath)
                add("--wg-config"); add(File(dir, "aether-wg.toml").absolutePath)
            }
            Logs.i("aether: starting ${binary.absolutePath}")
            proc = ProcessBuilder(command)
                .directory(dir)
                .redirectOutput(ProcessBuilder.Redirect.to(log))
                .redirectErrorStream(true)
                .apply {
                    environment()["HOME"] = dir.absolutePath
                    environment()["AETHER_LOG_LEVEL"] = "info"
                }
                .start()
            process = proc
            startMs = System.currentTimeMillis()
            startedAtMs = startMs
        }
        val deadline = startMs + START_TIMEOUT_MS
        while (System.currentTimeMillis() < deadline) {
            if (!proc.isAlive) {
                synchronized(this) { if (process === proc) process = null }
                val tail = lastLogLines(context)
                error("Aether stopped while starting" + tail.joinToString("\n", prefix = "\n"))
            }
            if (isRouteWorking()) {
                Logs.i("aether: traffic flows through the SOCKS5 proxy at $SOCKS_HOST:$SOCKS_PORT")
                startWatchdog()
                return statusMap(alreadyRunning = false)
            }
            Thread.sleep(VALIDATE_RETRY_MS)
        }
        stop()
        val tail = lastLogLines(context)
        error("Aether found no working route in time" + tail.joinToString("\n", prefix = "\n"))
    }

    /** Stops the helper and starts it again with a fresh scan, ignoring any cached last-working gateway. */
    fun rescan(context: Context = app): Map<String, Any?> {
        stop()
        return start(context, freshScan = true)
    }

    /** Stops the helper when it runs; a no-op otherwise. */
    fun stop() {
        synchronized(this) { stopLocked() }
    }

    private fun stopLocked() {
        stopWatchdog()
        val proc = process ?: return
        process = null
        try {
            proc.destroy()
            val exited = try {
                proc.waitFor(STOP_GRACE_MS, java.util.concurrent.TimeUnit.MILLISECONDS)
            } catch (_: InterruptedException) {
                false
            }
            if (!exited) proc.destroyForcibly()
        } catch (error: Throwable) {
            Logs.w("aether: stop failed: ${error.message}")
        } finally {
            startedAtMs = 0L
        }
    }

    /**
     * Watches the route while the helper is up: nothing else monitors it
     * once connected, and on phones that kill background processes the
     * helper can die silently while the card still says Connected. Every
     * [WATCHDOG_INTERVAL_MS] a real request crosses the proxy; two
     * consecutive failures rescan from scratch, and a dead process is
     * restarted. Runs on its own daemon thread and never blocks a start
     * or a stop: a stop kills the watchdog first, and the watchdog checks
     * the stop flag — and that it is still the current watchdog thread —
     * again before restarting or rescanning anything, so a rescan that
     * replaces the watchdog cannot leave two of them running.
     */
    private fun startWatchdog() {
        synchronized(this) {
            if (watchdogThread?.isAlive == true) return
            watchdogStop = false
            val thread = Thread({
                val self = Thread.currentThread()
                var failures = 0
                while (!watchdogStop && watchdogThread === self) {
                    try {
                        Thread.sleep(WATCHDOG_INTERVAL_MS)
                    } catch (_: InterruptedException) {
                        break
                    }
                    if (watchdogStop || watchdogThread !== self) break
                    if (!isProcessAlive()) {
                        Logs.w("aether: helper died; restarting it")
                        if (watchdogStop || watchdogThread !== self) break
                        runCatching { start() }
                            .onFailure { Logs.w("aether: restart failed: ${it.message}") }
                        failures = 0
                    } else if (!isRouteWorking()) {
                        failures++
                        Logs.w("aether: route check failed $failures/$WATCHDOG_MAX_FAILURES")
                        if (failures >= WATCHDOG_MAX_FAILURES) {
                            failures = 0
                            Logs.w("aether: route dead twice in a row; rescanning")
                            if (watchdogStop || watchdogThread !== self) break
                            runCatching { rescan() }
                                .onFailure { Logs.w("aether: rescan failed: ${it.message}") }
                        }
                    } else {
                        failures = 0
                    }
                }
            }, "aether-watchdog")
            thread.isDaemon = true
            watchdogThread = thread
            thread.start()
        }
    }

    private fun stopWatchdog() {
        synchronized(this) {
            watchdogStop = true
            val thread = watchdogThread
            watchdogThread = null
            // Never interrupt the calling thread itself: a rescan runs on
            // the watchdog thread, and an interrupt there would abort the
            // fresh start's wait instead of stopping the old watchdog.
            if (thread != null && thread != Thread.currentThread()) {
                thread.interrupt()
            }
        }
    }

    /** The status the UI polls: process, proxy, uptime and the last log lines. */
    fun status(): Map<String, Any?> = statusMap(alreadyRunning = false)

    private fun statusMap(alreadyRunning: Boolean): Map<String, Any?> = mapOf(
        "running" to isProcessAlive(),
        "connected" to isConnected(),
        "alreadyRunning" to alreadyRunning,
        "host" to SOCKS_HOST,
        "port" to SOCKS_PORT,
        "uptimeMs" to if (startedAtMs > 0L) System.currentTimeMillis() - startedAtMs else 0L,
        "log" to lastLogLines(),
    )

    private fun lastLogLines(context: Context = app): List<String> {
        val log = logFile(context)
        if (!log.isFile) return emptyList()
        return runCatching {
            val lines = log.readLines().filter { it.isNotBlank() }
            lines.takeLast(LOG_TAIL_LINES)
        }.getOrDefault(emptyList())
    }

    /**
     * The executable helper: the copy the installer extracted to the native
     * library dir. That is the only valid location: running a binary out of
     * the app's private files dir is blocked on Android 10+, so the old
     * fallback of extracting it from the APK zip there could never execute
     * and only failed confusingly later.
     */
    private fun resolveBinary(context: Context): File {
        val extracted = File(context.applicationInfo.nativeLibraryDir, "libaether.so")
        if (extracted.isFile && extracted.canExecute()) return extracted
        error("Aether is not installed for this device (no libaether.so found)")
    }
}
