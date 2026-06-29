package life.devops.passwordmanager.sync

import org.json.JSONObject
import java.io.File
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SyncSettingsTest {
    @Test
    fun defaultsMatchFlutterSyncSettingsContract() {
        val settings = SyncSettings.defaults(deviceId = "device-1")

        assertEquals(SyncProviderType.NONE, settings.providerType)
        assertEquals("/vault.json", settings.webdavPath)
        assertEquals(false, settings.autoSyncEnabled)
        assertEquals(30, settings.autoSyncIntervalMinutes)
        assertEquals(30, settings.autoSyncIntervalValue)
        assertEquals(SyncIntervalUnit.MINUTES, settings.autoSyncIntervalUnit)
        assertEquals(true, settings.autoSyncOnUnlock)
        assertEquals(SyncSettingsConflictStrategy.REMOTE_WINS, settings.conflictStrategy)
        assertEquals(true, settings.syncMasterKey)
        assertEquals("device-1", settings.deviceId)
        assertEquals(0, settings.lastSyncRevision)
        assertTrue(settings.logs.isEmpty())
        assertEquals("vault.sync.json", settings.objectStorageObjectKey)
    }

    @Test
    fun generatedDeviceIdUsesUnderscoreSeparator() {
        val deviceId = SyncSettings.generateDeviceId()

        assertFalse(deviceId.contains('-'))
        assertTrue(Regex("^[a-z0-9_]+$").matches(deviceId))
    }

    @Test
    fun jsonDecodeToleratesMissingAndUnknownValues() {
        val settings = SyncSettings.fromJson(
            JSONObject(
                """
                {
                  "providerType": "futureProvider",
                  "webdavUrl": "https://dav.example.com",
                  "conflictStrategy": "futureStrategy",
                  "lastRemoteFingerprint": "etag:remote-v1",
                  "logs": [
                    {
                      "timestamp": "2026-05-24T03:00:00Z",
                      "message": "done",
                      "level": "info"
                    }
                  ]
                }
                """.trimIndent()
            )
        )

        assertEquals(SyncProviderType.NONE, settings.providerType)
        assertEquals("https://dav.example.com", settings.webdavUrl)
        assertEquals("etag:remote-v1", settings.lastRemoteFingerprint)
        assertEquals("/vault.json", settings.webdavPath)
        assertEquals(SyncSettingsConflictStrategy.REMOTE_WINS, settings.conflictStrategy)
        assertEquals(true, settings.syncMasterKey)
        assertEquals(1, settings.logs.size)
        assertEquals("done", settings.logs.single().message)
    }

    @Test
    fun jsonDecodeSupportsSecondBasedInterval() {
        val settings = SyncSettings.fromJson(
            JSONObject(
                """
                {
                  "autoSyncIntervalValue": 30,
                  "autoSyncIntervalUnit": "seconds"
                }
                """.trimIndent()
            )
        )

        assertEquals(1, settings.autoSyncIntervalMinutes)
        assertEquals(30, settings.autoSyncIntervalValue)
        assertEquals(SyncIntervalUnit.SECONDS, settings.autoSyncIntervalUnit)
    }

    @Test
    fun jsonDecodeKeepsLegacyMinuteInterval() {
        val settings = SyncSettings.fromJson(
            JSONObject(
                """
                {
                  "autoSyncIntervalMinutes": 15
                }
                """.trimIndent()
            )
        )

        assertEquals(15, settings.autoSyncIntervalMinutes)
        assertEquals(15, settings.autoSyncIntervalValue)
        assertEquals(SyncIntervalUnit.MINUTES, settings.autoSyncIntervalUnit)
    }

    @Test
    fun jsonEncodeKeepsFlutterFieldNames() {
        val json = SyncSettings.defaults(deviceId = "device-1")
            .copy(
                autoSyncIntervalMinutes = 1,
                autoSyncIntervalValue = 30,
                autoSyncIntervalUnit = SyncIntervalUnit.SECONDS,
                objectStorageBucket = "vault",
                objectStorageEndpoint = "oss-cn-hangzhou.aliyuncs.com",
                objectStorageObjectKey = "sync/vault.json",
                lastRemoteFingerprint = "etag:remote-v1",
            )
            .toJson()

        assertEquals("none", json.getString("providerType"))
        assertEquals("/vault.json", json.getString("webdavPath"))
        assertEquals(1, json.getInt("autoSyncIntervalMinutes"))
        assertEquals(30, json.getInt("autoSyncIntervalValue"))
        assertEquals("seconds", json.getString("autoSyncIntervalUnit"))
        assertEquals("vault", json.getString("objectStorageBucket"))
        assertEquals("oss-cn-hangzhou.aliyuncs.com", json.getString("objectStorageEndpoint"))
        assertEquals("sync/vault.json", json.getString("objectStorageObjectKey"))
        assertEquals("etag:remote-v1", json.getString("lastRemoteFingerprint"))
        assertEquals("remoteWins", json.getString("conflictStrategy"))
        assertEquals(true, json.getBoolean("syncMasterKey"))
    }

    @Test
    fun factoryValidatesProvidersAndBuildsConfiguredClients() {
        val transport = SyncSettingsFakeRemoteSyncTransport(
            responses = ArrayDeque(
                listOf(
                    Result.success(RemoteSyncHttpResponse(statusCode = 200, body = "{}")),
                    Result.success(RemoteSyncHttpResponse(statusCode = 201)),
                    Result.success(RemoteSyncHttpResponse(statusCode = 200, body = "{}")),
                )
            )
        )
        val factory = SyncClientFactory()
        val missing = factory.makeClient(SyncSettings.defaults(deviceId = "device-1"), transport)
        val webdav = factory.makeClient(
            SyncSettings.defaults(deviceId = "device-1").copy(
                providerType = SyncProviderType.WEBDAV,
                webdavUrl = " https://dav.example.com/root/ ",
                webdavPath = " vault.json ",
                webdavUsername = " alice ",
                webdavPassword = " secret ",
            ),
            transport,
        )
        val presigned = factory.makeClient(
            SyncSettings.defaults(deviceId = "device-1").copy(
                providerType = SyncProviderType.S3_PRESIGNED,
                presignedUploadUrl = "https://upload.example.com/vault",
            ),
            transport,
        )
        val cos = factory.makeClient(
            SyncSettings.defaults(deviceId = "device-1").copy(
                providerType = SyncProviderType.TENCENT_COS,
                objectStorageAccessKeyId = "ak",
                objectStorageSecretAccessKey = "sk",
                objectStorageBucket = "vault",
                objectStorageEndpoint = "cos.ap-shanghai.myqcloud.com",
                objectStorageAppId = "1250000000",
                objectStorageObjectKey = "prod/vault.json",
            ),
            transport,
        )

        assertNull(missing)
        assertNotNull(webdav)
        assertNotNull(presigned)
        assertNotNull(cos)
        assertEquals(RemoteSyncResult(payload = "{}", statusCode = 200), webdav.download())
        assertEquals(RemoteSyncResult(payload = null, statusCode = 201), presigned.upload("{}"))
        assertEquals(RemoteSyncResult(payload = "{}", statusCode = 200), cos.download())
        assertEquals("https://dav.example.com/root/vault.json", transport.requests[0].url.toString())
        assertEquals("Basic YWxpY2U6c2VjcmV0", transport.requests[0].headers["Authorization"])
        assertEquals("https://upload.example.com/vault", transport.requests[1].url.toString())
        assertEquals("https://vault-1250000000.cos.ap-shanghai.myqcloud.com/prod/vault.json", transport.requests[2].url.toString())
        assertTrue(transport.requests[2].headers["Authorization"].orEmpty().contains("q-sign-algorithm=sha1"))
    }

    @Test
    fun repositoryStoresSecretsOutsidePlaintextSettingsFile() {
        val directory = createTempDirectory("PasswordManagerAndroidSyncSettingsTests").toFile()
        try {
            val secretStore = InMemorySyncSecretStore()
            val repository = SyncSettingsRepository(
                settingsFile = File(directory, "sync_settings.json"),
                secretStore = secretStore,
            )
            val settings = SyncSettings.defaults(deviceId = "device-1").copy(
                providerType = SyncProviderType.WEBDAV,
                webdavUrl = "https://dav.example.com/root",
                webdavUsername = "alice",
                webdavPassword = "webdav-password",
                presignedDownloadUrl = "https://download.example.com/vault",
                presignedUploadUrl = "https://upload.example.com/vault",
                objectStorageAccessKeyId = "object-ak",
                objectStorageSecretAccessKey = "object-sk",
                objectStorageBucket = "vault",
                objectStorageEndpoint = "oss-cn-hangzhou.aliyuncs.com",
            )

            repository.save(settings)

            val rawFile = repository.rawSettingsFile()!!
            assertTrue(rawFile.contains("\"providerType\": \"webdav\""))
            assertTrue(rawFile.contains("\"webdavUsername\": \"alice\""))
            assertFalse(rawFile.contains("webdav-password"))
            assertFalse(rawFile.contains("https://download.example.com/vault"))
            assertFalse(rawFile.contains("https://upload.example.com/vault"))
            assertFalse(rawFile.contains("object-ak"))
            assertFalse(rawFile.contains("object-sk"))
            assertTrue(rawFile.contains("\"objectStorageBucket\": \"vault\""))
            assertTrue(rawFile.contains("\"objectStorageEndpoint\": \"oss-cn-hangzhou.aliyuncs.com\""))
            assertEquals(settings.syncSecrets, secretStore.load("device-1"))
            assertEquals(settings, repository.load())

            repository.delete()
            assertNull(repository.rawSettingsFile())
            assertEquals(SyncSecretBundle.EMPTY, secretStore.load("device-1"))
        } finally {
            directory.deleteRecursively()
        }
    }
}

private class SyncSettingsFakeRemoteSyncTransport(
    private val responses: ArrayDeque<Result<RemoteSyncHttpResponse>>,
) : RemoteSyncHttpTransport {
    val requests = mutableListOf<RemoteSyncRequest>()

    override fun perform(request: RemoteSyncRequest): RemoteSyncHttpResponse {
        requests += request
        if (responses.isEmpty()) {
            throw IllegalStateException("No fake response configured.")
        }
        return responses.removeFirst().getOrThrow()
    }
}
