package io.flrone.bridge

import io.nekohasekai.sagernet.database.DataStore
import io.nekohasekai.sagernet.database.GroupRepo
import io.nekohasekai.sagernet.database.ProfileManager
import io.nekohasekai.sagernet.database.ProxyGroup
import io.nekohasekai.sagernet.database.SagerDatabase
import io.nekohasekai.sagernet.outbound.OutboundFactory
import io.nekohasekai.sagernet.outbound.types.Socks
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The Aether profile: one SOCKS5 node at 127.0.0.1:1819 in its own "Aether"
 * group. It is an ordinary stored profile — the config generator, the
 * Xray-first core, the routing and the traffic stats all treat it like any
 * other SOCKS node. The only thing special about it is that the core's
 * SOCKS outbound only answers while [AetherRunner] keeps the helper process
 * up, which the start/stop hooks guarantee.
 *
 * The profile id is remembered in the store so the runner can recognise it
 * even after the user renames the node; the shape check in
 * [AetherRunner.isAetherProfile] covers a store that lost the id.
 */
object AetherProfiles {

    /**
     * Creates the Aether group and profile when they do not exist yet and
     * returns their ids. Never creates a second copy: a stored id that still
     * points at a row wins, otherwise a matching node is adopted.
     */
    suspend fun ensure(): Map<String, Any?> = withContext(Dispatchers.IO) {
        val groupId = ensureGroup()
        val stored = DataStore.aetherProfileId
        val existing = if (stored > 0L) SagerDatabase.proxyDao.getById(stored) else null
        if (existing != null && AetherRunner.isAetherProfile(existing)) {
            return@withContext mapOf(
                "profileId" to existing.id, "groupId" to groupId, "created" to false,
            )
        }
        val adopted = SagerDatabase.proxyDao.getAll().firstOrNull { AetherRunner.isAetherProfile(it) }
        if (adopted != null) {
            DataStore.aetherProfileId = adopted.id
            return@withContext mapOf(
                "profileId" to adopted.id, "groupId" to groupId, "created" to false,
            )
        }
        val socks = OutboundFactory.newByType("socks") as Socks
        socks.name = AetherRunner.PROFILE_NAME
        socks.server = AetherRunner.SOCKS_HOST
        socks.serverPort = AetherRunner.SOCKS_PORT
        socks.version = 5
        val entity = ProfileManager.addProfile(socks, groupId)
        DataStore.aetherProfileId = entity.id
        BboxBridge.scheduleRefresh(immediate = true)
        mapOf("profileId" to entity.id, "groupId" to groupId, "created" to true)
    }

    /** True when the Aether profile is the one the service would start. */
    fun isSelected(): Boolean {
        val id = DataStore.aetherProfileId
        if (id <= 0L) return false
        if (DataStore.selectedProxy == id) return true
        val selected = SagerDatabase.proxyDao.getById(DataStore.selectedProxy) ?: return false
        return AetherRunner.isAetherProfile(selected)
    }

    private suspend fun ensureGroup(): Long {
        val groups = GroupRepo.rawGroups()
        groups.firstOrNull { it.name == AetherRunner.PROFILE_NAME }?.let { return it.id }
        val group = ProxyGroup().apply { name = AetherRunner.PROFILE_NAME }
        return GroupRepo.add(group).id
    }
}
