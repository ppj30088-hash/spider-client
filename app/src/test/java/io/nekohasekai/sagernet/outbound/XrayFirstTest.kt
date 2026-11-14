package io.nekohasekai.sagernet.outbound

import io.nekohasekai.sagernet.outbound.import.ProfileImport
import io.nekohasekai.sagernet.outbound.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Xray-first: VMess, Trojan and Shadowsocks profiles run on the Xray core, and the Xray outbound
 * JSON they build carries the profile, unless Xray v26 cannot carry it — then the profile stays on
 * sing-box. Only pure paths are exercised here: validation localises its messages, which plain
 * JVM tests cannot do.
 */
class XrayFirstTest {

    private val uuid = "550e8400-e29b-41d4-a716-446655440000"
    private val pbk = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    private fun parseLink(link: String) = OutboundFactory.parseLink(link)!!

    private fun xray(link: String): JsonObject = parseLink(link).buildXray(BuildContext.DEFAULT).json

    private fun stream(link: String): JsonObject = xray(link).obj("streamSettings")

    @Test
    fun `vmess tls over tcp runs on xray with the converted stream`() {
        val link = "vmess://$uuid@example.com:443?security=tls&sni=example.com#VMess-TLS"
        val outbound = parseLink(link)

        assertTrue(outbound.isXray())
        val built = xray(link)
        assertEquals("vmess", built.string("protocol"))
        val settings = built.obj("settings")
        assertEquals("example.com", settings.string("address"))
        assertEquals(443, settings.int("port"))
        assertEquals(uuid, settings.string("id"))
        assertEquals("auto", settings.string("security"))
        val stream = stream(link)
        assertEquals("raw", stream.string("network"))
        assertEquals("tls", stream.string("security"))
        assertEquals("example.com", stream.obj("tlsSettings").string("serverName"))
    }

    @Test
    fun `vmess plain http runs on xray as the raw tcp header`() {
        val link = "vmess://$uuid@example.com:80?type=http&host=example.com&path=%2Fplain#VMess-HTTP"
        val outbound = parseLink(link)

        assertTrue(outbound.isXray())
        assertEquals("raw", stream(link).string("network"))
        assertEquals("http", stream(link).obj("rawSettings").obj("header").string("type"))
    }

    @Test
    fun `vmess reality over ws stays on sing-box`() {
        val link = "vmess://$uuid@example.com:443?security=reality&sni=example.com&pbk=$pbk&type=ws&path=%2Fpath#VMess-WS-Reality"
        assertFalse(parseLink(link).isXray())
    }

    @Test
    fun `vmess with alterId stays on sing-box`() {
        val link = "vmess://$uuid@example.com:443?security=tls&sni=example.com&alterId=64#VMess-AlterId"
        assertFalse(parseLink(link).isXray())
    }

    @Test
    fun `vmess with no body security stays on sing-box`() {
        val link = "vmess://$uuid@example.com:443?encryption=none#VMess-None"
        assertFalse(parseLink(link).isXray())
    }

    @Test
    fun `vmess that skips certificate verification stays on sing-box`() {
        val link = "vmess://$uuid@example.com:443?security=tls&allowInsecure=1#VMess-Insecure"
        assertFalse(parseLink(link).isXray())
    }

    @Test
    fun `vmess with tls fragment stays on sing-box`() {
        val link = "vmess://$uuid@example.com:443?security=tls&tls_fragment=true#VMess-Fragment"
        assertFalse(parseLink(link).isXray())
    }

    @Test
    fun `vmess over h2 stays on sing-box because xray removed that network`() {
        val link = "vmess://$uuid@example.com:443?security=tls&sni=example.com&type=http&host=example.com&path=%2Fh2#VMess-H2"
        assertFalse(parseLink(link).isXray())
    }

    @Test
    fun `vmess over quic stays on sing-box because xray removed that network`() {
        val link = "vmess://$uuid@example.com:443?security=tls&sni=example.com&type=quic#VMess-QUIC"
        assertFalse(parseLink(link).isXray())
    }

