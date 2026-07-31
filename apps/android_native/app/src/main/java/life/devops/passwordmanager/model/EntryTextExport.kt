package life.devops.passwordmanager.model

internal data class EntryTextExportField(
    val id: String,
    val title: String,
)

internal fun VaultEntry.selectedFieldsText(
    fields: List<EntryTextExportField>,
    categoryTemplates: Collection<CategoryTemplate>,
    entries: Collection<VaultEntry>,
): String =
    fields.joinToString("\n") { field ->
        "${field.title.exportLineEscaped()}: ${exportValue(field.id, categoryTemplates, entries).exportLineEscaped()}"
    }

private fun VaultEntry.exportValue(
    fieldId: String,
    categoryTemplates: Collection<CategoryTemplate>,
    entries: Collection<VaultEntry>,
): String {
    when (fieldId) {
        "label" -> return label
        "category" -> return payload.category
        "tags" -> return payload.tags.joinToString(", ")
    }

    when (val entryPayload = payload) {
        is VaultPayload.Credential -> when (fieldId) {
            "credential.username" -> return entryPayload.value.username
            "credential.password" -> return entryPayload.value.password
            "credential.accounts" -> return entryPayload.value.accounts.exportText()
            "credential.token" -> return entryPayload.value.token
            "credential.appId" -> return entryPayload.value.appId
            "credential.accessKey" -> return entryPayload.value.accessKey
            "credential.secretKey" -> return entryPayload.value.secretKey
            "credential.notes" -> return entryPayload.value.notes
        }
        is VaultPayload.Server -> when (fieldId) {
            "server.name" -> return entryPayload.value.name
            "server.ipAddress" -> return entryPayload.value.ipAddress
            "server.port" -> return entryPayload.value.port
            "server.username" -> return entryPayload.value.username
            "server.password" -> return entryPayload.value.password
            "server.accounts" -> return entryPayload.value.accounts.exportText()
            "server.basicConfig" -> return entryPayload.value.basicConfig
            "server.operatingSystem" -> return entryPayload.value.operatingSystem
            "server.location" -> return entryPayload.value.location
            "server.notes" -> return entryPayload.value.notes
        }
        is VaultPayload.Service -> when (fieldId) {
            "service.name" -> return entryPayload.value.name
            "service.connectionAddress" -> return entryPayload.value.connectionAddress
            "service.connectionPort" -> return entryPayload.value.connectionPort
            "service.accountId" -> return referencedEntryText(entryPayload.value.accountId, entries)
            "service.serverIds" -> return entryPayload.value.serverIds
                .joinToString(", ") { referencedEntryText(it, entries) }
            "service.accounts" -> return entryPayload.value.accounts.exportText()
            "service.notes" -> return entryPayload.value.notes
        }
    }

    if (!fieldId.startsWith("custom.")) return ""
    val customFieldId = fieldId.removePrefix("custom.")
    val field = customFields.firstOrNull { it.id == customFieldId } ?: return ""
    resolveFieldReference(
        field = field,
        sourceTemplate = categoryTemplates.firstOrNull {
            it.category.equals(payload.category, ignoreCase = true)
        },
        categoryTemplates = categoryTemplates,
        entries = entries,
    )?.let { return it.exportText() }
    resolveEntryReference(
        field = field,
        template = categoryTemplates.firstOrNull {
            it.category.equals(payload.category, ignoreCase = true)
        },
        entries = entries.toList(),
    )?.let { return it.exportText() }
    return field.value
}

private fun List<ServiceAccount>.exportText(): String =
    joinToString(", ") { account ->
        val note = account.note.takeIf { it.isNotEmpty() }?.let { " - $it" }.orEmpty()
        "${account.username}: ${account.password}$note"
    }

private fun referencedEntryText(id: String?, entries: Collection<VaultEntry>): String {
    if (id.isNullOrBlank()) return ""
    val target = entries.firstOrNull { it.id == id } ?: return "Referenced entry is unavailable."
    if (target.isDeleted) return "Referenced entry was deleted."
    return target.label.ifBlank { "Untitled" }
}

private fun EntryReferenceResolution.exportText(): String =
    when (status) {
        EntryReferenceStatus.EMPTY -> "No entry selected."
        EntryReferenceStatus.RESOLVED -> target?.label?.ifBlank { "Untitled" }
            ?: "Referenced entry is unavailable."
        EntryReferenceStatus.MISSING -> "Referenced entry is unavailable."
        EntryReferenceStatus.DELETED -> "Referenced entry was deleted."
        EntryReferenceStatus.CATEGORY_MISMATCH -> "Referenced entry is outside the target category."
    }

private fun FieldReferenceResolution.exportText(): String =
    when (status) {
        FieldReferenceStatus.EMPTY -> "No entry selected."
        FieldReferenceStatus.INVALID_CONFIGURATION -> "Field reference configuration needs repair."
        FieldReferenceStatus.MISSING -> "Referenced entry is unavailable."
        FieldReferenceStatus.DELETED -> "Referenced entry was deleted."
        FieldReferenceStatus.CATEGORY_MISMATCH -> "Referenced entry is outside the target category."
        FieldReferenceStatus.TARGET_FIELD_MISSING -> "Target field is no longer available."
        FieldReferenceStatus.TARGET_FIELD_UNSUPPORTED -> "Target field is not a text field."
        FieldReferenceStatus.TARGET_FIELD_EMPTY -> "Target field is empty."
        FieldReferenceStatus.RESOLVED -> {
            val targetLabel = targetEntry?.label?.ifBlank { "Untitled" }
                ?: return "Referenced entry is unavailable."
            "$targetLabel: ${targetField?.value.orEmpty()}"
        }
    }

private fun String.exportLineEscaped(): String =
    replace("\r\n", "\\n")
        .replace("\r", "\\n")
        .replace("\n", "\\n")
