package life.devops.passwordmanager.store

import life.devops.passwordmanager.model.CustomField
import life.devops.passwordmanager.model.EntryDraft
import life.devops.passwordmanager.model.ServerPayload
import life.devops.passwordmanager.model.ServicePayload
import life.devops.passwordmanager.model.VaultEntryType
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class VaultStoreSearchTest {
    @Test
    fun listEntriesSupportsStructuredKeyValueSearch() {
        val directory = createTempDirectory("PasswordManagerAndroidSearchTests").toFile()
        try {
            val store = VaultStore(repository = FileVaultRepository(directory))
            assertTrue(store.setupMasterPassword("test-password", "test-password"))
            val server = store.upsert(
                EntryDraft(
                    label = "Production Gateway",
                    type = VaultEntryType.SERVER,
                    category = "Infra",
                    tags = listOf("prod"),
                    customFields = listOf(CustomField(name = "Owner", value = "sre-team")),
                    server = ServerPayload(
                        name = "gateway-prod",
                        ipAddress = "1.2.3.4",
                        port = "22",
                        username = "root",
                    ),
                )
            )
            val service = store.upsert(
                EntryDraft(
                    label = "Billing Service",
                    type = VaultEntryType.SERVICE,
                    category = "Apps",
                    tags = listOf("billing"),
                    customFields = listOf(CustomField(name = "Region", value = "ap-south")),
                    service = ServicePayload(
                        name = "billing-api",
                        connectionAddress = "https://billing.example.com",
                        connectionPort = "443",
                    ),
                )
            )

            assertEquals(listOf(server.id), store.listEntries(query = "ip:1.2.3.4").map { it.id })
            assertEquals(listOf(service.id), store.listEntries(query = "name:billing-api").map { it.id })
            assertEquals(listOf(service.id), store.listEntries(query = "https://billing.example.com").map { it.id })
            assertEquals(listOf(server.id), store.listEntries(query = "owner:sre-team").map { it.id })
            assertEquals(listOf(service.id), store.listEntries(query = "region:ap-south").map { it.id })
            assertEquals(listOf(server.id), store.listEntries(query = "tag:prod ip:1.2.3.4").map { it.id })
            assertEquals(emptyList(), store.listEntries(query = "ip:9.9.9.9"))
        } finally {
            directory.deleteRecursively()
        }
    }
}
