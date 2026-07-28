import Foundation

enum CustomFieldSemantic: Equatable, Sendable {
    case text
    case entryReference
    case unsupported
}

struct CustomFieldSemantics: Equatable, Sendable {
    let semantic: CustomFieldSemantic
    let templateField: FieldTemplate?
}

let customFieldTextValueType = "text"
let customFieldEntryReferenceValueType = "entryReference"

func customFieldSemantics(
    field: CustomField,
    template: CategoryTemplate?
) -> CustomFieldSemantics {
    guard let templateField = matchingCustomFieldTemplate(field: field, template: template) else {
        return CustomFieldSemantics(
            semantic: field.templateFieldId.isEmpty ? .text : .unsupported,
            templateField: nil
        )
    }

    let semantic: CustomFieldSemantic
    switch templateField.normalizedValueType {
    case customFieldTextValueType:
        semantic = .text
    case customFieldEntryReferenceValueType:
        semantic = .entryReference
    default:
        semantic = .unsupported
    }
    return CustomFieldSemantics(semantic: semantic, templateField: templateField)
}

func matchingCustomFieldTemplate(
    field: CustomField,
    template: CategoryTemplate?
) -> FieldTemplate? {
    guard let fields = template?.fields else { return nil }
    if !field.templateFieldId.isEmpty {
        return fields.first { $0.id == field.templateFieldId }
    }

    let normalizedName = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty else { return nil }
    return fields.first {
        $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(normalizedName) == .orderedSame
    }
}

func isEditableCategoryFieldType(_ valueType: String) -> Bool {
    switch normalizedCategoryFieldValueType(valueType) {
    case customFieldTextValueType, customFieldEntryReferenceValueType:
        true
    default:
        false
    }
}

func categoryTemplateFieldsForUserSave(
    existing: [FieldTemplate],
    requestedCustomFields: [FieldTemplate],
    storedValueFieldIds: Set<String> = []
) -> [FieldTemplate] {
    let requested = CategoryTemplate.defaultFields + requestedCustomFields
    var usedExistingIndices = Set<Int>()
    var merged: [FieldTemplate] = []

    for field in requested {
        guard let existingIndex = matchingExistingFieldIndex(
            existing: existing,
            requested: field,
            usedIndices: usedExistingIndices
        ) else {
            merged.append(normalizedCategoryTemplateField(field))
            continue
        }

        usedExistingIndices.insert(existingIndex)
        let current = existing[existingIndex]
        if !isEditableCategoryFieldType(current.valueType) {
            merged.append(current)
        } else if storedValueFieldIds.contains(current.id),
                  current.normalizedValueType != field.normalizedValueType {
            merged.append(current)
        } else {
            var normalized = normalizedCategoryTemplateField(field)
            normalized.id = current.id
            merged.append(normalized)
        }
    }

    for (index, field) in existing.enumerated()
    where !usedExistingIndices.contains(index)
        && (!isEditableCategoryFieldType(field.valueType) || storedValueFieldIds.contains(field.id)) {
        merged.append(field)
    }
    return merged
}

func duplicateEditableCategoryTemplateFieldName(_ fields: [FieldTemplate]) -> String? {
    var names: [String] = []
    for field in fields where isEditableCategoryFieldType(field.valueType) {
        let name = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { continue }
        if names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return name
        }
        names.append(name)
    }
    return nil
}

func newCategoryTemplateField(
    name: String = "",
    valueType: String = customFieldTextValueType,
    targetCategory: String = ""
) -> FieldTemplate {
    normalizedCategoryTemplateField(FieldTemplate(
        id: UUID().uuidString.lowercased(),
        name: name,
        valueType: valueType,
        targetCategory: targetCategory
    ))
}

extension FieldTemplate {
    var normalizedValueType: String {
        normalizedCategoryFieldValueType(valueType)
    }
}

private func matchingExistingFieldIndex(
    existing: [FieldTemplate],
    requested: FieldTemplate,
    usedIndices: Set<Int>
) -> Int? {
    if !requested.id.isEmpty,
       let index = existing.indices.first(where: {
           !usedIndices.contains($0) && existing[$0].id == requested.id
       }) {
        return index
    }

    let requestedName = requested.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !requestedName.isEmpty else { return nil }
    return existing.indices.first {
        !usedIndices.contains($0)
            && existing[$0].name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(requestedName) == .orderedSame
    }
}

private func normalizedCategoryTemplateField(_ field: FieldTemplate) -> FieldTemplate {
    var normalized = field
    normalized.name = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
    normalized.valueType = field.normalizedValueType
    switch normalized.valueType {
    case customFieldTextValueType:
        normalized.targetCategory = ""
    case customFieldEntryReferenceValueType:
        normalized.targetCategory = field.targetCategory.trimmingCharacters(in: .whitespacesAndNewlines)
    default:
        break
    }
    return normalized
}

private func normalizedCategoryFieldValueType(_ valueType: String) -> String {
    valueType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? customFieldTextValueType
        : valueType
}
