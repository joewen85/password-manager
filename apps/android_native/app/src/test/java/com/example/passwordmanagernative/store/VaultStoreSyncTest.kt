package com.example.passwordmanagernative.store

import com.example.passwordmanagernative.model.CategoryTemplate
import com.example.passwordmanagernative.model.CredentialPayload
import com.example.passwordmanagernative.model.EntryDraft
import com.example.passwordmanagernative.model.VaultEntryType
import com.example.passwordmanagernative.model.VaultSnapshot
import com.example.passwordmanagernative.sync.InMemorySyncSecretStore
import com.example.passwordmanagernative.sync.RemoteSyncClient
import com.example.passwordmanagernative.sync.RemoteSyncResult
import com.example.passwordmanagernative.sync.SyncSettingsConflictStrategy
import com.example.passwordmanagernative.sync.SyncProviderType
import com.example.passwordmanagernative.sync.SyncSettings
import com.example.passwordmanagernative.sync.SyncSettingsRepository
import com.example.passwordmanagernative.sync.VaultSyncEngine
import com.example.passwordmanagernative.sync.VaultSyncPayload
import java.io.File
import java.time.Instant
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class VaultStoreSyncTest {
    @Test
    fun syncSettingsPersistAndReloadThroughRepository() {
        val directory = createTempDirectory("PasswordManagerAndroidVaultStoreSyncSettingsTests").toFile()
        try {
            val syncRepository = SyncSettingsRepository(
                settingsFile = File(directory, "sync_settings.json"),
                secretStore = InMemorySyncSecretStore(),
            )
            val store = VaultStore(
                repository = FileVaultRepository(directory),
                syncSettingsRepository = syncRepository,
            )
            val settings = SyncSettings.defaults(deviceId = "device-1").copy(
                providerType = SyncProviderType.S3_PRESIGNED,
                presignedDownloadUrl = "https://download.example.com/vault",
                presignedUploadUrl = "https://upload.example.com/vault",
            )

            store.updateSyncSettings(settings)

            assertEquals(settings, store.syncSettings)
            assertEquals("Configured: S3 Presigned URL", store.syncStatus)
            assertEquals("Sync settings saved.", store.statusMessage)

            val reloadedStore = VaultStore(
                repository = FileVaultRepository(directory),
                syncSettingsRepository = syncRepository,
            )
            assertEquals(settings, reloadedStore.syncSettings)
            assertEquals("Configured: S3 Presigned URL", reloadedStore.syncStatus)
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun syncNowUploadsSnapshotAndPersistsResult() {
        val directory = createTempDirectory("PasswordManagerAndroidVaultStoreSyncNowTests").toFile()
        try {
            val syncRepository = SyncSettingsRepository(
                settingsFile = File(directory, "sync_settings.json"),
                secretStore = InMemorySyncSecretStore(),
            )
            val now = Instant.parse("2027-01-15T08:00:00Z")
            val engine = VaultSyncEngine(clock = { now })
            val repository = FileVaultRepository(directory)
            val store = VaultStore(
                repository = repository,
                syncSettingsRepository = syncRepository,
                syncEngine = engine,
            )
            assertTrue(store.setupMasterPassword("test-password", "test-password"))
            store.upsert(
                EntryDraft(
                    label = "Sync Login",
                    type = VaultEntryType.CREDENTIAL,
                    category = "",
                    tags = emptyList(),
                    credential = CredentialPayload(
                        username = "sync@example.com",
                        password = "secret",
                    ),
                )
            )
            val settings = SyncSettings.defaults(deviceId = "android-device").copy(
                providerType = SyncProviderType.WEBDAV,
                webdavUrl = "https://dav.example.com/root",
                webdavPath = "/vault.json",
            )
            store.updateSyncSettings(settings)
            val client = VaultStoreSyncFakeClient(
                downloads = ArrayDeque(listOf(RemoteSyncResult(payload = null, statusCode = 404))),
                uploadStatusCodes = ArrayDeque(listOf(201)),
            )

            store.syncNow(client)

            assertEquals(1, client.uploadedPayloads.size)
            val uploaded = assertNotNull(engine.decodePayload(client.uploadedPayloads.single()))
            assertEquals("android-device", uploaded.deviceId)
            assertTrue(uploaded.snapshot.entries.any { it.label == "Sync Login" })
            assertEquals("success", store.syncSettings.lastSyncStatus)
            assertEquals(now, store.syncSettings.lastSyncAt)
            assertTrue(store.syncStatus.contains("Synced 1 items"))

            val reloadedStore = VaultStore(
                repository = repository,
                syncSettingsRepository = syncRepository,
                syncEngine = engine,
            )
            assertTrue(reloadedStore.unlock("test-password"))
            assertEquals("success", reloadedStore.syncSettings.lastSyncStatus)
            assertTrue(reloadedStore.syncStatus.contains("Synced 1 items"))
            assertTrue(reloadedStore.listEntries().any { it.label == "Sync Login" })
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun syncNowPreservesNewlyCreatedEmptyCategory() {
        val directory = createTempDirectory("PasswordManagerAndroidVaultStoreSyncCategoryTests").toFile()
        try {
            val syncRepository = SyncSettingsRepository(
                settingsFile = File(directory, "sync_settings.json"),
                secretStore = InMemorySyncSecretStore(),
            )
            val now = Instant.parse("2027-01-15T08:00:00Z")
            val engine = VaultSyncEngine(clock = { now })
            val repository = FileVaultRepository(directory)
            val store = VaultStore(
                repository = repository,
                syncSettingsRepository = syncRepository,
                syncEngine = engine,
            )
            assertTrue(store.setupMasterPassword("test-password", "test-password"))
            val settings = SyncSettings.defaults(deviceId = "android-device").copy(
                providerType = SyncProviderType.WEBDAV,
                webdavUrl = "https://dav.example.com/root",
                webdavPath = "/vault.json",
            )
            store.updateSyncSettings(settings)
            assertTrue(store.addCategory("test"))
            val client = VaultStoreSyncFakeClient(
                downloads = ArrayDeque(listOf(RemoteSyncResult(payload = null, statusCode = 404))),
                uploadStatusCodes = ArrayDeque(listOf(201)),
            )

            store.syncNow(client)

            assertEquals(listOf("test"), store.categories())
            assertEquals("test", store.categoryTemplate("test")?.category)
            assertEquals(listOf("名称", "备注"), store.categoryTemplate("test")?.fields?.map { it.name })
            val uploaded = assertNotNull(engine.decodePayload(client.uploadedPayloads.single()))
            assertEquals(listOf("test"), uploaded.snapshot.categories)
            assertEquals(listOf("test"), uploaded.snapshot.categoryTemplates.map { it.category })

            val reloadedStore = VaultStore(
                repository = repository,
                syncSettingsRepository = syncRepository,
                syncEngine = engine,
            )
            assertTrue(reloadedStore.unlock("test-password"))
            assertEquals(listOf("test"), reloadedStore.categories())
            assertEquals("test", reloadedStore.categoryTemplate("test")?.category)
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun syncNowDoesNotRestoreLocallyDeletedEmptyCategory() {
        val directory = createTempDirectory("PasswordManagerAndroidVaultStoreSyncDeletedCategoryTests").toFile()
        try {
            val syncRepository = SyncSettingsRepository(
                settingsFile = File(directory, "sync_settings.json"),
                secretStore = InMemorySyncSecretStore(),
            )
            val now = Instant.parse("2027-01-15T08:00:00Z")
            val engine = VaultSyncEngine(clock = { now })
            val repository = FileVaultRepository(directory)
            val store = VaultStore(
                repository = repository,
                syncSettingsRepository = syncRepository,
                syncEngine = engine,
            )
            assertTrue(store.setupMasterPassword("test-password", "test-password"))
            val settings = SyncSettings.defaults(deviceId = "android-device").copy(
                providerType = SyncProviderType.WEBDAV,
                webdavUrl = "https://dav.example.com/root",
                webdavPath = "/vault.json",
                conflictStrategy = SyncSettingsConflictStrategy.KEEP_BOTH,
                lastSyncRevision = 2,
            )
            store.updateSyncSettings(settings)
            assertTrue(store.addCategory("test"))
            assertTrue(store.deleteCategory("test"))
            val staleRemote = VaultSnapshot(
                entries = emptyList(),
                categories = listOf("test"),
                categoryTemplates = listOf(CategoryTemplate(category = "test")),
                tags = emptyList(),
                updatedAt = Instant.parse("2027-01-15T08:01:00Z"),
            )
            val remotePayload = engine.encodePayload(
                VaultSyncPayload(
                    exportedAt = now,
                    deviceId = "remote-device",
                    revision = 3,
                    snapshot = staleRemote,
                )
            )
            val client = VaultStoreSyncFakeClient(
                downloads = ArrayDeque(listOf(RemoteSyncResult(payload = remotePayload, statusCode = 200))),
                uploadStatusCodes = ArrayDeque(listOf(200)),
            )

            store.syncNow(client)

            assertEquals(emptyList(), store.categories())
            assertEquals(null, store.categoryTemplate("test"))
            val uploaded = assertNotNull(engine.decodePayload(client.uploadedPayloads.single()))
            assertEquals(4, uploaded.revision)
            assertEquals(emptyList(), uploaded.snapshot.categories)
            assertEquals(emptyList(), uploaded.snapshot.categoryTemplates)

            val reloadedStore = VaultStore(
                repository = repository,
                syncSettingsRepository = syncRepository,
                syncEngine = engine,
            )
            assertTrue(reloadedStore.unlock("test-password"))
            assertEquals(emptyList(), reloadedStore.categories())
            assertEquals(null, reloadedStore.categoryTemplate("test"))
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun clearAllDataRequiresMasterPasswordAndKeepsVaultUsable() {
        val directory = createTempDirectory("PasswordManagerAndroidClearDataTests").toFile()
        try {
            val store = VaultStore(repository = FileVaultRepository(directory))
            assertTrue(store.setupMasterPassword("test-password", "test-password"))
            store.upsert(
                EntryDraft(
                    label = "Clear Me",
                    type = VaultEntryType.CREDENTIAL,
                    category = "Temporary",
                    tags = listOf("wipe"),
                    credential = CredentialPayload(
                        username = "clear@example.com",
                        password = "secret",
                        category = "Temporary",
                        tags = listOf("wipe"),
                    ),
                )
            )
            store.setTotpSecret("JBSWY3DPEHPK3PXP")
            store.setRequireTotp(true)

            assertFalse(store.clearAllData("wrong-password"))
            assertEquals(1, store.listEntries().size)
            assertTrue(store.requireTotp)

            assertTrue(store.clearAllData("test-password"))

            assertEquals(emptyList(), store.listEntries())
            assertEquals(emptyList(), store.categories())
            assertEquals(emptyList(), store.tags())
            assertFalse(store.requireTotp)
            assertEquals("", store.totpSecret)

            val reloadedStore = VaultStore(repository = FileVaultRepository(directory))
            assertTrue(reloadedStore.unlock("test-password"))
            assertEquals(emptyList(), reloadedStore.listEntries())
            assertFalse(reloadedStore.requireTotp)
        } finally {
            directory.deleteRecursively()
        }
    }
}

private class VaultStoreSyncFakeClient(
    private val downloads: ArrayDeque<RemoteSyncResult>,
    private val uploadStatusCodes: ArrayDeque<Int>,
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
