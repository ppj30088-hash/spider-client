package io.flrone.bridge

import android.content.Context
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.database.SagerDatabase
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
 * The helper: one bundled native binary (CluvexStudio/Aether, v2.4.0) that
 * finds a reachable route by itself and exposes it as a local SOCKS5 proxy,
 * in one of three modes. The app itself never speaks MASQUE, WireGuard or
 * Psiphon here: the helper does that, and the core only sees an ordinary
 * SOCKS5 outbound — the profile [AetherProfiles] / [PsiphonProfiles]
 * creates. So this object owns exactly one thing: the helper process.
 * Start it before the core comes up, stop it after the core goes down.
 * Everything else (config, VPN, UI) is the existing machinery working on
 * the helper's profile like any other SOCKS profile.
 *
 * The three modes, one process at a time:
 * - AETHER: Aether's own WARP/MASQUE tunnel, on 127.0.0.1:1819.
 * - PSIPHON: Aether's built-in Psiphon mode (`--psiphon-only`): no WARP
 *   tunnel at all, the proxy on 127.0.0.1:1820 is plain Psiphon. It runs
 *   the psiphon-tunnel-core console binary as a child of Aether, with
 *   Aether's own built-in Psiphon config (placeholder channel/sponsor,
 *   Psiphon's public server list) — no config needed from the user.
 * - CHAIN: Aether's `--psiphon` mode: the WARP tunnel carries Psiphon
 *   inside it (aether -> warp -> psiphon -> internet), served on
 *   127.0.0.1:1821. The WARP SOCKS on 1819 still serves underneath it.
 *
 * The binary ships per ABI as `libaether.so` in the APK's jniLibs, which the
 * installer extracts to the native library dir (legacy packaging is on, so the
 * files are deflated at install time). The Psiphon console binary ships the
 * same way as `libpsiphon.so` (built with Aether's own psiphon-build.sh from
 * its pinned psiphon-tunnel-core fork commit); Aether finds it through
 * AETHER_PSIPHON_BIN.
 *
 * The helper runs as a child process of this app, so it shares this UID.
 * That is why the tunnel must never capture this app (see VpnService):
 * the helper's own traffic would enter the tunnel, where the core sends it
 * to its default outbound — the helper's own SOCKS proxy — and loop
 * forever, which is exactly how registration retried endlessly while no
 * traffic flowed.
 */
object AetherRunner {

    /** The SOCKS5 listener Aether opens for its own WARP tunnel. */
    const val SOCKS_HOST = "127.0.0.1"
    const val SOCKS_PORT = 1819

    /** The SOCKS5 listener Aether's Psiphon-only mode serves on. */
    const val PSIPHON_SOCKS_PORT = 1820

    /** The SOCKS5 listener the chained (warp -> psiphon) mode serves on. */
    const val CHAIN_SOCKS_PORT = 1821

    /** Aether's own name for the profile it routes through, also the group name. */
    const val PROFILE_NAME = "Aether"

    /** The Psiphon profile's name, also the group name. */
    const val PSIPHON_PROFILE_NAME = "Psiphon"

    /** The chained profile's name; its group is "Chain". */
    const val CHAIN_PROFILE_NAME = "Aether+Psiphon"

    /** The chained profile's group name. */
    const val CHAIN_GROUP_NAME = "Chain"

    /** The helper's mode: which tunnel the single process runs. */
    enum class Mode(val key: String) {
        AETHER("aether"),
        PSIPHON("psiphon"),
        CHAIN("chain"),
    }

    /** The SOCKS5 port a mode serves on. */
    fun portFor(mode: Mode): Int = when (mode) {
        Mode.AETHER -> SOCKS_PORT
        Mode.PSIPHON -> PSIPHON_SOCKS_PORT
        Mode.CHAIN -> CHAIN_SOCKS_PORT
    }

