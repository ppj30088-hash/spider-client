package io.flrone.bridge

import android.content.Context
import android.os.Build
import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.ProxyEntity
import io.nekohasekai.sagernet.ktx.Logs
import io.nekohasekai.sagernet.ktx.app
import io.nekohasekai.sagernet.outbound.types.Socks
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket
import java.util.zip.ZipFile

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
 * files are deflated at install time). When that copy is missing — an install
 * that kept the libraries inside the APK — the same entry is pulled out of the
 * APK zip into the app's private dir instead.
 */
object AetherRunner {

    /** The SOCKS5 listener Aether opens (its default; passed explicitly too). */
    const val SOCKS_HOST = "127.0.0.1"
    const val SOCKS_PORT = 1819

    /** Aether's own name for the profile it routes through, also the group name. */
    const val PROFILE_NAME = "Aether"

    /**
     * How long a start may take: the helper loads its (bundled) identity
     * and then scans for a route, which on a slow network is tens of
     * seconds. The UI shows "starting" for this whole window, so it must
     * be generous rather than exact.
     */
    private const val START_TIMEOUT_MS = 120_000L
    private const val POLL_MS = 500L
    private const val STOP_GRACE_MS = 3_000L
    private const val LOG_TAIL_LINES = 8

    @Volatile
    private var process: Process? = null

    @Volatile
    private var startedAtMs: Long = 0L

    /** The private dir: identity files, the log, and the fallback binary copy. */
    fun dataDir(context: Context = app): File = File(context.filesDir, "aether").apply { mkdirs() }

    private fun logFile(context: Context = app): File = File(dataDir(context), "aether.log")

    /**
     * Installs the MASQUE identity the build registered (see the
     * "Pre-register Aether identity" step in .github/actions/android-build):
     * a free WARP account registered where the API answers, bundled in the
     * APK at assets/aether/aether-masque.toml. The phone's network blocks
     * the registration API, so without this the helper can never get an
     * account and no route is ever found; with it, the helper loads the
     * saved identity and never calls the API at all. Only installed when
     * the phone has no identity of its own yet — an identity the phone
     * registered itself is never overwritten. A build without the bundled
     * file (local dev builds) simply falls back to the helper registering
     * its own account.
     */
    private fun ensureBundledIdentity(context: Context) {
        val dir = dataDir(context)
        val target = File(dir, "aether-masque.toml")
        if (target.isFile) return
        try {
            context.assets.open("aether/aether-masque.toml").use { input ->
                target.outputStream().use { input.copyTo(it) }
            }
            target.setReadable(true, true)
            target.setWritable(true, true)
            target.setExecutable(false, false)
            Logs.i("aether: installed the bundled masque identity")
        } catch (_: Exception) {
            Logs.i("aether: no bundled masque identity; the helper will register one")
        }
    }

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
     * thread) until the SOCKS5 port answers or the start times out; throws with
     * the helper's last log lines when it dies or never comes up. The process
     * table is only locked for the hand-over, never for the wait, so the UI's
     * status polls keep answering while a start scans.
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
            if (isConnected()) return statusMap(alreadyRunning = true)
            stopLocked()
            val binary = resolveBinary(context)
            val dir = dataDir(context)
            ensureBundledIdentity(context)
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
            if (isPortOpen()) {
                Logs.i("aether: SOCKS5 proxy is up at $SOCKS_HOST:$SOCKS_PORT")
                return statusMap(alreadyRunning = false)
            }
            Thread.sleep(POLL_MS)
        }
        stop()
        error("Aether did not open its local proxy in time")
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
     * The executable helper. First the extracted copy in the native library
     * dir; otherwise the `lib/<abi>/libaether.so` entry is pulled out of the
     * APK zip into the private dir (and marked executable).
     */
    private fun resolveBinary(context: Context): File {
        val extracted = File(context.applicationInfo.nativeLibraryDir, "libaether.so")
        if (extracted.isFile && extracted.canExecute()) return extracted
        val dir = dataDir(context)
        val fallback = File(dir, "libaether.so")
        if (fallback.isFile && fallback.canExecute()) return fallback
        val abis = Build.SUPPORTED_ABIS.toList()
        ZipFile(File(context.applicationInfo.sourceDir)).use { zip ->
            for (abi in abis) {
                val entry = zip.getEntry("lib/$abi/libaether.so") ?: continue
                zip.getInputStream(entry).use { input -> fallback.outputStream().use { input.copyTo(it) } }
                fallback.setExecutable(true, true)
                if (fallback.canExecute()) return fallback
            }
        }
        error("Aether is not installed for this device (no libaether.so found)")
    }
}
