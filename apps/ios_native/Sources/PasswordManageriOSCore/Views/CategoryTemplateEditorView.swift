import SwiftUI

struct CategoryTemplateEditorView: View {
    @Bindable var store: VaultStore
    let category: String

    @Environment(\.dismiss) private var dismiss
    @State private var fields: [FieldTemplate]
    @State private var errorMessage: String?

    private let storedValueFieldIDs: Set<String>

    init(store: VaultStore, category: String) {
        self.store = store
        self.category = category
        let template = store.categoryTemplate(for: category) ?? CategoryTemplate(category: category)
        let baseNames = Set(CategoryTemplate.defaultFields.map {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        _fields = State(initialValue: template.fields.filter {
            !baseNames.contains($0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        })
        storedValueFieldIDs = store.categoryTemplateStoredValueFieldIds(category)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(category)
                        .font(.headline)
                    Text("Fields with saved values can be renamed, and reference targets can change, but their type cannot change and they cannot be removed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section("Custom Fields") {
                    if fields.isEmpty {
                        Text("No custom fields.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach($fields) { $field in
                        CategoryTemplateFieldEditor(
                            field: $field,
                            categories: store.categories,
                            isStored: storedValueFieldIDs.contains(field.id),
                            remove: { remove(field.id) }
                        )
                    }

                    Button(action: addField) {
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
            .navigationTitle("Edit Category Fields")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
        }
    }

    private func addField() {
        fields.append(newCategoryTemplateField())
    }

    private func remove(_ id: String) {
        guard !storedValueFieldIDs.contains(id) else { return }
        fields.removeAll { $0.id == id }
    }

    private func save() {
        if store.updateCategoryTemplate(category: category, requestedCustomFields: fields) {
            dismiss()
        } else {
            errorMessage = store.statusMessage ?? "Operation failed."
        }
    }
}

private struct CategoryTemplateFieldEditor: View {
    @Binding var field: FieldTemplate
    var categories: [String]
    var isStored: Bool
    var remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isEditableCategoryFieldType(field.valueType) {
                HStack(spacing: 8) {
                    TextField("Field Name", text: $field.name)
                    if !isStored {
                        Button(role: .destructive, action: remove) {
                            Label("Remove Field", systemImage: "trash")
                        }
                        .labelStyle(.iconOnly)
                    }
                }

                if isStored {
                    LabeledContent("Field Type", value: fieldTypeTitle)
                    Text("This field has saved values. Its type and presence are locked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Field Type", selection: valueTypeBinding) {
                        Text("Text").tag(customFieldTextValueType)
                        Text("Entry").tag(customFieldEntryReferenceValueType)
                    }
                    .pickerStyle(.segmented)
                }

                if field.normalizedValueType == customFieldEntryReferenceValueType {
                    Picker("Target Category", selection: $field.targetCategory) {
                        Text("Any Category").tag("")
                        ForEach(categories, id: \.self) { category in
                            Text(category).tag(category)
                        }
                    }
                }
            } else {
                Text(field.name.isEmpty ? "Unsupported Field" : field.name)
                    .font(.headline)
                LabeledContent("Field Type", value: field.valueType)
                Text("This field type is not supported by this version. Its metadata and stored values will be preserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var fieldTypeTitle: String {
        field.normalizedValueType == customFieldEntryReferenceValueType ? "Entry Reference" : "Text"
    }

    private var valueTypeBinding: Binding<String> {
        Binding(
            get: { field.normalizedValueType },
            set: { value in
                field.valueType = value
                if value == customFieldTextValueType {
                    field.targetCategory = ""
                }
            }
        )
    }
}