    /**
     * How long a start may take. The WARP first run registers a device and
     * then scans for a route, which on a slow network is tens of seconds.
     * Psiphon takes longer: Aether gives it 180s to come up, and a chain
     * needs the warp tunnel first and then Psiphon through it. The UI shows
     * "starting" for this whole window, so it must be generous rather than
     * exact.
     */
    private const val START_TIMEOUT_AETHER_MS = 120_000L
    private const val START_TIMEOUT_PSIPHON_MS = 300_000L
    private const val START_TIMEOUT_CHAIN_MS = 300_000L

    /**
     * When a failed egress probe means "no route" rather than "not yet": the
     * warp scan's own window for Aether, Psiphon's ready window for Psiphon,
     * and both together for a chain. The UI reads this from the status map.
     */
    private const val STARTUP_WINDOW_AETHER_MS = 90_000L
    private const val STARTUP_WINDOW_PSIPHON_MS = 180_000L
    private const val STARTUP_WINDOW_CHAIN_MS = 270_000L

    private fun startTimeoutMs(mode: Mode): Long = when (mode) {
        Mode.AETHER -> START_TIMEOUT_AETHER_MS
        Mode.PSIPHON -> START_TIMEOUT_PSIPHON_MS
        Mode.CHAIN -> START_TIMEOUT_CHAIN_MS
    }

    fun startupWindowMs(mode: Mode): Long = when (mode) {
        Mode.AETHER -> STARTUP_WINDOW_AETHER_MS
        Mode.PSIPHON -> STARTUP_WINDOW_PSIPHON_MS
        Mode.CHAIN -> STARTUP_WINDOW_CHAIN_MS
    }

    private const val STOP_GRACE_MS = 3_000L
    private const val LOG_TAIL_LINES = 8

    /**
     * What proves the route: a tiny Cloudflare endpoint that answers HTTP
     * 200 with no body to speak of, fetched through the helper's own proxy.
     * Each attempt is bounded so a proxy that accepts and never answers
     * fails fast instead of hanging the start. It works through any of the
     * three modes: the endpoint is reachable from wherever the tunnel exits.
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

    /** The mode the running process is in, null when nothing runs. */
    @Volatile
    private var currentMode: Mode? = null

    @Volatile
    private var watchdogThread: Thread? = null

    @Volatile
    private var watchdogStop = false

    /** The private dir: identity files and the log. */
    fun dataDir(context: Context = app): File = File(context.filesDir, "aether").apply { mkdirs() }

    private fun logFile(context: Context = app): File = File(dataDir(context), "aether.log")

    /** True when the helper process is alive, whatever the port says. */
    fun isProcessAlive(): Boolean = process?.isAlive == true

    /** True when something answers on the given SOCKS5 port. */
    private fun isPortOpen(port: Int): Boolean = try {
        Socket().use { it.connect(InetSocketAddress(SOCKS_HOST, port), 500) }
        true
    } catch (_: Exception) {
        false
    }

    /** True when the helper is up and its own mode's proxy answers. */
    fun isConnected(): Boolean {
        val mode = currentMode ?: return false
        return isProcessAlive() && isPortOpen(portFor(mode))
    }