    @Test
    fun `trojan with tls runs on xray with the flat settings`() {
        val link = "trojan://password@example.com:443?security=tls&sni=example.com#Trojan-TLS"
        val outbound = parseLink(link)

        assertTrue(outbound.isXray())
        val built = xray(link)
        assertEquals("trojan", built.string("protocol"))
        val settings = built.obj("settings")
        assertEquals("example.com", settings.string("address"))
        assertEquals(443, settings.int("port"))
        assertEquals("password", settings.string("password"))
        assertEquals("tls", stream(link).string("security"))
    }

    @Test
    fun `trojan without tls stays on sing-box`() {
        // security=none keeps the profile TLS-less (so it stays on sing-box) without
        // tripping the no-TLS warning, whose localised message plain JVM tests cannot
        // build (it reads the app, which is never started here).
        val link = "trojan://password@example.com:443?security=none#Trojan-Plain"
        assertFalse(parseLink(link).isXray())
    }

    @Test
    fun `trojan reality over ws stays on sing-box`() {
        val link = "trojan://password@example.com:443?security=reality&sni=example.com&pbk=$pbk&type=ws#Trojan-WS-Reality"
        assertFalse(parseLink(link).isXray())
    }

    @Test
    fun `shadowsocks aes-256-gcm runs on xray`() {
        val link = "ss://YWVzLTI1Ni1nY206cGFzcw@example.com:8388#SS"
        val outbound = parseLink(link)

        assertTrue(outbound.isXray())
        val built = xray(link)
        assertEquals("shadowsocks", built.string("protocol"))
        val server = built.obj("settings").array("servers")[0] as JsonObject
        assertEquals("example.com", server.string("address"))
        assertEquals(8388, server.int("port"))
        assertEquals("aes-256-gcm", server.string("method"))
        assertEquals("pass", server.string("password"))
    }

    @Test
    fun `shadowsocks with a plugin stays on sing-box`() {
        val link = "ss://YWVzLTI1Ni1nY206cGFzcw@example.com:8388?plugin=obfs-local%3Bobfs%3Dhttp#SS-Plugin"
        assertFalse(parseLink(link).isXray())
    }

    @Test
    fun `shadowsocks with a stream cipher stays on sing-box`() {
        val link = "ss://cmM0LW1kNTpwYXNz@example.com:8388#SS-RC4"
        assertFalse(parseLink(link).isXray())
    }

    @Test
    fun `shadowsocks with no method stays on sing-box`() {
        val link = "ss://bm9uZTpwYXNz@example.com:8388#SS-None"
        assertFalse(parseLink(link).isXray())
    }

    @Test
    fun `shadowsocks 2022 method with several keys stays on sing-box`() {
        val link = "ss://MjAyMi1ibGFrZTMtYWVzLTEyOC1nY206YUdWc2JHODphR1ZzYkc4@example.com:8388#SS-2022-Multi"
        assertFalse(parseLink(link).isXray())
    }

    @Test
    fun `plain vless stays on sing-box and tls vless becomes xray`() {
        val plain = parseLink("vless://$uuid@example.com:443#Plain")
        assertEquals("vless", plain.type)
        assertFalse(plain.isXray())

        val tls = parseLink("vless://$uuid@example.com:443?security=tls&sni=example.com#TLS")
        assertEquals("xrayvless", tls.type)
        assertTrue(tls.isXray())
    }

    @Test
    fun `clash vmess over ws with tls runs on xray and clash trojan does too`() {
        val clash = """
            proxies:
              - name: Clash-VMess
                type: vmess
                server: example.com
                port: 443
                uuid: $uuid
                alterId: 0
                cipher: auto
                tls: true
                servername: example.com
                network: ws
                ws-opts:
                  path: /path
              - name: Clash-Trojan
                type: trojan
                server: example.com
                port: 443
                password: password
                tls: true
                sni: example.com
        """.trimIndent()
        val result = ProfileImport.parse(clash, ctx = BuildContext.DEFAULT)

        assertEquals(listOf("Clash-VMess", "Clash-Trojan"), result.outbounds.map { it.name })
        assertTrue(result.outbounds.all { it.isXray() })
        assertTrue(result.messages.none { it.startsWith("[error]") })
    }
}
