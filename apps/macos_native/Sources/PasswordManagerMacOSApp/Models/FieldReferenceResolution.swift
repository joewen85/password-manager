import Foundation

enum FieldReferenceStatus: Equatable, Sendable {
    case empty
    case invalidConfiguration
    case missing
    case deleted
    case categoryMismatch
    case targetFieldMissing
    case targetFieldUnsupported
    case targetFieldEmpty
    case resolved
}

struct FieldReferenceTarget: Equatable, Sendable {
    let entryID: String
    let entryLabel: String
    let entryCategory: String
    let fieldID: String
    let fieldName: String
    let fieldValue: String
}

struct FieldReferenceResolution: Equatable, Sendable {
    let status: FieldReferenceStatus
    let target: FieldReferenceTarget?

    init(status: FieldReferenceStatus, target: FieldReferenceTarget? = nil) {
        self.status = status
        self.target = target
    }
}

func resolveFieldReference(
    sourceEntry: VaultEntry,
    field: CustomField,
    categoryTemplates: [CategoryTemplate],
    entries: [VaultEntry]
) -> FieldReferenceResolution? {
    guard let sourceTemplate = matchingFieldReferenceCategoryTemplate(
        category: sourceEntry.payload.category,
        templates: categoryTemplates
    ),
    let sourceTemplateField = customFieldSemantics(
        field: field,
        template: sourceTemplate
    ).templateField,
    sourceTemplateField.valueType == "fieldReference" else {
        return nil
    }

    guard !field.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return FieldReferenceResolution(status: .empty)
    }

    let targetCategory = sourceTemplateField.targetCategory
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let targetFieldID = sourceTemplateField.targetFieldId
    guard !targetCategory.isEmpty,
          !targetFieldID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return FieldReferenceResolution(status: .invalidConfiguration)
    }

    let sourceCategory = sourceTemplate.category.trimmingCharacters(in: .whitespacesAndNewlines)
    guard sourceCategory.caseInsensitiveCompare(targetCategory) != .orderedSame
            || sourceTemplateField.id != targetFieldID else {
        return FieldReferenceResolution(status: .invalidConfiguration)
    }

    guard let targetEntry = entries.first(where: { $0.id == field.value }) else {
        return FieldReferenceResolution(status: .missing)
    }
    let targetEntryCategory = targetEntry.payload.category
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let entryProjection = FieldReferenceTarget(
        entryID: targetEntry.id,
        entryLabel: targetEntry.label,
        entryCategory: targetEntryCategory,
        fieldID: targetFieldID,
        fieldName: "",
        fieldValue: ""
    )
    guard !targetEntry.isDeleted else {
        return FieldReferenceResolution(status: .deleted, target: entryProjection)
    }

    guard targetEntryCategory.caseInsensitiveCompare(targetCategory) == .orderedSame else {
        return FieldReferenceResolution(status: .categoryMismatch, target: entryProjection)
    }

    guard let targetTemplate = matchingFieldReferenceCategoryTemplate(
        category: targetEntryCategory,
        templates: categoryTemplates
    ),
    let targetTemplateField = targetTemplate.fields.first(where: { $0.id == targetFieldID }) else {
        return FieldReferenceResolution(status: .targetFieldMissing, target: entryProjection)
    }
    let fieldProjection = FieldReferenceTarget(
        entryID: targetEntry.id,
        entryLabel: targetEntry.label,
        entryCategory: targetEntryCategory,
        fieldID: targetTemplateField.id,
        fieldName: targetTemplateField.name,
        fieldValue: ""
    )
    guard targetTemplateField.normalizedValueType == "text" else {
        return FieldReferenceResolution(status: .targetFieldUnsupported, target: fieldProjection)
    }

    guard let targetValueField = matchingFieldReferenceTargetValue(
        in: targetEntry.customFields,
        templateField: targetTemplateField
    ),
    !targetValueField.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return FieldReferenceResolution(status: .targetFieldEmpty, target: fieldProjection)
    }

    return FieldReferenceResolution(
        status: .resolved,
        target: FieldReferenceTarget(
            entryID: targetEntry.id,
            entryLabel: targetEntry.label,
            entryCategory: targetEntryCategory,
            fieldID: targetTemplateField.id,
            fieldName: targetTemplateField.name,
            fieldValue: targetValueField.value
        )
    )
}

func propagateFieldReferenceCategoryRename(
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
            guard field.valueType == "fieldReference",
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

func fieldReferenceTargetFieldIDs(
    targetCategory: String,
    templates: [CategoryTemplate]
) -> Set<String> {
    let normalizedCategory = targetCategory.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedCategory.isEmpty else { return [] }

    return Set(templates.flatMap(\.fields).compactMap { field in
        guard field.valueType == "fieldReference",
              field.targetCategory.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(normalizedCategory) == .orderedSame,
              !field.targetFieldId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return field.targetFieldId
    })
}

extension VaultEntry {
    func withFieldReferenceSearchProjection(
        categoryTemplates: [CategoryTemplate],
        entries: [VaultEntry]
    ) -> VaultEntry {
        let sourceTemplate = matchingFieldReferenceCategoryTemplate(
            category: payload.category,
            templates: categoryTemplates
        )
        var projectedEntry = withEntryReferenceSearchProjection(
            template: sourceTemplate,
            entries: entries
        )
        projectedEntry.customFields = zip(customFields, projectedEntry.customFields).map {
            sourceField, projectedField in
            guard customFieldSemantics(field: sourceField, template: sourceTemplate)
                .templateField?.valueType == "fieldReference" else {
                return projectedField
            }

            var fieldProjection = projectedField
            let resolution = resolveFieldReference(
                sourceEntry: self,
                field: sourceField,
                categoryTemplates: categoryTemplates,
                entries: entries
            )
            if resolution?.status == .resolved, let target = resolution?.target {
                fieldProjection.value = [
                    target.entryLabel,
                    target.entryCategory,
                    target.fieldName
                ]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            } else {
                fieldProjection.value = ""
            }
            return fieldProjection
        }
        return projectedEntry
    }

    func remappingFieldReferenceIDs(
        using destinationIDsBySourceID: [String: String],
        template: CategoryTemplate?
    ) -> VaultEntry {
        var remappedEntry = self
        remappedEntry.customFields = customFields.map { field in
            guard customFieldSemantics(field: field, template: template)
                .templateField?.valueType == "fieldReference",
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

private func matchingFieldReferenceCategoryTemplate(
    category: String,
    templates: [CategoryTemplate]
) -> CategoryTemplate? {
    let normalizedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
    return templates.first {
        $0.category.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(normalizedCategory) == .orderedSame
    }
}

private func matchingFieldReferenceTargetValue(
    in fields: [CustomField],
    templateField: FieldTemplate
) -> CustomField? {
    if let exact = fields.first(where: {
        !$0.templateFieldId.isEmpty && $0.templateFieldId == templateField.id
    }) {
        return exact
    }

    let targetName = templateField.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !targetName.isEmpty else { return nil }
    return fields.first {
        $0.templateFieldId.isEmpty
            && $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(targetName) == .orderedSame
    }
}
