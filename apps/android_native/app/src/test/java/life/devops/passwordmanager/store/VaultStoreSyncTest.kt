package life.devops.passwordmanager.store

import life.devops.passwordmanager.model.CategoryTemplate
import life.devops.passwordmanager.model.CredentialPayload
import life.devops.passwordmanager.model.EncryptedPayloadRecord
import life.devops.passwordmanager.model.EntryDraft
import life.devops.passwordmanager.model.MasterKeyRecord
import life.devops.passwordmanager.model.ServiceAccount
import life.devops.passwordmanager.model.VaultEntry
import life.devops.passwordmanager.model.VaultEntryType
import life.devops.passwordmanager.model.VaultPayload
import life.devops.passwordmanager.model.VaultSnapshot
import life.devops.passwordmanager.sync.InMemorySyncSecretStore
import life.devops.passwordmanager.sync.RemoteSyncClient
import life.devops.passwordmanager.sync.RemoteSyncResult
import life.devops.passwordmanager.sync.SyncSettingsConflictStrategy
import life.devops.passwordmanager.sync.SyncProviderType
import life.devops.passwordmanager.sync.SyncSettings
import life.devops.passwordmanager.sync.SyncSettingsRepository
import life.devops.passwordmanager.sync.VaultSyncEngine
import life.devops.passwordmanager.sync.VaultSyncPayload
import org.json.JSONObject
import java.io.File
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
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
                        accounts = listOf(ServiceAccount(username = "ops", password = "account-secret")),
                        token = "sync-token",
                        secretKey = "sync-secret-key",
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
            val rawUpload = client.uploadedPayloads.single()
            assertFalse(rawUpload.contains("Sync Login"))
            assertFalse(rawUpload.contains("sync@example.com"))
            assertFalse(rawUpload.contains("secret"))
            assertFalse(rawUpload.contains("account-secret"))
            assertFalse(rawUpload.contains("sync-token"))
            assertFalse(rawUpload.contains("sync-secret-key"))
            assertTrue(rawUpload.contains("encryptedVault"))
            assertFalse(rawUpload.contains("\"snapshot\""))
            val uploaded = decodeEncryptedSyncPayload(rawUpload, repository)
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
    fun syncNowAppliesEncryptedRemoteSnapshot() {
        val directory = createTempDirectory("PasswordManagerAndroidVaultStoreEncryptedRemoteSyncTests").toFile()
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
            val remoteSnapshot = VaultSnapshot(
                entries = listOf(
                    VaultEntry(
                        label = "Remote Login",
                        type = VaultEntryType.CREDENTIAL,
                        payload = VaultPayload.Credential(
                            CredentialPayload(
                                username = "remote@example.com",
                                password = "remote-secret",
                                token = "remote-token",
                                secretKey = "remote-secret-key",
                            )
                        ),
                        updatedAt = Instant.parse("2027-01-15T08:01:00Z"),
                        version = mapOf("remote-device" to 1),
                        updatedBy = "remote-device",
                    )
                ),
                updatedAt = Instant.parse("2027-01-15T08:01:00Z"),
            )
            val remotePayload = encodeEncryptedSyncPayload(
                VaultSyncPayload(
                    exportedAt = now,
                    deviceId = "remote-device",
                    revision = 1,
                    snapshot = remoteSnapshot,
                ),
                repository = repository,
            )
            val client = VaultStoreSyncFakeClient(
                downloads = ArrayDeque(listOf(RemoteSyncResult(payload = remotePayload, statusCode = 200))),
                uploadStatusCodes = ArrayDeque(listOf(200)),
            )

            store.syncNow(client)

            assertTrue(store.listEntries().any { it.label == "Remote Login" })
            assertFalse(remotePayload.contains("remote-secret"))
            assertTrue(remotePayload.contains("encryptedVault"))
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun syncNowOnFreshInstallUsesRemoteMasterKeyRecord() {
        val directory = createTempDirectory("PasswordManagerAndroidFreshInstallSyncTests").toFile()
        try {
            val now = Instant.parse("2027-01-15T08:00:00Z")
            val engine = VaultSyncEngine(clock = { now })
            val remote = createRemoteSyncFixture(File(directory, "remote"), engine)
            val fresh = createConfiguredSyncStore(
                directory = File(directory, "fresh"),
                engine = engine,
                password = "test-password",
                deviceId = "fresh-device",
            )
            val freshClient = VaultStoreSyncFakeClient(
                downloads = ArrayDeque(listOf(RemoteSyncResult(payload = remote.payload, statusCode = 200))),
                uploadStatusCodes = ArrayDeque(listOf(200)),
            )

            fresh.store.syncNow(freshClient)

            assertEquals("success", fresh.store.syncSettings.lastSyncStatus, fresh.store.syncSettings.lastSyncMessage)
            val expectedLabels = setOf("Remote Login", "Remote Server")
            val expectedCategories = setOf("Accounts", "Infrastructure", "Empty Category")
            assertEquals(expectedLabels, fresh.store.listEntries().map { it.label }.toSet())
            assertEquals(expectedCategories, fresh.store.categories().toSet())
            assertEquals(remote.masterKeyRecord, fresh.repository.loadEnvelope()?.masterKeyRecord)
            val mergedRemotePayload = freshClient.uploadedPayloads.single()
            assertEquals(
                remote.masterKeyRecord.saltBase64,
                JSONObject(mergedRemotePayload).getJSONObject("masterKeyRecord").getString("saltBase64"),
            )
            val mergedRemoteLabels = decodeEncryptedSyncPayload(mergedRemotePayload, remote.repository)
                .snapshot.entries.map { it.label }.toSet()
            assertEquals(expectedLabels, mergedRemoteLabels)

            val reloadedStore = VaultStore(
                repository = fresh.repository,
                syncSettingsRepository = fresh.syncSettingsRepository,
                syncEngine = engine,
            )
            assertTrue(reloadedStore.unlock("test-password"))
            assertEquals(expectedLabels, reloadedStore.listEntries().map { it.label }.toSet())
            assertEquals(expectedCategories, reloadedStore.categories().toSet())
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun syncNowOnFreshInstallRejectsRemoteMasterKeyRecordForWrongPassword() {
        val directory = createTempDirectory("PasswordManagerAndroidFreshInstallWrongPasswordSyncTests").toFile()
        try {
            val engine = VaultSyncEngine(clock = { Instant.parse("2027-01-15T08:00:00Z") })
            val remote = createRemoteSyncFixture(File(directory, "remote"), engine)
            val fresh = createConfiguredSyncStore(
                directory = File(directory, "fresh"),
                engine = engine,
                password = "wrong-password",
                deviceId = "wrong-password-device",
            )
            val localMasterKeyRecord = fresh.repository.loadEnvelope()?.masterKeyRecord

            fresh.store.syncNow(
                VaultStoreSyncFakeClient(
                    downloads = ArrayDeque(listOf(RemoteSyncResult(payload = remote.payload, statusCode = 200))),
                    uploadStatusCodes = ArrayDeque(listOf(200)),
                )
            )

            assertEquals("error", fresh.store.syncSettings.lastSyncStatus)
            assertEquals("Vault authentication failed.", fresh.store.syncSettings.lastSyncMessage)
            assertEquals(emptyList(), fresh.store.listEntries())
            assertEquals(localMasterKeyRecord, fresh.repository.loadEnvelope()?.masterKeyRecord)
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun syncNowRewritesLegacyPlaintextRemoteWhenNoMergeUploadIsNeeded() {
        val directory = createTempDirectory("PasswordManagerAndroidVaultStoreLegacyPlaintextRemoteSyncTests").toFile()
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
            store.syncNow(
                VaultStoreSyncFakeClient(
                    downloads = ArrayDeque(listOf(RemoteSyncResult(payload = null, statusCode = 404))),
                    uploadStatusCodes = ArrayDeque(listOf(200)),
                )
            )
            val remoteSnapshot = VaultSnapshot(
                entries = listOf(
                    VaultEntry(
                        label = "Legacy Remote Login",
                        type = VaultEntryType.CREDENTIAL,
                        payload = VaultPayload.Credential(
                            CredentialPayload(username = "legacy@example.com", password = "legacy-secret")
                        ),
                        updatedAt = Instant.parse("2027-01-15T08:01:00Z"),
                        version = mapOf("remote-device" to 1),
                        updatedBy = "remote-device",
                    )
                ),
                updatedAt = Instant.parse("2027-01-15T08:01:00Z"),
            )
            val legacyRemotePayload = engine.encodePayload(
                VaultSyncPayload(
                    exportedAt = now,
                    deviceId = "remote-device",
                    revision = 2,
                    snapshot = remoteSnapshot,
                )
            )
            val client = VaultStoreSyncFakeClient(
                downloads = ArrayDeque(listOf(RemoteSyncResult(payload = legacyRemotePayload, statusCode = 200))),
                uploadStatusCodes = ArrayDeque(listOf(200)),
            )

            store.syncNow(client)

            assertTrue(store.listEntries().any { it.label == "Legacy Remote Login" })
            assertEquals(1, client.uploadedPayloads.size)
            val migrated = decodeEncryptedSyncPayload(client.uploadedPayloads.single(), repository)
            assertEquals(2, migrated.revision)
            assertTrue(migrated.snapshot.entries.any { it.label == "Legacy Remote Login" })
            assertFalse(client.uploadedPayloads.single().contains("legacy-secret"))
            assertTrue(client.uploadedPayloads.single().contains("encryptedVault"))
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
            val uploaded = decodeEncryptedSyncPayload(client.uploadedPayloads.single(), repository)
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
            val uploaded = decodeEncryptedSyncPayload(client.uploadedPayloads.single(), repository)
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
    fun syncNowIgnoresStaleResultWhenLocalCategoryChangesDuringSync() {
        val directory = createTempDirectory("PasswordManagerAndroidVaultStoreSyncRaceCategoryTests").toFile()
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
            val client = BlockingVaultStoreSyncFakeClient(
                downloads = ArrayDeque(
                    listOf(
                        RemoteSyncResult(payload = remotePayload, statusCode = 200),
                        RemoteSyncResult(payload = remotePayload, statusCode = 200),
                    )
                ),
                uploadStatusCodes = ArrayDeque(listOf(200)),
            )
            val syncFailure = AtomicReference<Throwable?>(null)
            val syncThread = Thread {
                runCatching { store.syncNow(client) }
                    .onFailure { syncFailure.set(it) }
            }

            syncThread.start()
            assertTrue(client.waitForDownloadAttempt())
            assertTrue(store.deleteCategory("test"))
            client.releaseDownload()
            syncThread.join(5_000)

            assertFalse(syncThread.isAlive)
            syncFailure.get()?.let { throw AssertionError("Sync thread failed", it) }
            assertEquals(emptyList(), store.categories())
            assertEquals(null, store.categoryTemplate("test"))
            assertEquals(1, client.uploadedPayloads.size)
            val uploaded = decodeEncryptedSyncPayload(client.uploadedPayloads.single(), repository)
            assertEquals(4, uploaded.revision)
            assertEquals(emptyList(), uploaded.snapshot.categories)
            assertEquals(emptyList(), uploaded.snapshot.categoryTemplates)
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

private data class ConfiguredSyncStore(
    val store: VaultStore,
    val repository: FileVaultRepository,
    val syncSettingsRepository: SyncSettingsRepository,
)

private data class RemoteSyncFixture(
    val payload: String,
    val masterKeyRecord: MasterKeyRecord,
    val repository: FileVaultRepository,
)

private fun createConfiguredSyncStore(
    directory: File,
    engine: VaultSyncEngine,
    password: String,
    deviceId: String,
): ConfiguredSyncStore {
    val repository = FileVaultRepository(directory)
    val syncSettingsRepository = SyncSettingsRepository(
        settingsFile = File(directory, "sync_settings.json"),
        secretStore = InMemorySyncSecretStore(),
    )
    val store = VaultStore(
        repository = repository,
        syncSettingsRepository = syncSettingsRepository,
        syncEngine = engine,
    )
    check(store.setupMasterPassword(password, password))
    store.updateSyncSettings(
        SyncSettings.defaults(deviceId = deviceId).copy(
            providerType = SyncProviderType.WEBDAV,
            webdavUrl = "https://dav.example.com/root",
            webdavPath = "/vault.json",
        )
    )
    return ConfiguredSyncStore(store, repository, syncSettingsRepository)
}

private fun createRemoteSyncFixture(
    directory: File,
    engine: VaultSyncEngine,
): RemoteSyncFixture {
    val remote = createConfiguredSyncStore(
        directory = directory,
        engine = engine,
        password = "test-password",
        deviceId = "remote-device",
    )
    check(remote.store.addCategory("Accounts"))
    check(remote.store.addCategory("Infrastructure"))
    check(remote.store.addCategory("Empty Category"))
    remote.store.upsert(
        EntryDraft(
            label = "Remote Login",
            type = VaultEntryType.CREDENTIAL,
            category = "Accounts",
            tags = emptyList(),
            credential = CredentialPayload(
                username = "remote@example.com",
                password = "remote-secret",
            ),
        )
    )
    val initialUpload = VaultStoreSyncFakeClient(
        downloads = ArrayDeque(listOf(RemoteSyncResult(payload = null, statusCode = 404))),
        uploadStatusCodes = ArrayDeque(listOf(201)),
    )
    remote.store.syncNow(initialUpload)
    remote.store.upsert(
        EntryDraft(
            label = "Remote Server",
            type = VaultEntryType.SERVER,
            category = "Infrastructure",
            tags = emptyList(),
        )
    )
    val updatedUpload = VaultStoreSyncFakeClient(
        downloads = ArrayDeque(
            listOf(RemoteSyncResult(payload = initialUpload.uploadedPayloads.single(), statusCode = 200))
        ),
        uploadStatusCodes = ArrayDeque(listOf(200)),
    )
    remote.store.syncNow(updatedUpload)
    val payload = updatedUpload.uploadedPayloads.single()
    check(JSONObject(payload).getInt("revision") == 1)
    check(JSONObject(payload).optJSONObject("masterKeyRecord") != null)
    return RemoteSyncFixture(
        payload = payload,
        masterKeyRecord = checkNotNull(remote.repository.loadEnvelope()?.masterKeyRecord),
        repository = remote.repository,
    )
}

private fun decodeEncryptedSyncPayload(
    rawPayload: String,
    repository: FileVaultRepository,
    password: String = "test-password",
): VaultSyncPayload {
    val json = JSONObject(rawPayload)
    val encryptedJson = json.getJSONObject("encryptedVault")
    val encryptedVault = EncryptedPayloadRecord(
        ciphertext = encryptedJson.getString("ciphertext"),
        nonce = encryptedJson.getString("nonce"),
        mac = encryptedJson.getString("mac"),
        version = encryptedJson.optInt("version", 1),
    )
    val masterKeyRecord = checkNotNull(repository.loadEnvelope()?.masterKeyRecord)
    val crypto = AndroidVaultCrypto()
    val key = crypto.verify(password, masterKeyRecord)
    val snapshot = VaultJson.decodeSnapshot(
        String(crypto.decrypt(encryptedVault, key), StandardCharsets.UTF_8)
    )
    return VaultSyncPayload(
        version = json.optInt("version", 1),
        exportedAt = Instant.parse(json.getString("exportedAt")),
        deviceId = json.optString("deviceId"),
        revision = json.optInt("revision", 0),
        snapshot = snapshot,
    )
}

private fun encodeEncryptedSyncPayload(
    payload: VaultSyncPayload,
    repository: FileVaultRepository,
    password: String = "test-password",
): String {
    val masterKeyRecord = checkNotNull(repository.loadEnvelope()?.masterKeyRecord)
    val crypto = AndroidVaultCrypto()
    val key = crypto.verify(password, masterKeyRecord)
    val encryptedVault = crypto.encrypt(
        VaultJson.encodeSnapshot(payload.snapshot).toByteArray(StandardCharsets.UTF_8),
        key,
    )
    return JSONObject()
        .put("version", payload.version)
        .put("exportedAt", payload.exportedAt.toString())
        .put("deviceId", payload.deviceId)
        .put("revision", payload.revision)
        .put("masterKeyRecord", JSONObject.NULL)
        .put(
            "encryptedVault",
            JSONObject()
                .put("ciphertext", encryptedVault.ciphertext)
                .put("nonce", encryptedVault.nonce)
                .put("mac", encryptedVault.mac)
                .put("version", encryptedVault.version)
        )
        .toString()
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

private class BlockingVaultStoreSyncFakeClient(
    private val downloads: ArrayDeque<RemoteSyncResult>,
    private val uploadStatusCodes: ArrayDeque<Int>,
) : RemoteSyncClient {
    val uploadedPayloads = mutableListOf<String>()
    private val firstDownloadStarted = CountDownLatch(1)
    private val releaseFirstDownload = CountDownLatch(1)
    private var downloadCount = 0

    fun waitForDownloadAttempt(): Boolean =
        firstDownloadStarted.await(2, TimeUnit.SECONDS)

    fun releaseDownload() {
        releaseFirstDownload.countDown()
    }

    override fun download(): RemoteSyncResult {
        val shouldBlock = synchronized(this) {
            val isFirstDownload = downloadCount == 0
            downloadCount += 1
            isFirstDownload
        }
        if (shouldBlock) {
            firstDownloadStarted.countDown()
            if (!releaseFirstDownload.await(2, TimeUnit.SECONDS)) {
                return RemoteSyncResult(payload = null, statusCode = 408)
            }
        }
        return synchronized(this) {
            if (downloads.isEmpty()) RemoteSyncResult(payload = null, statusCode = 404) else downloads.removeFirst()
        }
    }

    override fun upload(payload: String): RemoteSyncResult {
        val statusCode = synchronized(this) {
            uploadedPayloads += payload
            if (uploadStatusCodes.isEmpty()) 200 else uploadStatusCodes.removeFirst()
        }
        return RemoteSyncResult(payload = null, statusCode = statusCode)
    }
}
