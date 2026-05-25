package com.example.passwordmanagernative.sync

import com.example.passwordmanagernative.model.CredentialPayload
import com.example.passwordmanagernative.model.SecuritySettings
import com.example.passwordmanagernative.model.VaultEntry
import com.example.passwordmanagernative.model.VaultEntryType
import com.example.passwordmanagernative.model.VaultPayload
import com.example.passwordmanagernative.model.VaultSnapshot
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class VaultSyncEngineTest {
    @Test
    fun missingRemoteUploadsLocalPayloadAndRecordsStatus() {
        val now = Instant.parse("2027-01-15T08:00:00Z")
        val engine = VaultSyncEngine(clock = { now })
        val client = FakeSyncClient(
            downloads = ArrayDeque(listOf(RemoteSyncResult(payload = null, statusCode = 404))),
            uploadStatusCodes = ArrayDeque(listOf(201)),
        )
        val snapshot = makeSnapshot(
            entries = listOf(makeEntry(id = "local-1", label = "Local", device = "android"))
        )
        val settings = SyncSettings.defaults(deviceId = "android-device")

        val result = engine.synchronize(localSnapshot = snapshot, settings = settings, client = client)

        assertTrue(result.uploaded)
        assertFalse(result.appliedRemote)
        assertEquals(0, result.settings.lastSyncRevision)
        assertEquals("success", result.settings.lastSyncStatus)
        assertEquals(1, client.uploadedPayloads.size)
        val uploaded = engine.decodePayload(client.uploadedPayloads.single())!!
        assertEquals("android-device", uploaded.deviceId)
        assertEquals("Local", uploaded.snapshot.entries.single().label)
    }

    @Test
    fun remoteDominantPayloadAppliesWithoutUpload() {
        val now = Instant.parse("2027-01-15T08:00:00Z")
        val engine = VaultSyncEngine(clock = { now })
        val settings = SyncSettings.defaults(deviceId = "android-device").copy(lastSyncRevision = 1)
        val local = makeSnapshot(
            entries = listOf(makeEntry(id = "shared", label = "Old", device = "android", version = mapOf("android" to 1)))
        )
        val remote = makeSnapshot(
            entries = listOf(makeEntry(id = "shared", label = "Remote", device = "remote", version = mapOf("android" to 1, "remote" to 1)))
        )
        val remotePayload = engine.encodePayload(
            VaultSyncPayload(
                exportedAt = now,
                deviceId = "remote-device",
                revision = 2,
                snapshot = remote,
            )
        )
        val client = FakeSyncClient(
            downloads = ArrayDeque(listOf(RemoteSyncResult(payload = remotePayload, statusCode = 200)))
        )

        val result = engine.synchronize(localSnapshot = local, settings = settings, client = client)

        assertFalse(result.uploaded)
        assertTrue(result.appliedRemote)
        assertEquals("Remote", result.snapshot.entries.single().label)
        assertEquals(2, result.settings.lastSyncRevision)
        assertTrue(client.uploadedPayloads.isEmpty())
    }

    @Test
    fun concurrentPayloadMergesAndUploadsNextRevision() {
        val now = Instant.parse("2027-01-15T08:00:00Z")
        val engine = VaultSyncEngine(clock = { now }, idGenerator = { "conflict-id" })
        val settings = SyncSettings.defaults(deviceId = "android-device").copy(
            lastSyncRevision = 2,
            conflictStrategy = SyncSettingsConflictStrategy.LOCAL_WINS,
        )
        val local = makeSnapshot(
            categories = listOf("Local"),
            tags = listOf("android"),
            entries = listOf(
                makeEntry(
                    id = "shared",
                    label = "Local",
                    category = "Local",
                    tags = listOf("android"),
                    device = "android",
                    version = mapOf("android" to 2, "remote" to 1),
                )
            )
        )
        val remote = makeSnapshot(
            categories = listOf("Remote"),
            tags = listOf("remote"),
            entries = listOf(
                makeEntry(
                    id = "shared",
                    label = "Remote",
                    category = "Remote",
                    tags = listOf("remote"),
                    device = "remote",
                    version = mapOf("android" to 1, "remote" to 2),
                )
            )
        )
        val remotePayload = engine.encodePayload(
            VaultSyncPayload(
                exportedAt = now,
                deviceId = "remote-device",
                revision = 4,
                snapshot = remote,
            )
        )
        val client = FakeSyncClient(
            downloads = ArrayDeque(listOf(RemoteSyncResult(payload = remotePayload, statusCode = 200))),
            uploadStatusCodes = ArrayDeque(listOf(200)),
        )

        val result = engine.synchronize(localSnapshot = local, settings = settings, client = client)

        assertTrue(result.uploaded)
        assertTrue(result.appliedRemote)
        assertEquals(5, result.settings.lastSyncRevision)
        assertEquals(1, result.stats.conflicts)
        assertEquals(setOf("Local", "Remote"), result.snapshot.categories.toSet())
        assertEquals(setOf("android", "remote"), result.snapshot.tags.toSet())
        assertEquals(2, result.snapshot.entries.size)
        val uploaded = engine.decodePayload(client.uploadedPayloads.single())!!
        assertEquals(5, uploaded.revision)
        assertTrue(uploaded.snapshot.entries.any { it.id == "conflict-id" })
    }
}

private class FakeSyncClient(
    private val downloads: ArrayDeque<RemoteSyncResult>,
    private val uploadStatusCodes: ArrayDeque<Int> = ArrayDeque(),
) : RemoteSyncClient {
    val uploadedPayloads = mutableListOf<String>()

    override fun download(): RemoteSyncResult =
        if (downloads.isEmpty()) RemoteSyncResult(payload = null, statusCode = 404) else downloads.removeFirst()

    override fun upload(payload: String): RemoteSyncResult {
        uploadedPayloads += payload
        val statusCode = if (uploadStatusCodes.isEmpty()) 200 else uploadStatusCodes.removeFirst()
        return RemoteSyncResult(payload = null, statusCode = statusCode)
    }
}

private fun makeSnapshot(
    categories: List<String> = emptyList(),
    tags: List<String> = emptyList(),
    entries: List<VaultEntry>,
    updatedAt: Instant = Instant.parse("2026-01-01T00:00:00Z"),
): VaultSnapshot =
    VaultSnapshot(
        entries = entries,
        categories = categories,
        tags = tags,
        security = SecuritySettings(requireTotp = true, totpSecret = "JBSWY3DPEHPK3PXP"),
        syncStatus = "Idle",
        backupStatus = "No backup has run",
        updatedAt = updatedAt,
    )

private fun makeEntry(
    id: String,
    label: String,
    category: String = "",
    tags: List<String> = emptyList(),
    device: String,
    version: Map<String, Int> = emptyMap(),
): VaultEntry =
    VaultEntry(
        id = id,
        label = label,
        type = VaultEntryType.CREDENTIAL,
        payload = VaultPayload.Credential(
            CredentialPayload(
                username = "${label.lowercase()}@example.com",
                password = "secret",
                tags = tags,
                category = category,
            )
        ),
        createdAt = Instant.parse("2026-01-01T00:00:00Z"),
        updatedAt = Instant.parse("2026-01-01T00:01:00Z"),
        version = version,
        updatedBy = device,
    )
