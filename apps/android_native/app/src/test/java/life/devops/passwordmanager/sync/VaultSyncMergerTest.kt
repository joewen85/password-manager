package life.devops.passwordmanager.sync

import life.devops.passwordmanager.model.CredentialPayload
import life.devops.passwordmanager.model.VaultEntry
import life.devops.passwordmanager.model.VaultEntryType
import life.devops.passwordmanager.model.VaultPayload
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class VaultSyncMergerTest {
    @Test
    fun mergeKeepsAdditionsFromBothSides() {
        var counter = 0
        val merger = VaultSyncMerger(
            idGenerator = { "conflict-${counter++}" },
            conflictLabelBuilder = { _, _ -> "(conflict)" },
            conflictStrategy = SyncConflictStrategy.KEEP_BOTH,
        )
        val local = listOf(
            buildEntry(id = "a1", label = "Local", updatedBy = "A", version = mapOf("A" to 1))
        )
        val remote = listOf(
            buildEntry(id = "b1", label = "Remote", updatedBy = "B", version = mapOf("B" to 1))
        )

        val result = merger.merge(localEntries = local, remoteEntries = remote)

        assertEquals(2, result.entries.size)
        assertEquals(0, result.stats.conflicts)
    }

    @Test
    fun uuidIdsAreMatchedCaseInsensitivelyAcrossSwiftAndAndroid() {
        val merger = VaultSyncMerger()
        val local = buildEntry(
            id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            label = "Android original",
            updatedBy = "android",
            version = mapOf("android" to 1),
        )
        val remote = buildEntry(
            id = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            label = "macOS edit",
            updatedBy = "macos",
            version = mapOf("android" to 1, "macos" to 1),
        )

        val result = merger.merge(localEntries = listOf(local), remoteEntries = listOf(remote))

        assertEquals(1, result.entries.size)
        assertEquals("macOS edit", result.entries.single().label)
        assertEquals("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", result.entries.single().id)
        assertEquals(0, result.stats.conflicts)
    }

    @Test
    fun concurrentRenameConflictProducesConflictCopy() {
        var counter = 0
        val merger = VaultSyncMerger(
            idGenerator = { "conflict-${counter++}" },
            conflictLabelBuilder = { _, _ -> "(conflict)" },
            conflictStrategy = SyncConflictStrategy.LOCAL_WINS,
        )
        val local = listOf(
            buildEntry(
                id = "x1",
                label = "Name-A",
                updatedBy = "A",
                version = mapOf("A" to 2, "B" to 1),
            )
        )
        val remote = listOf(
            buildEntry(
                id = "x1",
                label = "Name-B",
                updatedBy = "B",
                version = mapOf("A" to 1, "B" to 2),
            )
        )

        val result = merger.merge(localEntries = local, remoteEntries = remote)

        assertEquals(1, result.stats.conflicts)
        assertEquals(2, result.entries.size)
        assertEquals(1, result.entries.count { it.id == "x1" })
        assertTrue(result.entries.any { it.label.contains("Name-B") })
    }

    @Test
    fun deleteVsUpdateKeepsTombstoneAndConflictCopy() {
        var counter = 0
        val merger = VaultSyncMerger(
            idGenerator = { "conflict-${counter++}" },
            conflictLabelBuilder = { _, _ -> "(conflict)" },
            conflictStrategy = SyncConflictStrategy.KEEP_BOTH,
        )
        val local = listOf(
            buildEntry(
                id = "d1",
                label = "Delete-Me",
                updatedBy = "A",
                version = mapOf("A" to 2, "B" to 1),
                isDeleted = true,
            )
        )
        val remote = listOf(
            buildEntry(
                id = "d1",
                label = "Delete-Me",
                updatedBy = "B",
                version = mapOf("A" to 1, "B" to 2),
            )
        )

        val result = merger.merge(localEntries = local, remoteEntries = remote)

        assertEquals(1, result.stats.conflicts)
        assertTrue(result.entries.any { it.id == "d1" && it.isDeleted })
        assertTrue(result.entries.any { it.id != "d1" && !it.isDeleted })
    }

    @Test
    fun bothDeleteKeepsSingleTombstone() {
        var counter = 0
        val merger = VaultSyncMerger(
            idGenerator = { "conflict-${counter++}" },
            conflictLabelBuilder = { _, _ -> "(conflict)" },
            conflictStrategy = SyncConflictStrategy.KEEP_BOTH,
        )
        val local = listOf(
            buildEntry(
                id = "z1",
                label = "Gone",
                updatedBy = "A",
                version = mapOf("A" to 2, "B" to 1),
                isDeleted = true,
            )
        )
        val remote = listOf(
            buildEntry(
                id = "z1",
                label = "Gone",
                updatedBy = "B",
                version = mapOf("A" to 1, "B" to 2),
                isDeleted = true,
            )
        )

        val result = merger.merge(localEntries = local, remoteEntries = remote)

        assertEquals(0, result.stats.conflicts)
        assertEquals(1, result.entries.size)
        assertTrue(result.entries.single().isDeleted)
    }

    @Test
    fun compareVersionClassifiesDominanceAndConcurrentUpdates() {
        assertEquals(
            VersionComparison.EQUAL,
            VaultSyncMerger.compareVersion(mapOf("A" to 1), mapOf("A" to 1)),
        )
        assertEquals(
            VersionComparison.LOCAL_DOMINATES,
            VaultSyncMerger.compareVersion(mapOf("A" to 2, "B" to 1), mapOf("A" to 1, "B" to 1)),
        )
        assertEquals(
            VersionComparison.REMOTE_DOMINATES,
            VaultSyncMerger.compareVersion(mapOf("A" to 1), mapOf("A" to 2)),
        )
        assertEquals(
            VersionComparison.CONCURRENT,
            VaultSyncMerger.compareVersion(mapOf("A" to 2, "B" to 1), mapOf("A" to 1, "B" to 2)),
        )
    }

    private fun buildEntry(
        id: String,
        label: String,
        updatedBy: String,
        version: Map<String, Int>,
        isDeleted: Boolean = false,
    ): VaultEntry {
        val now = Instant.parse("2026-02-12T10:00:00Z")
        return VaultEntry(
            id = id,
            label = label,
            type = VaultEntryType.CREDENTIAL,
            payload = VaultPayload.Credential(
                CredentialPayload(
                    username = "user-$id",
                    password = "password-$id",
                )
            ),
            createdAt = now,
            updatedAt = now.plusSeconds(300),
            version = version,
            updatedBy = updatedBy,
            isDeleted = isDeleted,
            deletedAt = if (isDeleted) now.plusSeconds(360) else null,
        )
    }
}
