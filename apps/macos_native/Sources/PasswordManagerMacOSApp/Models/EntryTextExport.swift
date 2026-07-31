import Foundation

extension VaultEntry {
    func selectedFieldsText(
        selectedFieldIDs: Set<String>,
        categoryTemplates: [CategoryTemplate],
        entries: [VaultEntry]
    ) -> String {
        exportFields
            .filter { selectedFieldIDs.contains($0.id) }
            .map { field in
                "\(field.title.exportLineEscaped): \(exportValue(for: field.id, categoryTemplates: categoryTemplates, entries: entries).exportLineEscaped)"
            }
            .joined(separator: "\n")
    }

    private func exportValue(
        for fieldID: String,
        categoryTemplates: [CategoryTemplate],
        entries: [VaultEntry]
    ) -> String {
        switch fieldID {
        case "label":
            return label
        case "category":
            return payload.category
        case "tags":
            return payload.tags.joined(separator: ", ")
        default:
            break
        }

        switch payload {
        case .credential(let credential):
            switch fieldID {
            case "credential.username": return credential.username
            case "credential.password": return credential.password
            case "credential.accounts": return credential.accounts.exportText
            case "credential.token": return credential.token
            case "credential.appId": return credential.appId
            case "credential.accessKey": return credential.accessKey
            case "credential.secretKey": return credential.secretKey
            case "credential.notes": return credential.notes
            default: break
            }
        case .server(let server):
            switch fieldID {
            case "server.name": return server.name
            case "server.ipAddress": return server.ipAddress
            case "server.port": return server.port
            case "server.username": return server.username
            case "server.password": return server.password
            case "server.accounts": return server.accounts.exportText
            case "server.accountId": return referencedEntryText(server.accountId, entries: entries)
            case "server.basicConfig": return server.basicConfig
            case "server.operatingSystem": return server.operatingSystem
            case "server.location": return server.location
            case "server.notes": return server.notes
            default: break
            }
        case .service(let service):
            switch fieldID {
            case "service.name": return service.name
            case "service.connectionAddress": return service.connectionAddress
            case "service.connectionPort": return service.connectionPort
            case "service.accountId": return referencedEntryText(service.accountId, entries: entries)
            case "service.serverIds":
                return service.serverIds.map { referencedEntryText($0, entries: entries) }.joined(separator: ", ")
            case "service.accounts": return service.accounts.exportText
            case "service.notes": return service.notes
            default: break
            }
        }

        guard fieldID.hasPrefix("custom.") else { return "" }
        let customFieldID = String(fieldID.dropFirst("custom.".count))
        guard let field = customFields.first(where: { $0.id == customFieldID }) else { return "" }

        if let resolution = resolveFieldReference(
            sourceEntry: self,
            field: field,
            categoryTemplates: categoryTemplates,
            entries: entries
        ) {
            return fieldReferenceExportText(resolution)
        }

        let sourceTemplate = categoryTemplates.first {
            $0.category.caseInsensitiveCompare(payload.category) == .orderedSame
        }
        if let resolution = resolveEntryReference(
            field: field,
            template: sourceTemplate,
            entries: entries
        ) {
            return entryReferenceExportText(resolution)
        }
        return field.value
    }

    private func referencedEntryText(_ id: String?, entries: [VaultEntry]) -> String {
        guard let id, !id.isEmpty else { return "" }
        guard let target = entries.first(where: { $0.id == id }) else {
            return L10n.t("Referenced entry is unavailable.")
        }
        guard !target.isDeleted else { return L10n.t("Referenced entry was deleted.") }
        return target.label.isEmpty ? L10n.t("Untitled") : target.label
    }
}

private extension Array where Element == ServiceAccount {
    var exportText: String {
        map { account in
            let note = account.note.isEmpty ? "" : " - \(account.note)"
            return "\(account.username): \(account.password)\(note)"
        }
        .joined(separator: ", ")
    }
}

private extension String {
    var exportLineEscaped: String {
        replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

private func entryReferenceExportText(_ resolution: EntryReferenceResolution) -> String {
    switch resolution.status {
    case .empty:
        return L10n.t("No entry selected.")
    case .resolved:
        guard let target = resolution.target else { return L10n.t("Referenced entry is unavailable.") }
        return target.label.isEmpty ? L10n.t("Untitled") : target.label
    case .missing:
        return L10n.t("Referenced entry is unavailable.")
    case .deleted:
        return L10n.t("Referenced entry was deleted.")
    case .categoryMismatch:
        return L10n.t("Referenced entry is outside the target category.")
    }
}

private func fieldReferenceExportText(_ resolution: FieldReferenceResolution) -> String {
    switch resolution.status {
    case .empty:
        return L10n.t("No entry selected.")
    case .invalidConfiguration:
        return L10n.t("Field reference configuration needs repair.")
    case .missing:
        return L10n.t("Referenced entry is unavailable.")
    case .deleted:
        return L10n.t("Referenced entry was deleted.")
    case .categoryMismatch:
        return L10n.t("Referenced entry is outside the target category.")
    case .targetFieldMissing:
        return L10n.t("Target field is no longer available.")
    case .targetFieldUnsupported:
        return L10n.t("Target field is not a text field.")
    case .targetFieldEmpty:
        return L10n.t("Target field is empty.")
    case .resolved:
        guard let target = resolution.target else { return L10n.t("Referenced entry is unavailable.") }
        let label = target.entryLabel.isEmpty ? L10n.t("Untitled") : target.entryLabel
        return "\(label): \(target.fieldValue)"
    }
}
