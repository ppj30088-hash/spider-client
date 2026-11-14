package io.nekohasekai.sagernet.outbound.common

import io.nekohasekai.sagernet.outbound.BuildContext
import io.nekohasekai.sagernet.outbound.json.JsonObject
import io.nekohasekai.sagernet.outbound.json.JsonValues
import io.nekohasekai.sagernet.outbound.json.jsonObjectOf
import io.nekohasekai.sagernet.outbound.link.Hosts

/**
 * The sing-box TLS + transport of a VMess / Trojan profile, as the Xray stream it runs on, and the
 * multiplex as the Xray mux. VMess, Trojan and Shadowsocks keep their sing-box fields as the stored
 * shape (the editors, links and subscriptions all read and write those), and the Xray shape is
 * derived fresh at build time, so a stored row needs no migration when its core changes.
 *
 * What Xray cannot carry stays on sing-box instead ([Tls.supportsXrayStream] and each type's own
 * [io.nekohasekai.sagernet.outbound.Outbound.isXray]): Xray v26.7+ removed `allowInsecure` (a config
 * carrying it fails the whole core load), runs REALITY only over raw, xhttp and gRPC, and the
 * sing-box-only TLS fragment and TLS tricks have no Xray counterpart. The checks here are pure
 * field reads, so they are safe wherever [io.nekohasekai.sagernet.outbound.Outbound.isXray] is
 * asked, including import validation.
 */

/** StreamConfig.Build: the networks Xray runs REALITY over. Keep in sync with CoreSupport. */
val xrayRealityNetworks = setOf("raw", "tcp", "xhttp", "splithttp", "grpc")

/** The Shadowsocks methods Xray still builds (AEAD and 2022-blake3); the stream ciphers and `none` are gone. */
val xrayShadowsocksMethods = setOf(
    "aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305", "xchacha20-ietf-poly1305",
    "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305",
)

/** The transport security of this TLS block as Xray names it: reality, tls, or none. */
fun Tls.xraySecurity(): String = when {
    reality.enabled || reality.public_key.isNotEmpty() -> "reality"
    enabled -> "tls"
    else -> "none"
}

/**
 * This TLS block's transport as an Xray network. Plain HTTP is the raw TCP header; TLS HTTP has no
 * Xray network left (Xray removed the H2 network in 2024-12, so `supportsXrayStream` keeps those
 * profiles on sing-box and this value is never emitted for them), and the same holds for QUIC
 * (removed 2024-09). The names are kept here so a converted stream still reads true to the
 * profile it came from.
 */
fun Tls.xrayNetwork(transport: Transport): String = when (transport.type) {
    "", "tcp" -> "raw"
    "ws" -> "ws"
    "httpupgrade" -> "httpupgrade"
    "grpc" -> "grpc"
    "http" -> if (xraySecurity() == "none") "raw" else "h2"
    "quic" -> "quic"
    "xhttp" -> "xhttp"
    else -> "raw"
}

/**
 * Whether this TLS block and transport can run on Xray at all. False when the profile needs
 * something Xray v26 no longer carries or never had: skipping certificate verification
 * (`allowInsecure` was removed and fails the whole config load), the sing-box-only TLS fragment
 * or TLS tricks turned on for the profile, REALITY over a network Xray refuses it on, or a
 * transport Xray removed: QUIC (2024-09) and TLS over HTTP, whose H2 network went in 2024-12
 * (plain HTTP still runs, as the raw TCP header). Those profiles stay on sing-box.
 */
fun Tls.supportsXrayStream(transport: Transport): Boolean {
    if (insecure) return false
    if (fragment || tls_tricks) return false
    if (transport.type == "quic") return false
    if (transport.type == "http" && xraySecurity() != "none") return false
    if (xraySecurity() == "reality" && xrayNetwork(transport) !in xrayRealityNetworks) return false
    return true
}

/** A uTLS fingerprint Xray knows, else "" so Xray (or the global fallback) picks its own. */
private fun xrayFingerprintOrEmpty(fingerprint: String, reality: Boolean): String {
    val value = fingerprint.trim()
    return if (value.isEmpty() || !XrayChecks.isXrayFingerprint(value, reality)) "" else value
}

/** The raw TCP HTTP header (sing-box's plaintext `http` transport, or an explicit raw header). */
private fun rawHttpHeaderSettings(transport: Transport): JsonObject {
    val request = JsonObject()
    val paths = transport.path.split(',').map { it.trim() }.filter { it.isNotEmpty() }
    if (paths.isNotEmpty()) request["path"] = JsonValues.stringArray(paths)
    val hosts = transport.host.split(',').map { Hosts.toAceHost(it.trim()) }.filter { it.isNotEmpty() }
    if (hosts.isNotEmpty()) request["headers"] = jsonObjectOf("Host" to JsonValues.stringArray(hosts))
    val header = jsonObjectOf("type" to "http")
    if (request.isNotEmpty()) header["request"] = request
    return jsonObjectOf("header" to header)
}

