package life.devops.passwordmanager.store

import life.devops.passwordmanager.model.EncryptedPayloadRecord
import life.devops.passwordmanager.model.MasterKeyRecord
import life.devops.passwordmanager.model.CategoryTemplate
import life.devops.passwordmanager.model.CredentialPayload
import life.devops.passwordmanager.model.FieldTemplate
import life.devops.passwordmanager.model.ScopedExportScope
import life.devops.passwordmanager.model.SecuritySettings
import life.devops.passwordmanager.model.VaultEntry
import life.devops.passwordmanager.model.VaultEntryType
import life.devops.passwordmanager.model.VaultPayload
import life.devops.passwordmanager.model.VaultPersistenceEnvelope
import life.devops.passwordmanager.model.VaultSnapshot
import java.io.File
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class FileVaultRepositoryTest {
    @Test
    fun backupCopiesEncryptedVaultEnvelope() {
        val directory = kotlin.io.path.createTempDirectory("PasswordManagerAndroidBackupTests").toFile()
        try {
            val repository = FileVaultRepository(directory)
            val envelope = VaultPersistenceEnvelope(
                schemaVersion = 1,
                masterKeyRecord = MasterKeyRecord(
                    saltBase64 = "salt",
                    iterations = 600_000,
                    verifierBase64 = "verifier",
                ),
                encryptedVault = EncryptedPayloadRecord(
                    ciphertext = "ciphertext",
                    nonce = "nonce",
                    mac = "mac",
                    version = 1,
                ),
                updatedAt = Instant.parse("2023-11-14T22:13:20Z"),
            )
            repository.saveEnvelope(envelope)

            val backupFile = repository.createBackup(Instant.parse("2023-11-14T22:13:21Z"))

            assertEquals("vault-20231114-221321.json", backupFile.name)
            assertTrue(backupFile.exists())
            assertEquals(File(directory, "vault.json").readText(), backupFile.readText())
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun backupRetentionKeepsNewestFiveBackups() {
        val directory = kotlin.io.path.createTempDirectory("PasswordManagerAndroidBackupRetentionTests").toFile()
        try {
            val repository = FileVaultRepository(directory)
            repository.saveEnvelope(
                VaultPersistenceEnvelope(
                    schemaVersion = 1,
                    masterKeyRecord = MasterKeyRecord(
                        saltBase64 = "salt",
                        iterations = 600_000,
                        verifierBase64 = "verifier",
                    ),
                    encryptedVault = EncryptedPayloadRecord(
                        ciphertext = "ciphertext",
                        nonce = "nonce",
                        mac = "mac",
                        version = 1,
                    ),
                    updatedAt = Instant.parse("2023-11-14T22:13:20Z"),
                )
            )

            repeat(7) { index ->
                repository.createBackup(Instant.parse("2023-11-14T22:13:2${index}Z"))
            }

            val backupNames = repository.listBackups().map { it.name }

            assertEquals(FileVaultRepository.BACKUP_RETENTION_COUNT, backupNames.size)
            assertEquals(
                listOf(
                    "vault-20231114-221326.json",
                    "vault-20231114-221325.json",
                    "vault-20231114-221324.json",
                    "vault-20231114-221323.json",
                    "vault-20231114-221322.json",
                ),
                backupNames,
            )
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun restoreLatestBackupReplacesCurrentVaultEnvelope() {
        val directory = kotlin.io.path.createTempDirectory("PasswordManagerAndroidRestoreBackupTests").toFile()
        try {
            val repository = FileVaultRepository(directory)
            fun envelope(ciphertext: String) = VaultPersistenceEnvelope(
                schemaVersion = 1,
                masterKeyRecord = MasterKeyRecord(
                    saltBase64 = "salt",
                    iterations = 600_000,
                    verifierBase64 = "verifier",
                ),
                encryptedVault = EncryptedPayloadRecord(
                    ciphertext = ciphertext,
                    nonce = "nonce",
                    mac = "mac",
                    version = 1,
                ),
                updatedAt = Instant.parse("2023-11-14T22:13:20Z"),
            )

            repository.saveEnvelope(envelope("oldest"))
            repository.createBackup(Instant.parse("2023-11-14T22:13:21Z"))
            repository.saveEnvelope(envelope("newest"))
            val newestBackup = repository.createBackup(Instant.parse("2023-11-14T22:13:22Z"))
            repository.saveEnvelope(envelope("current"))

            val restored = repository.restoreLatestBackup()

            assertEquals(newestBackup.name, restored.name)
            assertEquals(newestBackup.readText(), File(directory, "vault.json").readText())
            assertEquals("newest", repository.loadEnvelope()?.encryptedVault?.ciphertext)
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun snapshotExportImportRoundTripsThroughLocalDirectories() {
        val directory = kotlin.io.path.createTempDirectory("PasswordManagerAndroidImportExportTests").toFile()
        try {
            val repository = FileVaultRepository(directory)
            val snapshot = VaultSnapshot(
                entries = listOf(
                    VaultEntry(
                        id = "11111111-2222-3333-4444-555555555555",
                        label = "Imported Email",
                        type = VaultEntryType.CREDENTIAL,
                        payload = VaultPayload.Credential(
                            CredentialPayload(
                                username = "import@example.com",
                                password = "secret",
                                tags = listOf("import"),
                                category = "Imports",
                            )
                        ),
                    )
                ),
                categories = listOf("Imports"),
                tags = listOf("import"),
                security = SecuritySettings(requireTotp = true, totpSecret = "JBSWY3DPEHPK3PXP"),
                syncStatus = "Idle",
                backupStatus = "No backup has run",
                updatedAt = Instant.parse("2023-11-14T22:13:20Z"),
            )

            val exportFile = repository.saveSnapshotExport(
                snapshot,
                Instant.parse("2023-11-14T22:13:21Z"),
            )
            exportFile.copyTo(File(repository.importsDirectory(), exportFile.name))

            val imported = repository.loadSnapshotImport(exportFile.name)

            assertEquals("vault-export-20231114-221321.json", exportFile.name)
            assertEquals(1, imported.entries.size)
            assertEquals("Imported Email", imported.entries.first().label)
            assertTrue(imported.security.requireTotp)
            assertEquals("JBSWY3DPEHPK3PXP", imported.security.totpSecret)
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun scopedEntryAndCategoryExportsDecodeFromImports() {
        val directory = kotlin.io.path.createTempDirectory("PasswordManagerAndroidScopedExportTests").toFile()
        try {
            val repository = FileVaultRepository(directory)
            val entry = VaultEntry(
                id = "11111111-2222-3333-4444-555555555555",
                label = "Scoped Email",
                type = VaultEntryType.CREDENTIAL,
                payload = VaultPayload.Credential(
                    CredentialPayload(
                        username = "scoped@example.com",
                        password = "secret",
                        category = "Scoped",
                    )
                ),
            )
            val template = CategoryTemplate(
                category = "Scoped",
                fields = listOf(
                    FieldTemplate(
                        id = "template-owner",
                        name = "Owner",
                        valueType = "entryReference",
                        targetCategory = "Accounts",
                    )
                ),
            )

            val entryExportFile = repository.saveEntryExport(
                entry = entry,
                categoryTemplates = listOf(template),
                at = Instant.parse("2023-11-14T22:13:21Z"),
            )
            val categoryExportFile = repository.saveCategoryExport(
                category = "Scoped",
                entries = listOf(entry),
                categoryTemplates = listOf(template),
                at = Instant.parse("2023-11-14T22:13:22Z"),
            )
            entryExportFile.copyTo(File(repository.importsDirectory(), entryExportFile.name))
            categoryExportFile.copyTo(File(repository.importsDirectory(), categoryExportFile.name))

            val entryImport = repository.loadScopedImport(entryExportFile.name)
            val categoryImport = repository.loadScopedImport(categoryExportFile.name)

            assertEquals("entry-export-Scoped_Email-20231114-221321.json", entryExportFile.name)
            assertEquals("category-export-Scoped-20231114-221322.json", categoryExportFile.name)
            assertEquals(ScopedExportScope.ITEM, entryImport.scope)
            assertEquals(2, entryImport.version)
            assertEquals("Scoped Email", entryImport.item?.label)
            assertEquals(listOf(template), entryImport.categoryTemplates)
            assertEquals(ScopedExportScope.CATEGORY, categoryImport.scope)
            assertEquals(2, categoryImport.version)
            assertEquals("Scoped", categoryImport.category)
            assertEquals(1, categoryImport.items?.size)
            assertEquals(listOf(template), categoryImport.categoryTemplates)
        } finally {
            directory.deleteRecursively()
        }
    }
}
