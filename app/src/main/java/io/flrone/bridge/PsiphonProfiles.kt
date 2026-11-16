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
 * The Psiphon and chained profiles: ordinary stored SOCKS5 nodes, one per
 * helper mode — Psiphon on 127.0.0.1:1820 in its own "Psiphon" group, the
 * chain (warp -> psiphon) on 127.0.0.1:1821 in a "Chain" group. Like the
 * Aether profile, the config generator, the core, the routing and the
 * traffic stats all treat them like any other SOCKS node. The only thing
 * special about them is that the core's SOCKS outbound only answers while
 * [AetherRunner] keeps the helper process up in the matching mode, which
 * the start/stop hooks guarantee.
 *
 * The profile ids are remembered in the store so the runner can recognise
 * them even after the user renames a node; the shape checks in
 * [AetherRunner.isPsiphonProfile] / [AetherRunner.isChainProfile] cover a
 * store that lost an id.
 */
object PsiphonProfiles {

    /**
     * Creates the Psiphon group and profile when they do not exist yet and
     * returns their ids. Never creates a second copy: a stored id that still
     * points at a row wins, otherwise a matching node is adopted.
     */
    suspend fun ensurePsiphon(): Map<String, Any?> = withContext(Dispatchers.IO) {
        val groupId = ensureGroup(AetherRunner.PSIPHON_PROFILE_NAME)
        val stored = DataStore.psiphonProfileId
        val existing = if (stored > 0L) SagerDatabase.proxyDao.getById(stored) else null
        if (existing != null && AetherRunner.isPsiphonProfile(existing)) {
            return@withContext mapOf(
                "profileId" to existing.id, "groupId" to groupId, "created" to false,
            )
        }
        val adopted = SagerDatabase.proxyDao.getAll().firstOrNull { AetherRunner.isPsiphonProfile(it) }
        if (adopted != null) {
            DataStore.psiphonProfileId = adopted.id
            return@withContext mapOf(
                "profileId" to adopted.id, "groupId" to groupId, "created" to false,
            )
        }
        val socks = OutboundFactory.newByType("socks") as Socks
        socks.name = AetherRunner.PSIPHON_PROFILE_NAME
        socks.server = AetherRunner.SOCKS_HOST
        socks.serverPort = AetherRunner.PSIPHON_SOCKS_PORT
        socks.version = 5
        val entity = ProfileManager.addProfile(socks, groupId)
        DataStore.psiphonProfileId = entity.id
        BboxBridge.scheduleRefresh(immediate = true)
        mapOf("profileId" to entity.id, "groupId" to groupId, "created" to true)
    }

    /**
     * Creates the Chain group and chained profile when they do not exist yet
     * and returns their ids. Never creates a second copy, same as [ensurePsiphon].
     */
    suspend fun ensureChain(): Map<String, Any?> = withContext(Dispatchers.IO) {
        val groupId = ensureGroup(AetherRunner.CHAIN_GROUP_NAME)
        val stored = DataStore.chainProfileId
        val existing = if (stored > 0L) SagerDatabase.proxyDao.getById(stored) else null
        if (existing != null && AetherRunner.isChainProfile(existing)) {
            return@withContext mapOf(
                "profileId" to existing.id, "groupId" to groupId, "created" to false,
            )
        }
        val adopted = SagerDatabase.proxyDao.getAll().firstOrNull { AetherRunner.isChainProfile(it) }
        if (adopted != null) {
            DataStore.chainProfileId = adopted.id
            return@withContext mapOf(
                "profileId" to adopted.id, "groupId" to groupId, "created" to false,
            )
        }
        val socks = OutboundFactory.newByType("socks") as Socks
        socks.name = AetherRunner.CHAIN_PROFILE_NAME
        socks.server = AetherRunner.SOCKS_HOST
        socks.serverPort = AetherRunner.CHAIN_SOCKS_PORT
        socks.version = 5
        val entity = ProfileManager.addProfile(socks, groupId)
        DataStore.chainProfileId = entity.id
        BboxBridge.scheduleRefresh(immediate = true)
        mapOf("profileId" to entity.id, "groupId" to groupId, "created" to true)
    }

    /** True when the Psiphon profile is the one the service would start. */
    fun isPsiphonSelected(): Boolean {
        val id = DataStore.psiphonProfileId
        if (id <= 0L) return false
        if (DataStore.selectedProxy == id) return true
        val selected = SagerDatabase.proxyDao.getById(DataStore.selectedProxy) ?: return false
        return AetherRunner.isPsiphonProfile(selected)
    }

    /** True when the chained profile is the one the service would start. */
    fun isChainSelected(): Boolean {
        val id = DataStore.chainProfileId
        if (id <= 0L) return false
        if (DataStore.selectedProxy == id) return true
        val selected = SagerDatabase.proxyDao.getById(DataStore.selectedProxy) ?: return false
        return AetherRunner.isChainProfile(selected)
    }

    private suspend fun ensureGroup(name: String): Long {
        val groups = GroupRepo.rawGroups()
        groups.firstOrNull { it.name == name }?.let { return it.id }
        val group = ProxyGroup().apply { this.name = name }
        return GroupRepo.add(group).id
    }
}
