package life.devops.passwordmanager.store

import android.content.Context
import life.devops.passwordmanager.model.CategoryTemplate
import life.devops.passwordmanager.model.ScopedVaultExport
import life.devops.passwordmanager.model.VaultEntry
import life.devops.passwordmanager.model.VaultPersistenceEnvelope
import life.devops.passwordmanager.model.VaultSnapshot
import life.devops.passwordmanager.model.safeExportName
import java.io.File
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

class FileVaultRepository(private val baseDirectory: File) {

    private val vaultFile: File
        get() = File(baseDirectory, "vault.json")
    private val backupsDirectory: File
        get() = File(baseDirectory, "backups").apply { mkdirs() }
    private val exportsDirectory: File
        get() = File(baseDirectory, "exports").apply { mkdirs() }
    private val importsDirectory: File
        get() = File(baseDirectory, "imports").apply { mkdirs() }

    fun loadEnvelope(): VaultPersistenceEnvelope? {
        if (!vaultFile.exists()) return null
        return VaultJson.decodeEnvelope(vaultFile.readText())
    }

    fun saveEnvelope(envelope: VaultPersistenceEnvelope) {
        val tempFile = File(vaultFile.parentFile, "${vaultFile.name}.tmp")
        tempFile.writeText(VaultJson.encodeEnvelope(envelope))
        if (!tempFile.renameTo(vaultFile)) {
            tempFile.copyTo(vaultFile, overwrite = true)
            tempFile.delete()
        }
    }

    fun createBackup(at: Instant = Instant.now()): File {
        require(vaultFile.exists()) { "Vault has not been initialized." }
        val backupFile = File(backupsDirectory, "vault-${backupTimestamp.format(at)}.json")
        vaultFile.copyTo(backupFile, overwrite = true)
        pruneBackups()
        return backupFile
    }

    fun restoreLatestBackup(): File {
        val backupFile = listBackups().firstOrNull()
            ?: throw IllegalStateException("No local backup is available.")
        backupFile.copyTo(vaultFile, overwrite = true)
        return backupFile
    }

    fun restoreBackup(fileName: String): File {
        val sanitizedName = File(fileName).name
        val backupFile = File(backupsDirectory, sanitizedName)
        require(backupFile.isFile && backupFile.name.matches(backupNamePattern)) {
            "Backup file is not available."
        }
        backupFile.copyTo(vaultFile, overwrite = true)
        return backupFile
    }

    fun listBackups(): List<File> =
        backupsDirectory
            .listFiles { file -> file.isFile && file.name.matches(backupNamePattern) }
            .orEmpty()
            .sortedByDescending { it.name }

    fun saveSnapshotExport(snapshot: VaultSnapshot, at: Instant = Instant.now()): File {
        val exportFile = File(exportsDirectory, "vault-export-${backupTimestamp.format(at)}.json")
        exportFile.writeText(VaultJson.encodeSnapshot(snapshot))
        return exportFile
    }

    fun saveEntryExport(
        entry: VaultEntry,
        categoryTemplates: List<CategoryTemplate>,
        at: Instant = Instant.now(),
    ): File {
        val exportFile = File(
            exportsDirectory,
            "entry-export-${entry.safeExportName}-${backupTimestamp.format(at)}.json",
        )
        exportFile.writeText(
            VaultJson.encodeScopedExport(
                ScopedVaultExport(
                    scope = life.devops.passwordmanager.model.ScopedExportScope.ITEM,
                    exportedAt = at,
                    item = entry,
                    category = null,
                    items = null,
                    categoryTemplates = categoryTemplates,
                )
            )
        )
        return exportFile
    }

    fun saveCategoryExport(
        category: String,
        entries: List<VaultEntry>,
        categoryTemplates: List<CategoryTemplate>,
        at: Instant = Instant.now(),
    ): File {
        val exportFile = File(
            exportsDirectory,
            "category-export-${category.safeExportName}-${backupTimestamp.format(at)}.json",
        )
        exportFile.writeText(
            VaultJson.encodeScopedExport(
                ScopedVaultExport(
                    scope = life.devops.passwordmanager.model.ScopedExportScope.CATEGORY,
                    exportedAt = at,
                    item = null,
                    category = category,
                    items = entries,
                    categoryTemplates = categoryTemplates,
                )
            )
        )
        return exportFile
    }

    fun loadSnapshotImport(fileName: String): VaultSnapshot {
        val sanitizedName = File(fileName).name
        val importFile = File(importsDirectory, sanitizedName)
        return VaultJson.decodeSnapshot(importFile.readText())
    }

    fun loadScopedImport(fileName: String): ScopedVaultExport {
        val sanitizedName = File(fileName).name
        val importFile = File(importsDirectory, sanitizedName)
        return VaultJson.decodeScopedExport(importFile.readText())
    }

    fun importsDirectory(): File = importsDirectory

    fun encodeSnapshot(snapshot: VaultSnapshot): ByteArray =
        VaultJson.encodeSnapshot(snapshot).toByteArray(Charsets.UTF_8)

    fun decodeSnapshot(bytes: ByteArray): VaultSnapshot =
        VaultJson.decodeSnapshot(bytes.toString(Charsets.UTF_8))

    companion object {
        const val BACKUP_RETENTION_COUNT = 5
        private val backupNamePattern = Regex("""vault-\d{8}-\d{6}\.json""")
        private val backupTimestamp: DateTimeFormatter = DateTimeFormatter
            .ofPattern("yyyyMMdd-HHmmss")
            .withZone(ZoneOffset.UTC)

        fun fromContext(context: Context): FileVaultRepository =
            FileVaultRepository(context.filesDir)
    }

    private fun pruneBackups() {
        listBackups()
            .drop(BACKUP_RETENTION_COUNT)
            .forEach { it.delete() }
    }
}
