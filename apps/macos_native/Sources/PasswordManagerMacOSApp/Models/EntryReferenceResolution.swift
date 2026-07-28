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
