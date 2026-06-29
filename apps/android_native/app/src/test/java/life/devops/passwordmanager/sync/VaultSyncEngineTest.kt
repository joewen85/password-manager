package life.devops.passwordmanager.sync

import life.devops.passwordmanager.model.CategoryTemplate
import life.devops.passwordmanager.model.CredentialPayload
import life.devops.passwordmanager.model.SecuritySettings
import life.devops.passwordmanager.model.VaultEntry
import life.devops.passwordmanager.model.VaultEntryType
import life.devops.passwordmanager.model.VaultPayload
import life.devops.passwordmanager.model.VaultSnapshot
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
    fun remoteTombstoneAppliesWithoutRestoringDeletedTaxonomy() {
        val now = Instant.parse("2027-01-15T08:00:00Z")
        val engine = VaultSyncEngine(clock = { now })
        val settings = SyncSettings.defaults(deviceId = "android-device").copy(
            lastSyncRevision = 1,
            hasLocalChanges = false,
        )
        val sharedId = "deleted-shared"
        val local = makeSnapshot(
            categories = listOf("Deleted Category"),
            tags = listOf("deleted-tag"),
            entries = listOf(
                makeEntry(
                    id = sharedId,
                    label = "Local",
                    category = "Deleted Category",
                    tags = listOf("deleted-tag"),
                    device = "android",
                    version = mapOf("android" to 1),
                )
            )
        )
        val remote = makeSnapshot(
            categories = emptyList(),
            tags = emptyList(),
            entries = listOf(
                makeEntry(
                    id = sharedId,
                    label = "Local",
                    category = "Deleted Category",
                    tags = listOf("deleted-tag"),
                    device = "remote",
                    version = mapOf("android" to 1, "remote" to 1),
                    isDeleted = true,
                )
            )
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
        assertTrue(result.snapshot.entries.single().isDeleted)
        assertEquals(emptyList(), result.snapshot.categories)
        assertEquals(emptyList(), result.snapshot.tags)
        assertTrue(client.uploadedPayloads.isEmpty())
    }

    @Test
    fun localEmptyCategoryKeepsTemplateWhenMergedWithNewerRemote() {
        val now = Instant.parse("2027-01-15T08:00:00Z")
        val engine = VaultSyncEngine(clock = { now })
        val settings = SyncSettings.defaults(deviceId = "android-device").copy(
            lastSyncRevision = 1,
            hasLocalChanges = true,
        )
        val local = makeSnapshot(
            categories = listOf("test"),
            categoryTemplates = listOf(CategoryTemplate(category = "test")),
            entries = emptyList(),
        )
        val remote = makeSnapshot(
            categories = emptyList(),
            categoryTemplates = emptyList(),
            entries = emptyList(),
            updatedAt = Instant.parse("2027-01-15T08:01:00Z"),
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
            downloads = ArrayDeque(listOf(RemoteSyncResult(payload = remotePayload, statusCode = 200))),
            uploadStatusCodes = ArrayDeque(listOf(200)),
        )

        val result = engine.synchronize(localSnapshot = local, settings = settings, client = client)

        assertTrue(result.uploaded)
        assertEquals(listOf("test"), result.snapshot.categories)
        assertEquals(listOf("test"), result.snapshot.categoryTemplates.map { it.category })
        assertEquals(listOf("名称", "备注"), result.snapshot.categoryTemplates.single().fields.map { it.name })
        val uploaded = engine.decodePayload(client.uploadedPayloads.single())!!
        assertEquals(listOf("test"), uploaded.snapshot.categories)
        assertEquals(listOf("test"), uploaded.snapshot.categoryTemplates.map { it.category })
        assertEquals(listOf("名称", "备注"), uploaded.snapshot.categoryTemplates.single().fields.map { it.name })
    }

    @Test
    fun keepBothPreservesLocalEmptyCategoryWhenLocalChangesFlagIsClean() {
        val now = Instant.parse("2027-01-15T08:00:00Z")
        val engine = VaultSyncEngine(clock = { now })
        val settings = SyncSettings.defaults(deviceId = "android-device").copy(
            lastSyncRevision = 1,
            hasLocalChanges = false,
            conflictStrategy = SyncSettingsConflictStrategy.KEEP_BOTH,
        )
        val local = makeSnapshot(
            categories = listOf("test"),
            categoryTemplates = listOf(CategoryTemplate(category = "test")),
            entries = emptyList(),
        )
        val remote = makeSnapshot(
            categories = emptyList(),
            categoryTemplates = emptyList(),
            entries = emptyList(),
            updatedAt = Instant.parse("2027-01-15T08:01:00Z"),
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
            downloads = ArrayDeque(listOf(RemoteSyncResult(payload = remotePayload, statusCode = 200))),
            uploadStatusCodes = ArrayDeque(listOf(200)),
        )

        val result = engine.synchronize(localSnapshot = local, settings = settings, client = client)

        assertTrue(result.uploaded)
        assertEquals(listOf("test"), result.snapshot.categories)
        assertEquals(listOf("test"), result.snapshot.categoryTemplates.map { it.category })
        assertEquals(listOf("名称", "备注"), result.snapshot.categoryTemplates.single().fields.map { it.name })
        val uploaded = engine.decodePayload(client.uploadedPayloads.single())!!
        assertEquals(listOf("test"), uploaded.snapshot.categories)
        assertEquals(listOf("test"), uploaded.snapshot.categoryTemplates.map { it.category })
    }

    @Test
    fun keepBothDoesNotRestoreLocallyDeletedEmptyCategory() {
        val now = Instant.parse("2027-01-15T08:00:00Z")
        val engine = VaultSyncEngine(clock = { now })
        val settings = SyncSettings.defaults(deviceId = "android-device").copy(
            lastSyncRevision = 2,
            hasLocalChanges = true,
            conflictStrategy = SyncSettingsConflictStrategy.KEEP_BOTH,
        )
        val local = makeSnapshot(
            categories = emptyList(),
            categoryTemplates = emptyList(),
            entries = emptyList(),
            updatedAt = Instant.parse("2027-01-15T08:01:00Z"),
        )
        val remote = makeSnapshot(
            categories = listOf("test"),
            categoryTemplates = listOf(CategoryTemplate(category = "test")),
            entries = emptyList(),
            updatedAt = Instant.parse("2027-01-15T08:00:00Z"),
        )
        val remotePayload = engine.encodePayload(
            VaultSyncPayload(
                exportedAt = now,
                deviceId = "remote-device",
                revision = 3,
                snapshot = remote,
            )
        )
        val client = FakeSyncClient(
            downloads = ArrayDeque(listOf(RemoteSyncResult(payload = remotePayload, statusCode = 200))),
            uploadStatusCodes = ArrayDeque(listOf(200)),
        )

        val result = engine.synchronize(localSnapshot = local, settings = settings, client = client)

        assertTrue(result.uploaded)
        assertEquals(emptyList(), result.snapshot.categories)
        assertEquals(emptyList(), result.snapshot.categoryTemplates)
        val uploaded = engine.decodePayload(client.uploadedPayloads.single())!!
        assertEquals(emptyList(), uploaded.snapshot.categories)
        assertEquals(emptyList(), uploaded.snapshot.categoryTemplates)
    }

    @Test
    fun keepBothDoesNotRestoreOldCategoryNameAfterLocalRename() {
        val now = Instant.parse("2027-01-15T08:00:00Z")
        val engine = VaultSyncEngine(clock = { now })
        val settings = SyncSettings.defaults(deviceId = "android-device").copy(
            lastSyncRevision = 2,
            hasLocalChanges = true,
            conflictStrategy = SyncSettingsConflictStrategy.KEEP_BOTH,
        )
        val local = makeSnapshot(
            categories = listOf("prod"),
            categoryTemplates = listOf(CategoryTemplate(category = "prod")),
            entries = emptyList(),
            updatedAt = Instant.parse("2027-01-15T08:01:00Z"),
        )
        val remote = makeSnapshot(
            categories = listOf("test"),
            categoryTemplates = listOf(CategoryTemplate(category = "test")),
            entries = emptyList(),
            updatedAt = Instant.parse("2027-01-15T08:00:00Z"),
        )
        val remotePayload = engine.encodePayload(
            VaultSyncPayload(
                exportedAt = now,
                deviceId = "remote-device",
                revision = 3,
                snapshot = remote,
            )
        )
        val client = FakeSyncClient(
            downloads = ArrayDeque(listOf(RemoteSyncResult(payload = remotePayload, statusCode = 200))),
            uploadStatusCodes = ArrayDeque(listOf(200)),
        )

        val result = engine.synchronize(localSnapshot = local, settings = settings, client = client)

        assertTrue(result.uploaded)
        assertEquals(listOf("prod"), result.snapshot.categories)
        assertEquals(listOf("prod"), result.snapshot.categoryTemplates.map { it.category })
        val uploaded = engine.decodePayload(client.uploadedPayloads.single())!!
        assertEquals(listOf("prod"), uploaded.snapshot.categories)
        assertEquals(listOf("prod"), uploaded.snapshot.categoryTemplates.map { it.category })
    }

    @Test
    fun unchangedRemoteFingerprintSkipsFullDownloadWhenLocalIsClean() {
        val now = Instant.parse("2027-01-15T08:00:00Z")
        val engine = VaultSyncEngine(clock = { now })
        val settings = SyncSettings.defaults(deviceId = "android-device").copy(
            lastRemoteFingerprint = "etag:\"same\"",
            hasLocalChanges = false,
        )
        val local = makeSnapshot(
            entries = listOf(makeEntry(id = "local-1", label = "Local", device = "android"))
        )
        val client = FakeSyncClient(
            downloads = ArrayDeque(listOf(RemoteSyncResult(payload = "should-not-download", statusCode = 200))),
            metadata = RemoteSyncMetadata(statusCode = 200, eTag = "\"same\""),
        )

        val result = engine.synchronize(localSnapshot = local, settings = settings, client = client)

        assertFalse(result.uploaded)
        assertFalse(result.appliedRemote)
        assertEquals(0, client.downloadCount)
        assertEquals(1, client.metadataCount)
        assertEquals("Remote unchanged; skipped full sync download.", result.settings.lastSyncMessage)
        assertEquals("etag:\"same\"", result.settings.lastRemoteFingerprint)
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

    @Test
    fun localTaxonomyDeletionIsNotRestoredFromRemoteMetadataWhenLocalHasChanges() {
        val now = Instant.parse("2027-01-15T08:00:00Z")
        val engine = VaultSyncEngine(clock = { now })
        val settings = SyncSettings.defaults(deviceId = "android-device").copy(
            lastSyncRevision = 2,
            hasLocalChanges = true,
        )
        val local = makeSnapshot(
            categories = emptyList(),
            tags = emptyList(),
            entries = listOf(makeEntry(id = "shared", label = "Local", device = "android", version = mapOf("android" to 2)))
        )
        val remote = makeSnapshot(
            categories = listOf("Deleted Category"),
            tags = listOf("deleted-tag"),
            entries = listOf(makeEntry(id = "shared", label = "Remote", device = "remote", version = mapOf("android" to 1)))
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
            downloads = ArrayDeque(listOf(RemoteSyncResult(payload = remotePayload, statusCode = 200))),
            uploadStatusCodes = ArrayDeque(listOf(200)),
        )

        val result = engine.synchronize(localSnapshot = local, settings = settings, client = client)

        assertTrue(result.uploaded)
        assertEquals(emptyList(), result.snapshot.categories)
        assertEquals(emptyList(), result.snapshot.tags)
        val uploaded = engine.decodePayload(client.uploadedPayloads.single())!!
        assertEquals(emptyList(), uploaded.snapshot.categories)
        assertEquals(emptyList(), uploaded.snapshot.tags)
    }

    @Test
    fun localChangesUploadDirectlyWhenRemoteRevisionHasNotAdvanced() {
        val now = Instant.parse("2027-01-15T08:00:00Z")
        val engine = VaultSyncEngine(clock = { now })
        val settings = SyncSettings.defaults(deviceId = "android-device").copy(
            lastSyncRevision = 3,
            hasLocalChanges = true,
        )
        val local = makeSnapshot(
            categories = emptyList(),
            tags = emptyList(),
            entries = listOf(
                makeEntry(
                    id = "shared",
                    label = "Local",
                    category = "",
                    tags = emptyList(),
                    device = "android",
                    updatedAt = Instant.parse("2027-01-15T08:00:00Z"),
                    version = mapOf("android" to 1),
                )
            )
        )
        val remote = makeSnapshot(
            categories = listOf("Old Category"),
            tags = listOf("old-tag"),
            entries = listOf(
                makeEntry(
                    id = "shared",
                    label = "Remote",
                    category = "Old Category",
                    tags = listOf("old-tag"),
                    device = "android",
                    updatedAt = Instant.parse("2027-01-15T09:00:00Z"),
                    version = mapOf("android" to 1),
                )
            )
        )
        val remotePayload = engine.encodePayload(
            VaultSyncPayload(
                exportedAt = now,
                deviceId = "remote-device",
                revision = 3,
                snapshot = remote,
            )
        )
        val client = FakeSyncClient(
            downloads = ArrayDeque(listOf(RemoteSyncResult(payload = remotePayload, statusCode = 200))),
            uploadStatusCodes = ArrayDeque(listOf(200)),
        )

        val result = engine.synchronize(localSnapshot = local, settings = settings, client = client)

        assertTrue(result.uploaded)
        assertFalse(result.appliedRemote)
        assertEquals(4, result.settings.lastSyncRevision)
        assertEquals(emptyList(), result.snapshot.categories)
        assertEquals(emptyList(), result.snapshot.tags)
        val uploaded = engine.decodePayload(client.uploadedPayloads.single())!!
        assertEquals(4, uploaded.revision)
        assertEquals("Local", uploaded.snapshot.entries.single().label)
        assertEquals("", uploaded.snapshot.entries.single().payload.category)
        assertEquals(emptyList(), uploaded.snapshot.entries.single().payload.tags)
    }
}

private class FakeSyncClient(
    private val downloads: ArrayDeque<RemoteSyncResult>,
    private val uploadStatusCodes: ArrayDeque<Int> = ArrayDeque(),
    private val metadata: RemoteSyncMetadata = RemoteSyncMetadata(statusCode = 501),
) : RemoteSyncClient {
    val uploadedPayloads = mutableListOf<String>()
    var downloadCount = 0
        private set
    var metadataCount = 0
        private set

    override fun metadata(): RemoteSyncMetadata {
        metadataCount += 1
        return metadata
    }

    override fun download(): RemoteSyncResult {
        downloadCount += 1
        return if (downloads.isEmpty()) RemoteSyncResult(payload = null, statusCode = 404) else downloads.removeFirst()
    }

    override fun upload(payload: String): RemoteSyncResult {
        uploadedPayloads += payload
        val statusCode = if (uploadStatusCodes.isEmpty()) 200 else uploadStatusCodes.removeFirst()
        return RemoteSyncResult(payload = null, statusCode = statusCode)
    }
}

private fun makeSnapshot(
    categories: List<String> = emptyList(),
    categoryTemplates: List<CategoryTemplate> = emptyList(),
    tags: List<String> = emptyList(),
    entries: List<VaultEntry>,
    updatedAt: Instant = Instant.parse("2026-01-01T00:00:00Z"),
): VaultSnapshot =
    VaultSnapshot(
        entries = entries,
        categories = categories,
        categoryTemplates = categoryTemplates,
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
    updatedAt: Instant = Instant.parse("2026-01-01T00:01:00Z"),
    version: Map<String, Int> = emptyMap(),
    isDeleted: Boolean = false,
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
        updatedAt = updatedAt,
        version = version,
        updatedBy = device,
        isDeleted = isDeleted,
        deletedAt = if (isDeleted) updatedAt else null,
    )
