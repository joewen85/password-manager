import Foundation

enum FieldReferenceActionDestination: Equatable, Sendable {
    case entrySelection
    case categoryFields
}

struct FieldReferencePresentation: Equatable, Sendable {
    let text: String
    let actionTitle: String
    let actionDestination: FieldReferenceActionDestination
    let isError: Bool
    let canOpenTarget: Bool
}

func fieldReferencePresentation(_ resolution: FieldReferenceResolution?) -> FieldReferencePresentation {
    switch resolution?.status {
    case .empty, nil:
        return FieldReferencePresentation(
            text: "No entry selected.",
            actionTitle: "Select",
            actionDestination: .entrySelection,
            isError: false,
            canOpenTarget: false
        )
    case .invalidConfiguration:
        return configurationPresentation("Field reference configuration needs repair.")
    case .missing:
        return repairableEntryPresentation("Referenced entry is missing.")
    case .deleted:
        return repairableEntryPresentation("Referenced entry was deleted.")
    case .categoryMismatch:
        return repairableEntryPresentation("Referenced entry is outside the target category.")
    case .targetFieldMissing:
        return configurationPresentation("Target field is no longer available.")
    case .targetFieldUnsupported:
        return configurationPresentation("Target field is not a text field.")
    case .targetFieldEmpty:
        return repairableEntryPresentation("Target field is empty.")
    case .resolved:
        let target = resolution?.target
        return FieldReferencePresentation(
            text: [
                target?.entryLabel.isEmpty == false ? target?.entryLabel : "Untitled",
                target?.fieldName.isEmpty == false ? target?.fieldName : "Target Field"
            ]
            .compactMap { $0 }
            .joined(separator: " - "),
            actionTitle: "Replace",
            actionDestination: .entrySelection,
            isError: target == nil,
            canOpenTarget: target != nil
        )
    }
}

func resolveFieldReferenceForPresentation(
    sourceCategory: String,
    field: CustomField,
    categoryTemplates: [CategoryTemplate],
    entries: [VaultEntry]
) -> FieldReferenceResolution? {
    resolveFieldReference(
        sourceEntry: VaultEntry(
            label: "",
            type: .credential,
            payload: .credential(CredentialPayload(category: sourceCategory)),
            customFields: [field]
        ),
        field: field,
        categoryTemplates: categoryTemplates,
        entries: entries
    )
}

func fieldReferenceResolvedValue(_ resolution: FieldReferenceResolution?) -> String? {
    guard resolution?.status == .resolved else { return nil }
    return resolution?.target?.fieldValue
}

func fieldReferenceTargetFieldCandidates(
    sourceCategory: String,
    sourceField: FieldTemplate,
    templates: [CategoryTemplate]
) -> [FieldTemplate] {
    let targetCategory = sourceField.targetCategory.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !targetCategory.isEmpty else { return [] }
    let sourceCategory = sourceCategory.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let targetTemplate = templates.first(where: {
        $0.category.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(targetCategory) == .orderedSame
    }) else {
        return []
    }

    var seenIDs = Set<String>()
    return targetTemplate.fields.filter { candidate in
        let candidateName = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.normalizedValueType == customFieldTextValueType,
              !candidate.id.isEmpty,
              candidateName.caseInsensitiveCompare("名称") != .orderedSame,
              seenIDs.insert(candidate.id).inserted else {
            return false
        }
        return sourceCategory.caseInsensitiveCompare(targetCategory) != .orderedSame
            || candidate.id != sourceField.id
    }
}

func fieldReferenceTemplateConfigurationIsValid(
    sourceCategory: String,
    sourceField: FieldTemplate,
    templates: [CategoryTemplate]
) -> Bool {
    guard sourceField.normalizedValueType == customFieldFieldReferenceValueType,
          !sourceField.targetFieldId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return false
    }
    return fieldReferenceTargetFieldCandidates(
        sourceCategory: sourceCategory,
        sourceField: sourceField,
        templates: templates
    ).contains { $0.id == sourceField.targetFieldId }
}

private func configurationPresentation(_ text: String) -> FieldReferencePresentation {
    FieldReferencePresentation(
        text: text,
        actionTitle: "Edit Fields",
        actionDestination: .categoryFields,
        isError: true,
        canOpenTarget: false
    )
}

private func repairableEntryPresentation(_ text: String) -> FieldReferencePresentation {
    FieldReferencePresentation(
        text: text,
        actionTitle: "Repair",
        actionDestination: .entrySelection,
        isError: true,
        canOpenTarget: false
    )
}
