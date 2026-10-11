import Foundation

enum EntryReferenceStatus: Equatable, Sendable {
    case empty
    case resolved
    case missing
    case deleted
    case categoryMismatch
}

struct EntryReferenceTarget: Equatable, Sendable {
    let id: String
    let label: String
    let category: String
}

struct EntryReferenceResolution: Equatable, Sendable {
    let status: EntryReferenceStatus
    let target: EntryReferenceTarget?

    init(status: EntryReferenceStatus, target: EntryReferenceTarget? = nil) {
        self.status = status
        self.target = target
    }
}

struct EntryReferenceCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let category: String
}

func propagateEntryReferenceCategoryRename(
    templates: [CategoryTemplate],
    from oldCategory: String,
    to newCategory: String
) -> [CategoryTemplate] {
    let oldNormalized = oldCategory.trimmingCharacters(in: .whitespacesAndNewlines)
    let newNormalized = newCategory.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !oldNormalized.isEmpty, !newNormalized.isEmpty else { return templates }

    return templates.map { template in
        var updatedTemplate = template
        updatedTemplate.fields = template.fields.map { field in
            guard field.valueType == "entryReference",
                  field.targetCategory.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(oldNormalized) == .orderedSame else {
                return field
            }
            var updatedField = field
            updatedField.targetCategory = newNormalized
            return updatedField
        }
        return updatedTemplate
    }
}

func resolveEntryReference(
    field: CustomField,
    template: CategoryTemplate?,
    entries: [VaultEntry]
) -> EntryReferenceResolution? {
    guard let templateField = matchingReferenceTemplateField(field: field, template: template),
          templateField.valueType == "entryReference" else {
        return nil
    }
    guard !field.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return EntryReferenceResolution(status: .empty)
    }
    guard let targetEntry = entries.first(where: { $0.id == field.value }) else {
        return EntryReferenceResolution(status: .missing)
    }

    let target = EntryReferenceTarget(
        id: targetEntry.id,
        label: targetEntry.label,
        category: targetEntry.payload.category.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    if targetEntry.isDeleted {
        return EntryReferenceResolution(status: .deleted, target: target)
    }

    let targetCategory = templateField.targetCategory.trimmingCharacters(in: .whitespacesAndNewlines)
    if !targetCategory.isEmpty,
       target.category.caseInsensitiveCompare(targetCategory) != .orderedSame {
        return EntryReferenceResolution(status: .categoryMismatch, target: target)
    }
    return EntryReferenceResolution(status: .resolved, target: target)
}

extension VaultEntry {
    func withEntryReferenceSearchProjection(
        template: CategoryTemplate?,
        entries: [VaultEntry]
    ) -> VaultEntry {
        var projectedEntry = self
        projectedEntry.customFields = customFields.map { field in
            switch customFieldSemantics(field: field, template: template).semantic {
            case .text:
                return field
            case .fieldReference, .unsupported:
                var projectedField = field
                projectedField.value = ""
                return projectedField
            case .entryReference:
                let resolution = resolveEntryReference(
                    field: field,
                    template: template,
                    entries: entries
                )
                var projectedField = field
                if resolution?.status == .resolved, let target = resolution?.target {
                    projectedField.value = [target.label, target.category]
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                } else {
                    projectedField.value = ""
                }
                return projectedField
            }
        }
        return projectedEntry
    }

    func remappingEntryReferenceIDs(
        using destinationIDsBySourceID: [String: String],
        template: CategoryTemplate?
    ) -> VaultEntry {
        var remappedEntry = self
        remappedEntry.customFields = customFields.map { field in
            guard resolveEntryReference(field: field, template: template, entries: []) != nil,
                  let destinationID = destinationIDsBySourceID[field.value] else {
                return field
            }
            var remappedField = field
            remappedField.value = destinationID
            return remappedField
        }
        return remappedEntry
    }
}

func entryReferenceCandidates(
    entries: [VaultEntry],
    targetCategory: String,
    query: String = ""
) -> [EntryReferenceCandidate] {
    let normalizedCategory = targetCategory.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return entries
        .lazy
        .filter { !$0.isDeleted }
        .map {
            EntryReferenceCandidate(
                id: $0.id,
                label: $0.label,
                category: $0.payload.category.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        .filter {
            normalizedCategory.isEmpty
                || $0.category.caseInsensitiveCompare(normalizedCategory) == .orderedSame
        }
        .filter {
            normalizedQuery.isEmpty
                || $0.label.localizedCaseInsensitiveContains(normalizedQuery)
                || $0.category.localizedCaseInsensitiveContains(normalizedQuery)
        }
        .sorted {
            let labelOrder = $0.label.localizedCaseInsensitiveCompare($1.label)
            if labelOrder != .orderedSame { return labelOrder == .orderedAscending }
            if $0.label != $1.label { return $0.label < $1.label }
            return $0.id < $1.id
        }
}

private func matchingReferenceTemplateField(
    field: CustomField,
    template: CategoryTemplate?
) -> FieldTemplate? {
    guard let fields = template?.fields else { return nil }
    if !field.templateFieldId.isEmpty {
        return fields.first { $0.id == field.templateFieldId }
    }

    let fieldName = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !fieldName.isEmpty else { return nil }
    return fields.first {
        $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(fieldName) == .orderedSame
    }
}