    /**
     * True when a real request crosses the helper's SOCKS5 proxy and comes
     * back HTTP 200: the route behind the proxy actually moves traffic. A
     * port that answers only proves the listener is up — the helper opens
     * it before any route exists, and a gateway can answer the handshake
     * and still drop every byte. The request is plain HTTP through the
     * tunnel, so no TLS is involved, and the host is resolved by the proxy
     * (remote DNS), not on the phone.
     */
    private fun isRouteWorking(port: Int): Boolean {
        return try {
            val proxy = Proxy(Proxy.Type.SOCKS, InetSocketAddress(SOCKS_HOST, port))
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

    /** Whether [profile] is the Psiphon profile (SOCKS at 127.0.0.1:1820). */
    fun isPsiphonProfile(profile: ProxyEntity): Boolean {
        if (profile.id > 0L && profile.id == DataStore.psiphonProfileId) return true
        val outbound = profile.outbound
        return outbound is Socks && outbound.server == SOCKS_HOST &&
            outbound.serverPort == PSIPHON_SOCKS_PORT && profile.name == PSIPHON_PROFILE_NAME
    }

    /** Whether [profile] is the chained profile (SOCKS at 127.0.0.1:1821). */
    fun isChainProfile(profile: ProxyEntity): Boolean {
        if (profile.id > 0L && profile.id == DataStore.chainProfileId) return true
        val outbound = profile.outbound
        return outbound is Socks && outbound.server == SOCKS_HOST &&
            outbound.serverPort == CHAIN_SOCKS_PORT && profile.name == CHAIN_PROFILE_NAME
    }

    /** The helper mode a profile needs, or null when it is not a helper profile. */
    fun modeForProfile(profile: ProxyEntity): Mode? = when {
        isAetherProfile(profile) -> Mode.AETHER
        isPsiphonProfile(profile) -> Mode.PSIPHON
        isChainProfile(profile) -> Mode.CHAIN
        else -> null
    }

    /** The native service path's hook: start the helper only for a helper start. */
    fun startIfNeeded(context: Context = app, profile: ProxyEntity) {
        val mode = modeForProfile(profile) ?: return
        start(context, mode)
    }

    /**
     * Starts the helper in [mode] unless it is already up in that mode.
     * Blocks (on the caller's IO thread) until a real request crosses the
     * proxy and comes back HTTP 200 or the start times out; throws with the
     * helper's last log lines when it dies or never passes traffic. A port
     * that answers is not enough: the helper opens its listener before any
     * route exists, and the core and the VPN come up the moment this returns,
     * so returning early would put the VPN up over a helper that is still
     * registering and scanning — and, before the app was excluded from its
     * own tunnel, its traffic looped back into itself. The process table is
     * only locked for the hand-over, never for the wait, so the UI's status
     * polls keep answering while a start scans.
     *
     * The invocation is hardened for strict networks (Aether's own guide
     * prescribes each of these for Iran): HTTP/2 over TCP instead of
     * QUIC/UDP, fragment the TLS ClientHello so SNI-based resets do not kill
     * the WARP API calls, the heaviest MASQUE obfuscation profile, and a
     * scan that only trusts a gateway after a real HTTP request crossed it —
     * the plain balanced scan trusted gateways on a handshake, which is how
     * a dead route looked "connected" while no traffic flowed. [freshScan]
     * also ignores the cached last-working gateway and scans from scratch;
     * without it the helper reconnects to the last gateway that worked.
     *
     * The country filters come from the store: [DataStore.aetherExitLoc]
     * (--exit-loc, the WARP exit country) and [DataStore.psiphonRegion]
     * (--psiphon-region, the Psiphon exit country). Empty means any.
     */
    fun start(context: Context = app, mode: Mode = Mode.AETHER, freshScan: Boolean = false): Map<String, Any?> {
        val proc: Process
        val startMs: Long
        // The port the user-visible proxy serves on (the one the profile
        // points at and the validation request crosses). In chain mode the
        // main listener (--bind) is still the plain warp SOCKS on 1819 and
        // the chain is served separately on 1821 (--psiphon-bind).
        val port = portFor(mode)
        val bindPort = if (mode == Mode.CHAIN) SOCKS_PORT else port
        synchronized(this) {
            if (isProcessAlive() && currentMode == mode && isPortOpen(port)) {
                startWatchdog()
                return statusMap(alreadyRunning = true)
            }
            stopLocked()
            // Something else is already answering on the helper's port: a
            // second helper cannot bind there, and waiting for traffic
            // through a stranger's proxy would only time out confusingly.
            if (isPortOpen(port) || (bindPort != port && isPortOpen(bindPort))) {
                error("Aether could not start: port $port is already in use by another app. Stop that app (or restart the phone) and try again.")
            }
            val binary = resolveBinary(context)
            val dir = dataDir(context)
            val log = logFile(context)
            val psiphonBin = resolvePsiphonBinary(context)
            if ((mode == Mode.PSIPHON || mode == Mode.CHAIN) && psiphonBin == null) {
                error("Psiphon is not installed for this device (no libpsiphon.so found)")
            }
            val entries = if (mode == Mode.PSIPHON || mode == Mode.CHAIN) ensureServerEntries(context) else null
            val exitLoc = DataStore.aetherExitLoc.trim().uppercase()
            val region = DataStore.psiphonRegion.trim().uppercase()
            val command = buildList {
                add(binary.absolutePath)
                when (mode) {
                    Mode.AETHER -> {
                        add("--masque")
                        add("--h2")
                        add("--fragment")
                        add("--noize"); add("gfw")
                        add("--scan"); add("ironclad")
                        add("--startup-secs"); add("90")
                        add("--validate-secs"); add("20")
                        if (freshScan) add("--no-quick-reconnect")
                        if (exitLoc.length == 2) { add("--exit-loc"); add(exitLoc) }
                    }
                    Mode.PSIPHON -> {
                        add("--psiphon-only")
                        if (region.length == 2) { add("--psiphon-region"); add(region) }
                    }
                    Mode.CHAIN -> {
                        add("--masque")
                        add("--h2")
                        add("--fragment")
                        add("--noize"); add("gfw")
                        add("--scan"); add("ironclad")
                        add("--startup-secs"); add("90")
                        add("--validate-secs"); add("20")
                        if (freshScan) add("--no-quick-reconnect")
                        if (exitLoc.length == 2) { add("--exit-loc"); add(exitLoc) }
                        add("--psiphon")
                        add("--psiphon-bind"); add("$SOCKS_HOST:$CHAIN_SOCKS_PORT")
                        if (region.length == 2) { add("--psiphon-region"); add(region) }
                    }
                }
                add("--bind"); add("$SOCKS_HOST:$bindPort")
                add("--config"); add(File(dir, "aether.toml").absolutePath)
                if (mode != Mode.PSIPHON) {
                    add("--masque-config"); add(File(dir, "aether-masque.toml").absolutePath)
                    add("--wg-config"); add(File(dir, "aether-wg.toml").absolutePath)
                }
            }
            Logs.i("aether: starting ${binary.absolutePath} in ${mode.key} mode")
            proc = ProcessBuilder(command)
                .directory(dir)
                .redirectOutput(ProcessBuilder.Redirect.to(log))
                .redirectErrorStream(true)
                .apply {
                    environment()["HOME"] = dir.absolutePath
                    environment()["AETHER_LOG_LEVEL"] = "info"
                    if (psiphonBin != null) {
                        environment()["AETHER_PSIPHON_BIN"] = psiphonBin.absolutePath
                    }
                    if (entries != null) {
                        environment()["AETHER_PSIPHON_SERVER_ENTRIES"] = entries.absolutePath
                    }
                }
                .start()
            process = proc
            currentMode = mode
            startMs = System.currentTimeMillis()
            startedAtMs = startMs
        }
        val deadline = startMs + startTimeoutMs(mode)
        while (System.currentTimeMillis() < deadline) {
            if (!proc.isAlive) {
                synchronized(this) {
                    if (process === proc) {
                        process = null
                        currentMode = null
                    }
                }
                val tail = lastLogLines(context)
                error("Aether stopped while starting" + tail.joinToString("\n", prefix = "\n"))
            }
            if (isRouteWorking(port)) {
                Logs.i("aether: traffic flows through the SOCKS5 proxy at $SOCKS_HOST:$port")
                startWatchdog()
                return statusMap(alreadyRunning = false)
            }
            Thread.sleep(VALIDATE_RETRY_MS)
        }
        stop()
        val tail = lastLogLines(context)
        error("Aether found no working route in time" + tail.joinToString("\n", prefix = "\n"))
    }

    /**
     * Stops the helper and starts it again in the same mode with a fresh
     * scan, ignoring any cached last-working gateway: the "new IP" choice.
     * The mode is the running one when there is one, otherwise the selected
     * profile's mode — a rescan is only offered while a helper runs, but a
     * stale call must not silently start the wrong helper.
     */
    fun rescan(context: Context = app): Map<String, Any?> {
        val mode = currentMode ?: selectedMode() ?: Mode.AETHER
        stop()
        return start(context, mode, freshScan = true)
    }

    /**
     * Stops the helper and starts it again in the same mode, letting it
     * reconnect to the last gateway that worked: the "previous IP" choice.
     * For Psiphon modes there is no last-gateway flag; the restart reuses
     * the Psiphon data directory, where the tunnel remembers the servers
     * that worked, which is the closest equivalent.
     */
    fun reconnect(context: Context = app): Map<String, Any?> {
        val mode = currentMode ?: selectedMode() ?: Mode.AETHER
        stop()
        return start(context, mode, freshScan = false)
    }

    /** The helper mode the selected profile needs, or null when it is not a helper profile. */
    private fun selectedMode(): Mode? {
        val profile = runCatching {
            SagerDatabase.proxyDao.getById(DataStore.selectedProxy)
        }.getOrNull() ?: return null
        return modeForProfile(profile)
    }

    /** Stops the helper when it runs; a no-op otherwise. */
    fun stop() {
        synchronized(this) { stopLocked() }
    }

    private fun stopLocked() {
        stopWatchdog()
        currentMode = null
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
     * restarted in the same mode. Runs on its own daemon thread and never
     * blocks a start or a stop: a stop kills the watchdog first, and the
     * watchdog checks the stop flag — and that it is still the current
     * watchdog thread — again before restarting or rescanning anything, so
     * a rescan that replaces the watchdog cannot leave two of them running.
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
                    val mode = currentMode
                    if (!isProcessAlive() || mode == null) {
                        Logs.w("aether: helper died; restarting it")
                        if (watchdogStop || watchdogThread !== self) break
                        runCatching { start(mode = mode ?: Mode.AETHER) }
                            .onFailure { Logs.w("aether: restart failed: ${it.message}") }
                        failures = 0
                    } else if (!isRouteWorking(portFor(mode))) {
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

    private fun statusMap(alreadyRunning: Boolean): Map<String, Any?> {
        val mode = currentMode
        return mapOf(
            "running" to isProcessAlive(),
            "connected" to isConnected(),
            "alreadyRunning" to alreadyRunning,
            "mode" to mode?.key,
            "host" to SOCKS_HOST,
            "port" to (mode?.let { portFor(it) } ?: SOCKS_PORT),
            "startupMs" to (mode?.let { startupWindowMs(it) } ?: STARTUP_WINDOW_AETHER_MS),
            "uptimeMs" to if (startedAtMs > 0L) System.currentTimeMillis() - startedAtMs else 0L,
            "log" to lastLogLines(),
        )
    }

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

    /**
     * The Psiphon console binary Aether shells out to, next to libaether.so
     * in the native library dir. The installer extracts it with the rest of
     * the libraries; if the execute bit did not survive, one chmod here
     * restores it — the app owns the file.
     */
    private fun resolvePsiphonBinary(context: Context): File? {
        val extracted = File(context.applicationInfo.nativeLibraryDir, "libpsiphon.so")
        if (!extracted.isFile) return null
        if (!extracted.canExecute()) {
            runCatching { extracted.setExecutable(true, true) }
        }
        return if (extracted.canExecute()) extracted else null
    }

    /**
     * The bootstrap server list the Psiphon client starts with, so a first
     * connection does not depend on downloading the remote list. The bundled
     * asset is the pinned public list, every entry verified against
     * Psiphon's own signature key at build time; Psiphon replaces it from
     * inside the tunnel once a connection is up.
     */
    private fun ensureServerEntries(context: Context): File? {
        return runCatching {
            val dest = File(dataDir(context), "psiphon_server_entries.txt")
            if (!dest.isFile || dest.length() == 0L) {
                context.assets.open("psiphon_server_entries.txt").use { input ->
                    dest.outputStream().use { input.copyTo(it) }
                }
            }
            dest.takeIf { it.isFile && it.length() > 0L }
        }.getOrNull()
    }
}