/** A WebSocket / HTTPUpgrade path with its `?ed=` early-data size split off, and the size itself. */
private fun splitEarlyData(path: String, maxEarlyData: Int): Pair<String, Int> {
    if (!path.contains("?ed=")) return path to maxEarlyData
    val parts = path.split("?ed=")
    return parts[0] to (parts[1].toIntOrNull() ?: maxEarlyData)
}

/** The transport headers without a Host pair, which travels in the host field instead. */
private fun headersWithoutHost(headers: List<String>): MutableList<String> {
    val out = ArrayList<String>()
    var i = 0
    while (i + 1 < headers.size) {
        if (!headers[i].trim().equals("host", ignoreCase = true)) {
            out.add(headers[i])
            out.add(headers[i + 1])
        }
        i += 2
    }
    return out
}

/**
 * This TLS block and transport as an Xray stream. Values Xray has no field for are left out rather
 * than guessed: gRPC keeps only the service name, TLS keeps no client certificate, version range
 * or curve list, and a pinned SPKI key has no Xray counterpart. The global uTLS fingerprint
 * fallback is applied by [XrayStreamSetting.build]. Only ever built for a profile
 * [Tls.supportsXrayStream] accepts, so no removed network (`h2`, `quic`) reaches a config.
 */
fun Tls.toXrayStream(transport: Transport): XrayStreamSetting {
    val stream = XrayStreamSetting()
    stream.network = xrayNetwork(transport)
    stream.security = xraySecurity()
    if (stream.network == "raw" && (transport.type == "http" || transport.rawHttpHeader)) {
        stream.rawSettings = rawHttpHeaderSettings(transport)
    }
    when (stream.network) {
        "ws" -> {
            val (path, ed) = splitEarlyData(transport.path, transport.max_early_data)
            stream.ws.path = path
            stream.ws.host = transport.host
            stream.ws.ed = ed
            stream.ws.headers = headersWithoutHost(transport.headers)
        }

        "httpupgrade" -> {
            val (path, ed) = splitEarlyData(transport.path, transport.max_early_data)
            stream.httpupgrade.path = path
            stream.httpupgrade.host = transport.host
            stream.httpupgrade.ed = ed
            stream.httpupgrade.headers = headersWithoutHost(transport.headers)
        }

        "grpc" -> {
            stream.grpc.serviceName = transport.service_name
        }

        "xhttp" -> {
            stream.xhttp.host = transport.host
            stream.xhttp.path = transport.path
        }
    }
    when (stream.security) {
        "tls" -> {
            stream.tls.serverName = server_name
            stream.tls.alpn = ArrayList(alpn)
            stream.tls.fingerprint = xrayFingerprintOrEmpty(utls.fingerPrint, false)
            if (cipher_suites.isNotEmpty()) stream.tls.cipherSuites = cipher_suites.joinToString(":")
            if (certificate_sha256.isNotEmpty()) stream.tls.pinnedPeerCertSha256 = certificate_sha256.joinToString(",")
            if (ech.enabled) stream.tls.echConfigList = ech.configBase64().ifEmpty { ech.queryTarget() }
        }

        "reality" -> {
            stream.reality.serverName = server_name
            stream.reality.fingerprint = xrayFingerprintOrEmpty(utls.fingerPrint, true)
            stream.reality.password = reality.public_key
            stream.reality.shortId = reality.short_id
        }
    }
    return stream
}

/**
 * This multiplex as an Xray mux: Keep Default stays Keep Default, Off stays Off, On carries the
 * pool over (max streams per connection, else the connection cap with its minimum). The sing-box
 * protocol, padding and brutal settings have no Xray counterpart and are left out.
 */
fun Multiplex.toXrayMultiplex(): XrayMultiplex {
    val xmux = XrayMultiplex()
    if (unspecified) return xmux
    xmux.useDefault = false
    xmux.enabled = enabled
    if (!enabled) return xmux
    if (max_streams > 0) {
        xmux.concurrency = max_streams
    } else if (max_connections > 0) {
        xmux.maxConnections = max_connections
        if (min_streams > 0) xmux.concurrency = min_streams
    }
    return xmux
}

/** The Xray mux object for this multiplex, mirroring [XrayVless.buildXray]'s use of the global default. */
fun Multiplex.buildXrayMux(ctx: BuildContext): JsonObject =
    toXrayMultiplex().buildMux(ctx, ctx.xrayMuxDefaultOn)
