package com.example.passwordmanagernative.store

import com.example.passwordmanagernative.model.EncryptedPayloadRecord
import com.example.passwordmanagernative.model.MasterKeyRecord
import com.example.passwordmanagernative.model.VaultEntryType
import com.example.passwordmanagernative.model.VaultPayload
import org.json.JSONObject
import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class DartCompatibilityFixtureTest {
    private val crypto = AndroidVaultCrypto()

    @Test
    fun androidDerivesAndDecryptsFixtureGeneratedByPackagesCrypto() {
        val fixture = loadFixture()
        val derivedKey = crypto.verify(
            fixture.password,
            MasterKeyRecord(
                saltBase64 = fixture.saltBase64,
                iterations = fixture.iterations,
                verifierBase64 = fixture.derivedKeyBase64,
                metadataSaltBase64 = fixture.metadataSaltBase64,
                metadataIterations = fixture.iterations,
            ),
        )
        val metadataKey = crypto.verify(
            fixture.password,
            MasterKeyRecord(
                saltBase64 = fixture.metadataSaltBase64,
                iterations = fixture.iterations,
                verifierBase64 = fixture.metadataDerivedKeyBase64,
            ),
        )
        val plaintext = crypto.decrypt(fixture.encryptedPayload, derivedKey)
        val plaintextString = plaintext.toString(Charsets.UTF_8)
        val snapshot = VaultJson.decodeSnapshot(plaintextString)
        val credentialEntry = assertNotNull(
            snapshot.entries.firstOrNull { it.type == VaultEntryType.CREDENTIAL && !it.isDeleted }
        )
        val serverEntry = assertNotNull(snapshot.entries.firstOrNull { it.type == VaultEntryType.SERVER })
        val serviceEntry = assertNotNull(snapshot.entries.firstOrNull { it.type == VaultEntryType.SERVICE })
        val tombstoneEntry = assertNotNull(snapshot.entries.firstOrNull { it.isDeleted })

        assertEquals(AndroidVaultCrypto.DEFAULT_ITERATIONS, fixture.iterations)
        assertContentEquals(Base64.getDecoder().decode(fixture.derivedKeyBase64), derivedKey)
        assertContentEquals(Base64.getDecoder().decode(fixture.metadataDerivedKeyBase64), metadataKey)
        assertEquals(fixture.plaintextUtf8, plaintextString)
        assertEquals(4, snapshot.entries.size)
        assertEquals(listOf("Archive", "Compatibility", "Infrastructure", "Services"), snapshot.categories)
        assertEquals(listOf("dart", "deleted", "fixture", "ops", "prod", "server", "service"), snapshot.tags)
        assertTrue(snapshot.security.requireTotp)
        assertEquals("JBSWY3DPEHPK3PXP", snapshot.security.totpSecret)
        assertEquals("Fixture sync idle", snapshot.syncStatus)
        assertEquals("No backup has run", snapshot.backupStatus)

        assertEquals("11111111-2222-3333-4444-555555555555", credentialEntry.id)
        assertEquals("Dart Fixture Credential", credentialEntry.label)
        assertEquals("Compatibility", credentialEntry.payload.category)
        assertEquals(listOf("fixture", "dart"), credentialEntry.payload.tags)
        assertEquals(mapOf("dart-fixture" to 1), credentialEntry.version)
        assertEquals("dart-fixture", credentialEntry.updatedBy)
        val credential = (credentialEntry.payload as VaultPayload.Credential).value
        assertEquals("fixture-user", credential.username)
        assertEquals("fixture-password", credential.password)
        assertEquals("fixture-token", credential.token)
        assertEquals("fixture-app", credential.appId)
        assertEquals("fixture-access-key", credential.accessKey)
        assertEquals("fixture-secret-key", credential.secretKey)
        assertEquals("fixture-note", credential.notes)

        assertEquals("22222222-3333-4444-5555-666666666666", serverEntry.id)
        assertEquals("Dart Fixture Server", serverEntry.label)
        assertEquals("Infrastructure", serverEntry.payload.category)
        assertEquals(listOf("server", "ops"), serverEntry.payload.tags)
        val server = (serverEntry.payload as VaultPayload.Server).value
        assertEquals("fixture-server", server.name)
        assertEquals("10.0.0.12", server.ipAddress)
        assertEquals("22", server.port)
        assertEquals("root", server.username)
        assertEquals("server-password", server.password)
        assertEquals("2CPU 4GB", server.basicConfig)
        assertEquals("Ubuntu 24.04", server.operatingSystem)
        assertEquals("rack-a", server.location)
        assertEquals("server-note", server.notes)
        assertEquals("11111111-2222-3333-4444-555555555555", server.accountId)

        assertEquals("33333333-4444-5555-6666-777777777777", serviceEntry.id)
        assertEquals("Dart Fixture Service", serviceEntry.label)
        assertEquals("Services", serviceEntry.payload.category)
        assertEquals(listOf("service", "prod"), serviceEntry.payload.tags)
        val service = (serviceEntry.payload as VaultPayload.Service).value
        assertEquals("fixture-service", service.name)
        assertEquals("service.internal", service.connectionAddress)
        assertEquals("443", service.connectionPort)
        assertEquals("11111111-2222-3333-4444-555555555555", service.accountId)
        assertEquals(listOf("22222222-3333-4444-5555-666666666666"), service.serverIds)
        assertEquals(1, service.accounts.size)
        assertEquals("svc-admin", service.accounts.first().username)
        assertEquals("svc-password", service.accounts.first().password)
        assertEquals("primary service account", service.accounts.first().note)
        assertEquals("service-note", service.notes)

        assertEquals("44444444-5555-6666-7777-888888888888", tombstoneEntry.id)
        assertEquals("Dart Fixture Tombstone", tombstoneEntry.label)
        assertTrue(tombstoneEntry.isDeleted)
        assertNotNull(tombstoneEntry.deletedAt)
        assertEquals(mapOf("dart-fixture" to 4), tombstoneEntry.version)
    }

    private fun loadFixture(): DartCryptoFixture {
        val stream = assertNotNull(
            javaClass.classLoader?.getResourceAsStream("fixtures/dart_crypto_fixture.json")
        )
        val json = JSONObject(stream.bufferedReader().use { it.readText() })
        val encryptedPayload = json.getJSONObject("encryptedPayload")
        return DartCryptoFixture(
            password = json.getString("password"),
            iterations = json.getInt("iterations"),
            saltBase64 = json.getString("saltBase64"),
            metadataSaltBase64 = json.getString("metadataSaltBase64"),
            derivedKeyBase64 = json.getString("derivedKeyBase64"),
            metadataDerivedKeyBase64 = json.getString("metadataDerivedKeyBase64"),
            plaintextUtf8 = json.getString("plaintextUtf8"),
            encryptedPayload = EncryptedPayloadRecord(
                ciphertext = encryptedPayload.getString("ciphertext"),
                nonce = encryptedPayload.getString("nonce"),
                mac = encryptedPayload.getString("mac"),
                version = encryptedPayload.getInt("version"),
            ),
        )
    }
}

private data class DartCryptoFixture(
    val password: String,
    val iterations: Int,
    val saltBase64: String,
    val metadataSaltBase64: String,
    val derivedKeyBase64: String,
    val metadataDerivedKeyBase64: String,
    val plaintextUtf8: String,
    val encryptedPayload: EncryptedPayloadRecord,
)
