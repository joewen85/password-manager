import SwiftUI

struct TaxonomyManagementView: View {
    @Bindable var store: VaultStore
    var onChange: () -> Void = {}
    var initialFieldEditCategory: String?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedKind: TaxonomyKind = .category
    @State private var newValue = ""
    @State private var categoryCustomFields: [CustomField] = []
    @State private var renameRequest: TaxonomyEditRequest?
    @State private var fieldEditRequest: CategoryFieldsEditRequest?
    @State private var deleteRequest: TaxonomyEditRequest?
    @State private var didPresentInitialFieldEditor = false

    init(
        store: VaultStore,
        onChange: @escaping () -> Void = {},
        initialFieldEditCategory: String? = nil
    ) {
        self.store = store
        self.onChange = onChange
        self.initialFieldEditCategory = initialFieldEditCategory
    }

    private var values: [String] {
        switch selectedKind {
        case .category:
            store.categories
        case .tag:
            store.tags
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Manage", selection: $selectedKind) {
                    ForEach(TaxonomyKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 8) {
                    TextField(selectedKind.placeholder, text: $newValue)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addValue)
                    Button(action: addValue) {
                        Label("Add", systemImage: "plus")
                    }
                    .disabled(isAddDisabled)
                }

                if selectedKind == .category {
                    CategoryPresetShortcutButtons(fields: $categoryCustomFields)
                    CategoryTemplateFieldNameEditor(fields: $categoryCustomFields)
                }

                Group {
                    if values.isEmpty {
                        ContentUnavailableView(
                            L10n.tf("No %@", selectedKind.emptyLabel.capitalized),
                            systemImage: selectedKind.systemImage
                        )
                    } else {
                        List(values, id: \.self) { value in
                            HStack {
                                Label(value, systemImage: selectedKind.systemImage)
                                Spacer()
                                Button {
                                    renameRequest = TaxonomyEditRequest(kind: selectedKind, value: value)
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .labelStyle(.iconOnly)
                                .help("Rename")

                                if selectedKind == .category {
                                    Button {
                                        fieldEditRequest = CategoryFieldsEditRequest(
                                            category: value,
                                            fields: editableFields(for: value),
                                            storedValueFieldIDs: store.categoryTemplateStoredValueFieldIDs(value),
                                            referencedTargetFieldIDs: store.categoryTemplateReferencedTargetFieldIDs(value)
                                        )
                                    } label: {
                                        Label(L10n.t("Fields"), systemImage: "square.and.pencil")
                                    }
                                    .labelStyle(.iconOnly)
                                    .help(L10n.t("Fields"))
                                }

                                Button(role: .destructive) {
                                    deleteRequest = TaxonomyEditRequest(kind: selectedKind, value: value)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .labelStyle(.iconOnly)
                                .help("Delete")
                            }
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                renameRequest = TaxonomyEditRequest(kind: selectedKind, value: value)
                            }
                            .contextMenu {
                                Button {
                                    renameRequest = TaxonomyEditRequest(kind: selectedKind, value: value)
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }

                                if selectedKind == .category {
                                    Button {
                                        fieldEditRequest = CategoryFieldsEditRequest(
                                            category: value,
                                            fields: editableFields(for: value),
                                            storedValueFieldIDs: store.categoryTemplateStoredValueFieldIDs(value),
                                            referencedTargetFieldIDs: store.categoryTemplateReferencedTargetFieldIDs(value)
                                        )
                                    } label: {
                                        Label(L10n.t("Fields"), systemImage: "square.and.pencil")
                                    }
                                }

                                Button(role: .destructive) {
                                    deleteRequest = TaxonomyEditRequest(kind: selectedKind, value: value)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding()
            .navigationTitle("Manage Categories & Tags")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                ToolbarSpacer(.fixed)
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: addValue) {
                        Label(L10n.tf("Add %@", selectedKind.placeholder), systemImage: "plus")
                    }
                    .disabled(isAddDisabled)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 460)
        .onAppear {
            guard !didPresentInitialFieldEditor,
                  let initialFieldEditCategory,
                  store.categories.contains(where: { $0.caseInsensitiveCompare(initialFieldEditCategory) == .orderedSame }) else {
                return
            }
            didPresentInitialFieldEditor = true
            fieldEditRequest = CategoryFieldsEditRequest(
                category: initialFieldEditCategory,
                fields: editableFields(for: initialFieldEditCategory),
                storedValueFieldIDs: store.categoryTemplateStoredValueFieldIDs(initialFieldEditCategory),
                referencedTargetFieldIDs: store.categoryTemplateReferencedTargetFieldIDs(initialFieldEditCategory)
            )
        }
        .onChange(of: selectedKind) { _, nextKind in
            if nextKind == .tag {
                categoryCustomFields = []
            }
        }
        .sheet(item: $renameRequest) { request in
            TaxonomyRenameView(store: store, request: request) {
                onChange()
            }
            .frame(width: 420, height: 180)
        }
        .sheet(item: $fieldEditRequest) { request in
            CategoryFieldsEditView(store: store, request: request) {
                onChange()
            }
            .frame(width: 500, height: 520)
        }
        .alert(item: $deleteRequest) { request in
            Alert(
                title: Text(request.kind.deleteTitle),
                message: Text(request.kind.deleteMessage(for: request.value)),
                primaryButton: .destructive(Text("Delete")) {
                    deleteValue(request)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func editableFields(for category: String) -> [FieldTemplate] {
        let fields = store.categoryTemplates
            .first { $0.category.compare(category, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }?
            .fields
            ?? CategoryTemplate.defaultCategoryFields()
        return fields.filter {
                $0.name.compare("名称", options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
            }
            .map { field in
                var editable = field
                if field.normalizedValueType == "text" {
                    editable.valueType = "text"
                    editable.targetCategory = ""
                } else if field.normalizedValueType == "entryReference" {
                    editable.valueType = "entryReference"
                    editable.targetCategory = field.targetCategory.trimmingCharacters(in: .whitespacesAndNewlines)
                    editable.targetFieldId = ""
                } else if field.normalizedValueType == "fieldReference" {
                    editable.valueType = "fieldReference"
                    editable.targetCategory = field.targetCategory.trimmingCharacters(in: .whitespacesAndNewlines)
                    editable.targetFieldId = field.targetFieldId
                }
                return editable
            }
    }

    private var isAddDisabled: Bool {
        newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addValue() {
        let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let didSave: Bool
        switch selectedKind {
        case .category:
            didSave = store.addCategory(
                value,
                preset: nil,
                customFieldNames: categoryCustomFields.map(\.name)
            )
        case .tag:
            didSave = store.addTag(value)
        }
        if didSave {
            newValue = ""
            categoryCustomFields = []
            onChange()
        }
    }

    private func deleteValue(_ request: TaxonomyEditRequest) {
        let didDelete: Bool
        switch request.kind {
        case .category:
            didDelete = store.deleteCategory(request.value)
        case .tag:
            didDelete = store.deleteTag(request.value)
        }
        if didDelete {
            onChange()
        }
    }
}

private struct TaxonomyRenameView: View {
    @Bindable var store: VaultStore
    let request: TaxonomyEditRequest
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var value: String

    init(store: VaultStore, request: TaxonomyEditRequest, onSaved: @escaping () -> Void) {
        self.store = store
        self.request = request
        self.onSaved = onSaved
        _value = State(initialValue: request.value)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(request.kind.placeholder, text: $value)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
            }
            .formStyle(.grouped)
            .navigationTitle(request.kind.renameTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        let didSave: Bool
        switch request.kind {
        case .category:
            didSave = store.renameCategory(request.value, to: value)
        case .tag:
            didSave = store.renameTag(request.value, to: value)
        }
        if didSave {
            onSaved()
            dismiss()
        }
    }
}

private struct TaxonomyEditRequest: Identifiable {
    let kind: TaxonomyKind
    let value: String

    var id: String { "\(kind.rawValue)|\(value)" }
}

private struct CategoryFieldsEditRequest: Identifiable {
    let category: String
    let fields: [FieldTemplate]
    let storedValueFieldIDs: Set<String>
    let referencedTargetFieldIDs: Set<String>

    var id: String { category }
}

private struct CategoryFieldsEditView: View {
    @Bindable var store: VaultStore
    let category: String
    let storedValueFieldIDs: Set<String>
    let referencedTargetFieldIDs: Set<String>
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var fields: [FieldTemplate]

    init(store: VaultStore, request: CategoryFieldsEditRequest, onSaved: @escaping () -> Void) {
        self.store = store
        self.category = request.category
        self.storedValueFieldIDs = request.storedValueFieldIDs
        self.referencedTargetFieldIDs = request.referencedTargetFieldIDs
        self.onSaved = onSaved
        _fields = State(initialValue: request.fields)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(category) {
                    CategoryTemplateFieldEditor(
                        fields: $fields,
                        sourceCategory: category,
                        categories: store.categories,
                        templates: prospectiveTemplates,
                        storedValueFieldIDs: storedValueFieldIDs,
                        referencedTargetFieldIDs: referencedTargetFieldIDs
                    )
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L10n.t("Fields"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Save"), action: save)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func save() {
        guard store.updateCategoryTemplate(category, fields: fields) else { return }
        onSaved()
        dismiss()
    }

    private var prospectiveTemplates: [CategoryTemplate] {
        let updated = CategoryTemplate(
            category: category,
            fields: CategoryTemplate.defaultCategoryFields() + fields
        )
        return store.categoryTemplates.filter {
            $0.category.caseInsensitiveCompare(category) != .orderedSame
        } + [updated]
    }
}

private struct CategoryTemplateFieldEditor: View {
    @Binding var fields: [FieldTemplate]
    let sourceCategory: String
    let categories: [String]
    let templates: [CategoryTemplate]
    let storedValueFieldIDs: Set<String>
    let referencedTargetFieldIDs: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(fields.indices, id: \.self) { index in
                let isKnown = isEditableCategoryFieldType(fields[index].valueType)
                let isLocked = storedValueFieldIDs.contains(fields[index].id)
                    || referencedTargetFieldIDs.contains(fields[index].id)
                VStack(alignment: .leading, spacing: 8) {
                    if isKnown {
                        TextField(L10n.t("Field Name"), text: $fields[index].name)
                            .textFieldStyle(.roundedBorder)

                        Picker(L10n.t("Field Type"), selection: $fields[index].valueType) {
                            Text(L10n.t("Text")).tag("text")
                            Text(L10n.t("Field Reference")).tag("fieldReference")
                        }
                        .pickerStyle(.segmented)
                        .disabled(isLocked)

                        if fields[index].normalizedValueType == "fieldReference" {
                            Picker(L10n.t("Target Category"), selection: targetCategoryBinding(index)) {
                                Text(L10n.t("Select Target Category")).tag("")
                                if !fields[index].targetCategory.isEmpty,
                                   !categories.contains(where: {
                                       $0.caseInsensitiveCompare(fields[index].targetCategory) == .orderedSame
                                   }) {
                                    Text(fields[index].targetCategory).tag(fields[index].targetCategory)
                                }
                                ForEach(categories, id: \.self) { category in
                                    Text(category).tag(category)
                                }
                            }

                            Picker(L10n.t("Target Field"), selection: $fields[index].targetFieldId) {
                                Text(L10n.t("Select Target Field")).tag("")
                                if !fields[index].targetFieldId.isEmpty,
                                   !targetFieldCandidates(index).contains(where: {
                                       $0.id == fields[index].targetFieldId
                                   }) {
                                    Text(L10n.t("Target field is no longer available."))
                                        .tag(fields[index].targetFieldId)
                                }
                                ForEach(targetFieldCandidates(index)) { candidate in
                                    Text(candidate.name).tag(candidate.id)
                                }
                            }
                            .disabled(fields[index].targetCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        if isLocked {
                            Label(
                                L10n.t("Saved values lock this field's type and deletion."),
                                systemImage: "lock.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(fields[index].name.isEmpty ? L10n.t("Unsupported Field") : fields[index].name)
                            .font(.callout.weight(.medium))
                        Text(L10n.t("Unsupported field metadata and values are preserved read-only."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if isKnown && !isLocked {
                        HStack {
                            Spacer()
                            Button(role: .destructive) {
                                fields.remove(at: index)
                            } label: {
                                Label(L10n.t("Remove Field"), systemImage: "trash")
                            }
                            .labelStyle(.iconOnly)
                            .help(L10n.t("Remove Field"))
                        }
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .onChange(of: fields[index].valueType) { _, valueType in
                    if valueType == "text" {
                        fields[index].targetCategory = ""
                        fields[index].targetFieldId = ""
                    } else if valueType == "fieldReference" {
                        fields[index].targetCategory = ""
                        fields[index].targetFieldId = ""
                    }
                }
            }

            Button {
                fields.append(newCategoryTemplateField())
            } label: {
                Label(L10n.t("Add Field"), systemImage: "plus")
            }
            .controlSize(.small)
        }
    }

    private func targetFieldCandidates(_ index: Int) -> [FieldTemplate] {
        guard fields.indices.contains(index) else { return [] }
        return fieldReferenceTargetFieldCandidates(
            sourceCategory: sourceCategory,
            sourceField: fields[index],
            templates: templates
        )
    }

    private func targetCategoryBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { fields.indices.contains(index) ? fields[index].targetCategory : "" },
            set: { value in
                guard fields.indices.contains(index) else { return }
                fields[index].targetCategory = value
                fields[index].targetFieldId = ""
            }
        )
    }
}

private enum TaxonomyKind: String, CaseIterable, Identifiable {
    case category
    case tag

    var id: String { rawValue }

    var title: String {
        switch self {
        case .category: L10n.t("Categories")
        case .tag: L10n.t("Tags")
        }
    }

    var placeholder: String {
        switch self {
        case .category: L10n.t("Category")
        case .tag: L10n.t("Tag")
        }
    }

    var emptyLabel: String {
        switch self {
        case .category: L10n.t("categories")
        case .tag: L10n.t("tags")
        }
    }

    var systemImage: String {
        switch self {
        case .category: "folder"
        case .tag: "tag"
        }
    }

    var renameTitle: String {
        switch self {
        case .category: L10n.t("Rename Category")
        case .tag: L10n.t("Rename Tag")
        }
    }

    var deleteTitle: String {
        switch self {
        case .category: L10n.t("Delete Category")
        case .tag: L10n.t("Delete Tag")
        }
    }

    func deleteMessage(for value: String) -> String {
        switch self {
        case .category:
            L10n.tf("Delete category \"%@\"? Existing entries will become uncategorized.", value)
        case .tag:
            L10n.tf("Delete tag \"%@\"? Existing entries will lose this tag.", value)
        }
    }
}
