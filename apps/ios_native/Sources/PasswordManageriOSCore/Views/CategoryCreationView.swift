import SwiftUI

struct CategoryCreationView: View {
    @Bindable var store: VaultStore
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var customFields: [CustomField] = []
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
                            HStack(spacing: 8) {
                                TextField("Field Name", text: $field.name)
                                Button(role: .destructive) {
                                    removeCustomField(field.id)
                                } label: {
                                    Label("Remove Field", systemImage: "trash")
                                }
                                .labelStyle(.iconOnly)
                            }
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
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Value is required."
            return
        }

        let didSave = store.addCategory(
            trimmed,
            preset: nil,
            customFieldNames: customFields.map(\.name)
        )

        if didSave {
            onSaved()
            dismiss()
        } else {
            errorMessage = store.statusMessage ?? "Operation failed."
        }
    }

    private func addCustomField() {
        customFields.append(CustomField())
    }

    private func appendFields(for preset: CategoryTypePreset) {
        var existing = Set(
            customFields.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        for name in preset.fields {
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, existing.insert(key).inserted else { continue }
            customFields.append(CustomField(name: name))
        }
    }

    private func removeCustomField(_ id: String) {
        customFields.removeAll { $0.id == id }
    }
}
