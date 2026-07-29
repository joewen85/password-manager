import SwiftUI

func categoryCreationProspectiveTemplates(
    category: String,
    customFields: [FieldTemplate],
    existingTemplates: [CategoryTemplate]
) -> [CategoryTemplate] {
    let normalized = category.trimmingCharacters(in: .whitespacesAndNewlines)
    var templates = existingTemplates.filter {
        $0.category.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(normalized) != .orderedSame
    }
    guard !normalized.isEmpty else { return templates }
    templates.append(CategoryTemplate(
        category: normalized,
        fields: categoryTemplateFieldsForUserSave(
            existing: [],
            requestedCustomFields: customFields
        )
    ))
    return templates
}

func categoryCreationFieldValidationMessage(
    category: String,
    customFields: [FieldTemplate],
    existingTemplates: [CategoryTemplate]
) -> String? {
    if customFields.contains(where: {
        isEditableCategoryFieldType($0.valueType)
            && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }) {
        return "Field name is required."
    }

    let fields = categoryTemplateFieldsForUserSave(
        existing: [],
        requestedCustomFields: customFields
    )
    if let duplicateName = duplicateEditableCategoryTemplateFieldName(fields) {
        return "Field name already exists: \(duplicateName)."
    }

    let templates = categoryCreationProspectiveTemplates(
        category: category,
        customFields: customFields,
        existingTemplates: existingTemplates
    )
    if fields.contains(where: {
        $0.normalizedValueType == customFieldFieldReferenceValueType
            && !fieldReferenceTemplateConfigurationIsValid(
                sourceCategory: category,
                sourceField: $0,
                templates: templates
            )
    }) {
        return "Field reference requires a target category and target text field."
    }
    return nil
}

struct CategoryCreationView: View {
    @Bindable var store: VaultStore
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var customFields: [FieldTemplate] = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Category", text: $value)
                        .onSubmit(save)

                    Text("Create a category without opening the entry editor.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section("Field Shortcuts") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            ForEach(CategoryTypePreset.allCases) { preset in
                                Button {
                                    appendFields(for: preset)
                                } label: {
                                    Text(preset.title)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }

                        Text("New categories use only Name and Notes until you add custom fields.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Custom Fields") {
                    if customFields.isEmpty {
                        Text("No custom fields.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach($customFields) { $field in
                            CategoryTemplateFieldEditor(
                                field: $field,
                                sourceCategory: trimmedCategory,
                                categories: targetCategoryOptions,
                                templates: prospectiveTemplates,
                                isLocked: false,
                                remove: { removeCustomField(field.id) }
                            )
                        }
                    }

                    Button(action: addCustomField) {
                        Label("Add Field", systemImage: "plus")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Create Category")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        guard !trimmedCategory.isEmpty else {
            errorMessage = "Value is required."
            return
        }

        if let validationMessage = categoryCreationFieldValidationMessage(
            category: trimmedCategory,
            customFields: customFields,
            existingTemplates: store.categoryTemplates
        ) {
            errorMessage = validationMessage
            return
        }

        let didSave = store.addCategory(
            trimmedCategory,
            preset: nil,
            customFields: customFields
        )

        if didSave {
            onSaved()
            dismiss()
        } else {
            errorMessage = store.statusMessage ?? "Operation failed."
        }
    }

    private func addCustomField() {
        customFields.append(newCategoryTemplateField())
    }

    private func appendFields(for preset: CategoryTypePreset) {
        var existing = Set(
            customFields.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        for name in preset.fields {
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, existing.insert(key).inserted else { continue }
            customFields.append(newCategoryTemplateField(name: name))
        }
    }

    private func removeCustomField(_ id: String) {
        customFields.removeAll { $0.id == id }
    }

    private var trimmedCategory: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var targetCategoryOptions: [String] {
        var categories = store.categories
        if !trimmedCategory.isEmpty,
           !categories.contains(where: {
               $0.caseInsensitiveCompare(trimmedCategory) == .orderedSame
           }) {
            categories.append(trimmedCategory)
        }
        return categories.sorted()
    }

    private var prospectiveTemplates: [CategoryTemplate] {
        categoryCreationProspectiveTemplates(
            category: trimmedCategory,
            customFields: customFields,
            existingTemplates: store.categoryTemplates
        )
    }
}
