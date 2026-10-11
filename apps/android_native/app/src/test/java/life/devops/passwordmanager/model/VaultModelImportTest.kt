package life.devops.passwordmanager.model

import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals

class VaultModelImportTest {
    @Test
    fun safeExportNamesRemoveFilesystemAndWhitespaceSeparators() {
        assertEquals("Prod_Email", " Prod / Email ".safeExportName)
        assertEquals("untitled", " \n\t ".safeExportName)
    }

    @Test
    fun vaultEntryDefaultsUpdatedByWithoutHyphen() {
        val entry = VaultEntry(
            label = "Credential",
            type = VaultEntryType.CREDENTIAL,
            payload = VaultPayload.Credential(CredentialPayload()),
        )

        assertEquals("android", entry.updatedBy)
        assertFalse(entry.updatedBy.contains('-'))
    }

    @Test
    fun importMatchKeyUsesTypeLabelAndCategoryOnly() {
        val baseEntry = VaultEntry(
            id = "original",
            label = "Email",
            type = VaultEntryType.CREDENTIAL,
            payload = VaultPayload.Credential(CredentialPayload(category = "Personal")),
        )
        val matchingEntry = baseEntry.copy(
            id = "imported",
            label = " email ",
            payload = VaultPayload.Credential(CredentialPayload(category = " personal ")),
        )
        val differentCategory = baseEntry.copy(
            payload = VaultPayload.Credential(CredentialPayload(category = "Work")),
        )

        assertEquals(baseEntry.importMatchKey, matchingEntry.importMatchKey)
        assertNotEquals(baseEntry.importMatchKey, differentCategory.importMatchKey)
    }

    @Test
    fun copyForImportAssignsNewIdentityAndClearsTombstoneState() {
        val deletedEntry = VaultEntry(
            id = "deleted",
            label = "Deleted",
            type = VaultEntryType.CREDENTIAL,
            payload = VaultPayload.Credential(CredentialPayload()),
            isDeleted = true,
            deletedAt = Instant.parse("2026-05-23T00:09:00Z"),
        )

        val imported = deletedEntry.copyForImport(
            id = "new-id",
            updatedAt = Instant.parse("2026-05-24T00:00:00Z"),
        )

        assertEquals("new-id", imported.id)
        assertFalse(imported.isDeleted)
        assertEquals(null, imported.deletedAt)
        assertEquals(Instant.parse("2026-05-24T00:00:00Z"), imported.updatedAt)
    }
}
