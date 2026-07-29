import SwiftUI

struct EntryEditorView: View {
    var entry: VaultEntry?
    var initialCategory: String
    var categories: [String]
    var categoryTemplates: [CategoryTemplate]
    var entries: [VaultEntry]
    var tags: [String]
    var onCreateCategory: (String, CategoryTypePreset?, [String]) -> Bool
    var onCreateTag: (String) -> Bool
    var onEditCategoryFields: (String) -> Void
    var onSave: (EntryDraft) -> String?
    var onCancel: () -> Void

    @State private var draft: EntryDraft
    @State private var selectedTags: Set<String>
    @State private var availableCategories: [String]
    @State private var availableTags: [String]
    @State private var taxonomyMessage: String?

    init(
        entry: VaultEntry?,
        initialCategory: String = "",
        categories: [String],
        categoryTemplates: [CategoryTemplate] = [],
        entries: [VaultEntry] = [],
        tags: [String],
        onCreateCategory: @escaping (String, CategoryTypePreset?, [String]) -> Bool = { _, _, _ in false },
        onCreateTag: @escaping (String) -> Bool = { _ in false },
        onEditCategoryFields: @escaping (String) -> Void = { _ in },
        onSave: @escaping (EntryDraft) -> String?,
        onCancel: @escaping () -> Void
    ) {
        self.entry = entry
        self.initialCategory = initialCategory
        self.categories = categories
        self.categoryTemplates = categoryTemplates
        self.entries = entries
        self.tags = tags
        self.onCreateCategory = onCreateCategory
        self.onCreateTag = onCreateTag
        self.onEditCategoryFields = onEditCategoryFields
        self.onSave = onSave
        self.onCancel = onCancel
        let initialDraft: EntryDraft
        if let entry {
            initialDraft = EntryDraft(entry: entry)
        } else {
            var draft = EntryDraft()
            draft.category = initialCategory.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.configureTemplateFields(Self.templateFields(for: draft.category, in: categoryTemplates))
            initialDraft = draft
        }
        _draft = State(initialValue: initialDraft)
        _selectedTags = State(initialValue: Set(initialDraft.tags))
        _availableCategories = State(initialValue: categories)
        _availableTags = State(initialValue: tags)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                overviewSection

                Section("Tags") {
                    TagMultiSelectField(
                        selectedTags: $selectedTags,
                        tags: availableTags,
                        onCreateTag: createTag
                    )
                }

                if usesTemplateFields {
                    TemplateFieldsEditor(
                        fields: $draft.customFields,
                        hiddenFieldIDs: draft.hiddenCustomFieldIds,
                        sourceCategory: draft.category,
                        template: currentCategoryTemplate,
                        categoryTemplates: categoryTemplates,
                        entries: entries,
                        onEditCategoryFields: onEditCategoryFields,
                        addField: { draft.addCustomField() }
                    )
                } else {
                    switch draft.type {
                    case .credential:
                        CredentialEditor(payload: $draft.credential)
                    case .server:
                        ServerEditor(payload: $draft.server)
                    case .service:
                        ServiceEditor(payload: $draft.service)
                    }

                    CustomFieldsEditor(
                        fields: $draft.customFields,
                        hiddenFieldIDs: draft.hiddenCustomFieldIds,
                        sourceCategory: draft.category,
                        template: currentCategoryTemplate,
                        categoryTemplates: categoryTemplates,
                        entries: entries,
                        onEditCategoryFields: onEditCategoryFields,
                        addField: { draft.addCustomField() }
                    )
                }
            }
            .formStyle(.grouped)
            .padding()

            Divider()

            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button(entry == nil ? "Add Entry" : "Save Changes", action: save)
                .buttonStyle(.borderedProminent)
                .disabled(draft.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .onChange(of: categories) { _, nextCategories in
            availableCategories = mergedValues(availableCategories + nextCategories)
        }
        .onChange(of: draft.category) { _, nextCategory in
            applyTemplate(for: nextCategory)
        }
        .onChange(of: tags) { _, nextTags in
            availableTags = mergedValues(availableTags + nextTags)
        }
        .onAppear {
            resetDraft(from: entry)
        }
        .onChange(of: entry) { _, nextEntry in
            resetDraft(from: nextEntry)
        }
    }

    private var overviewSection: some View {
        Section("Overview") {
            TextField("Label", text: $draft.label)

            CategorySelectField(
                selectedCategory: $draft.category,
                categories: availableCategories,
                onCreateCategory: createCategory
            )

            if let taxonomyMessage {
                Text(taxonomyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func resetDraft(from entry: VaultEntry?) {
        let nextDraft: EntryDraft
        if let entry {
            var draft = EntryDraft(entry: entry)
            draft.configureTemplateFields(
                Self.categoryTemplateFields(for: draft.category, in: categoryTemplates) ?? []
            )
            nextDraft = draft
        } else {
            var draft = EntryDraft()
            draft.category = initialCategory.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.configureTemplateFields(Self.templateFields(for: draft.category, in: categoryTemplates))
            nextDraft = draft
        }
        draft = nextDraft
        selectedTags = Set(nextDraft.tags)
        taxonomyMessage = nil
    }

    private func createCategory(_ value: String, preset: CategoryTypePreset?, customFieldNames: [String]) -> Bool {
        guard !value.isEmpty else { return false }
        if onCreateCategory(value, preset, customFieldNames) {
            availableCategories = mergedValues(availableCategories + [value])
            draft.category = value
            applyTemplate(for: value, preset: preset, customFieldNames: customFieldNames)
            taxonomyMessage = "Category added."
            return true
        } else {
            taxonomyMessage = "Category could not be added."
            return false
        }
    }

    private func createTag(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if onCreateTag(value) {
            availableTags = mergedValues(availableTags + [value])
            selectedTags.insert(value)
            taxonomyMessage = "Tag added."
            return true
        } else {
            taxonomyMessage = "Tag could not be added."
            return false
        }
    }

    private func save() {
        draft.tags = selectedTags.sorted()
        if let duplicateName = draft.duplicateActiveTemplateBindingName(template: currentCategoryTemplate) {
            taxonomyMessage = "Field name already exists: \(duplicateName)."
            return
        }
        if let errorMessage = onSave(draft) {
            taxonomyMessage = errorMessage
        } else {
            taxonomyMessage = nil
        }
    }

    private func mergedValues(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }

    private func applyTemplate(
        for category: String,
        preset: CategoryTypePreset? = nil,
        customFieldNames: [String] = []
    ) {
        let normalized = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields: [FieldTemplate]
        if preset != nil || !customFieldNames.isEmpty {
            fields = CategoryTemplate.fields(for: preset, customFieldNames: customFieldNames)
        } else if let templateFields = Self.categoryTemplateFields(for: normalized, in: categoryTemplates) {
            fields = templateFields
        } else if entry == nil {
            fields = CategoryTemplate.defaultFields
        } else {
            fields = []
        }
        draft.configureTemplateFields(fields)
    }

    private var currentCategoryTemplate: CategoryTemplate? {
        let normalized = draft.category.trimmingCharacters(in: .whitespacesAndNewlines)
        return categoryTemplates.first {
            $0.category.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(normalized) == .orderedSame
        }
    }

    private var usesTemplateFields: Bool {
        Self.shouldUseTemplateFields(
            for: draft,
            isCreating: entry == nil,
            in: categoryTemplates
        )
    }

    private static func shouldUseTemplateFields(
        for draft: EntryDraft,
        isCreating: Bool,
        in templates: [CategoryTemplate]
    ) -> Bool {
        guard !isCreating else { return true }
        guard categoryTemplateFields(for: draft.category, in: templates) != nil else { return false }
        return !draft.customFields.isEmpty || !draft.payload.hasLegacyEditorValues
    }

    private static func templateFields(for category: String, in templates: [CategoryTemplate]) -> [FieldTemplate] {
        categoryTemplateFields(for: category, in: templates)
            ?? CategoryTemplate.defaultFields
    }

    private static func categoryTemplateFields(for category: String, in templates: [CategoryTemplate]) -> [FieldTemplate]? {
        let normalized = category.trimmingCharacters(in: .whitespacesAndNewlines)
        return templates.first { $0.category.caseInsensitiveCompare(normalized) == .orderedSame }?.fields
    }
}

private struct CategorySelectField: View {
    @Binding var selectedCategory: String
    var categories: [String]
    var onCreateCategory: (String, CategoryTypePreset?, [String]) -> Bool

    @State private var isPresented = false
    @State private var searchText = ""
    @State private var customFields: [CustomField] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Category")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                isPresented.toggle()
            } label: {
                HStack {
                    Text(selectedCategory.isEmpty ? "Uncategorized" : selectedCategory)
                        .foregroundStyle(selectedCategory.isEmpty ? .secondary : .primary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    SearchCreationField(
                        placeholder: "Search categories",
                        text: $searchText,
                        canCreate: canCreateCategory,
                        create: createCategory
                    )

                    if canCreateCategory {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Field shortcuts")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        CategoryTemplateFieldNameEditor(fields: $customFields)
                    }

                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            categoryRow(label: "Uncategorized", value: "")

                            if filteredCategories.isEmpty {
                                Text("No matching categories")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 8)
                            } else {
                                ForEach(filteredCategories, id: \.self) { category in
                                    categoryRow(label: category, value: category)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                }
                .padding(12)
                .frame(width: 320)
            }
        }
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredCategories: [String] {
        guard !trimmedSearchText.isEmpty else { return categories }
        return categories.filter { $0.localizedCaseInsensitiveContains(trimmedSearchText) }
    }

    private var canCreateCategory: Bool {
        !trimmedSearchText.isEmpty && !categories.contains { $0.caseInsensitiveCompare(trimmedSearchText) == .orderedSame }
    }

    private func createCategory() {
        guard canCreateCategory else { return }
        if onCreateCategory(trimmedSearchText, nil, customFields.map(\.name)) {
            selectedCategory = trimmedSearchText
            searchText = ""
            customFields = []
            isPresented = false
        }
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

    private func categoryRow(label: String, value: String) -> some View {
        Button {
            selectedCategory = value
            isPresented = false
        } label: {
            HStack {
                Text(label)
                Spacer()
                if selectedCategory == value {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

private struct TemplateFieldsEditor: View {
    @Binding var fields: [CustomField]
    var hiddenFieldIDs: Set<String>
    var sourceCategory: String
    var template: CategoryTemplate?
    var categoryTemplates: [CategoryTemplate]
    var entries: [VaultEntry]
    var onEditCategoryFields: (String) -> Void
    var addField: () -> Void

    private var visibleIndices: [Int] {
        fields.indices.filter { !hiddenFieldIDs.contains(fields[$0].id) }
    }

    var body: some View {
        Section("Fields") {
            if visibleIndices.isEmpty {
                Text("No custom fields.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visibleIndices, id: \.self) { index in
                    fieldEditor(at: index)
                }
            }

            Button(action: addField) {
                Label("Add Field", systemImage: "plus")
            }
        }
    }

    @ViewBuilder
    private func fieldEditor(at index: Int) -> some View {
        let semantics = customFieldSemantics(field: fields[index], template: template)
        if semantics.semantic == .entryReference, let templateField = semantics.templateField {
            EntryReferenceFieldEditor(
                field: $fields[index],
                templateField: templateField,
                entries: entries
            )
        } else if semantics.semantic == .fieldReference, let templateField = semantics.templateField {
            FieldReferenceFieldEditor(
                field: $fields[index],
                sourceCategory: sourceCategory,
                templateField: templateField,
                categoryTemplates: categoryTemplates,
                entries: entries,
                onEditCategoryFields: onEditCategoryFields
            )
        } else if semantics.semantic == .text {
            CustomFieldRow(
                field: $fields[index],
                showsValue: true,
                remove: { remove(fields[index].id) }
            )
        }
    }

    private func remove(_ id: String) {
        fields.removeAll { $0.id == id }
    }
}

private struct CategoryTemplateFieldNameEditor: View {
    @Binding var fields: [CustomField]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom Fields")
                .font(.caption)
                .foregroundStyle(.secondary)

            if fields.isEmpty {
                Text("No custom fields.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach($fields) { $field in
                    CustomFieldRow(field: $field, showsValue: false, remove: { remove(field.id) })
                }
            }

            Button(action: addField) {
                Label("Add Field", systemImage: "plus")
            }
            .controlSize(.small)
        }
    }

    private func addField() {
        fields.append(CustomField())
    }

    private func remove(_ id: String) {
        fields.removeAll { $0.id == id }
    }
}

private struct CustomFieldRow: View {
    @Binding var field: CustomField
    var showsValue: Bool = true
    var remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Field Name", text: $field.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 140)
                Spacer(minLength: 0)
                Button(role: .destructive, action: remove) {
                    Label("Remove Field", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .help("Remove Field")
            }
            if showsValue {
                TextField("Field Value", text: $field.value, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .padding(.top, 2)
            } else {
                Text("Name first, then value.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }
}

private struct CustomFieldsEditor: View {
    @Binding var fields: [CustomField]
    var hiddenFieldIDs: Set<String>
    var sourceCategory: String
    var template: CategoryTemplate?
    var categoryTemplates: [CategoryTemplate]
    var entries: [VaultEntry]
    var onEditCategoryFields: (String) -> Void
    var addField: () -> Void

    private var visibleIndices: [Int] {
        fields.indices.filter { !hiddenFieldIDs.contains(fields[$0].id) }
    }

    var body: some View {
        Section("Custom Fields") {
            if visibleIndices.isEmpty {
                Text("No custom fields.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visibleIndices, id: \.self) { index in
                    fieldEditor(at: index)
                }
            }

            Button(action: addField) {
                Label("Add Field", systemImage: "plus")
            }
        }
    }

    @ViewBuilder
    private func fieldEditor(at index: Int) -> some View {
        let semantics = customFieldSemantics(field: fields[index], template: template)
        if semantics.semantic == .entryReference, let templateField = semantics.templateField {
            EntryReferenceFieldEditor(
                field: $fields[index],
                templateField: templateField,
                entries: entries
            )
        } else if semantics.semantic == .fieldReference, let templateField = semantics.templateField {
            FieldReferenceFieldEditor(
                field: $fields[index],
                sourceCategory: sourceCategory,
                templateField: templateField,
                categoryTemplates: categoryTemplates,
                entries: entries,
                onEditCategoryFields: onEditCategoryFields
            )
        } else if semantics.semantic == .text {
            CustomFieldRow(
                field: $fields[index],
                showsValue: true,
                remove: { remove(fields[index].id) }
            )
        }
    }

    private func remove(_ id: String) {
        fields.removeAll { $0.id == id }
    }
}

private struct FieldReferenceFieldEditor: View {
    @Binding var field: CustomField
    var sourceCategory: String
    var templateField: FieldTemplate
    var categoryTemplates: [CategoryTemplate]
    var entries: [VaultEntry]
    var onEditCategoryFields: (String) -> Void

    @State private var isPresented = false
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(templateField.name.isEmpty ? "Field Reference" : templateField.name)
                    .font(.callout)
                Spacer()
                Label("Field Reference", systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(presentation.text)
                .foregroundStyle(presentation.isError ? .red : .secondary)

            Text("Target: \(targetCategory.isEmpty ? "Unavailable Category" : targetCategory) / \(targetFieldName)")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button(action: performPrimaryAction) {
                    Label(
                        presentation.actionTitle,
                        systemImage: presentation.actionDestination == .categoryFields
                            ? "square.and.pencil"
                            : "link.badge.plus"
                    )
                }
                .buttonStyle(.borderedProminent)

                if !field.value.isEmpty {
                    Button("Clear", role: .destructive) {
                        field.value = ""
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            selectionContent
        }
    }

    private var resolution: FieldReferenceResolution? {
        resolveFieldReferenceForPresentation(
            sourceCategory: sourceCategory,
            field: field,
            categoryTemplates: categoryTemplates,
            entries: entries
        )
    }

    private var presentation: FieldReferencePresentation {
        guard fieldReferenceTemplateConfigurationIsValid(
            sourceCategory: sourceCategory,
            sourceField: templateField,
            templates: categoryTemplates
        ) else {
            return fieldReferencePresentation(FieldReferenceResolution(status: .invalidConfiguration))
        }
        return fieldReferencePresentation(resolution)
    }

    private var targetCategory: String {
        templateField.targetCategory.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var targetFieldName: String {
        fieldReferenceTargetFieldCandidates(
            sourceCategory: sourceCategory,
            sourceField: templateField,
            templates: categoryTemplates
        ).first { $0.id == templateField.targetFieldId }?.name ?? "Unavailable Field"
    }

    private var candidates: [EntryReferenceCandidate] {
        entryReferenceCandidates(entries: entries, targetCategory: targetCategory, query: searchText)
    }

    private func performPrimaryAction() {
        switch presentation.actionDestination {
        case .categoryFields:
            onEditCategoryFields(sourceCategory)
        case .entrySelection:
            isPresented = true
        }
    }

    private var selectionContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search entries", text: $searchText)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if candidates.isEmpty {
                        Text("No matching entries")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(candidates) { candidate in
                            Button {
                                field.value = candidate.id
                                searchText = ""
                                isPresented = false
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.label.isEmpty ? "Untitled" : candidate.label)
                                        Text(candidate.category.isEmpty ? "Uncategorized" : candidate.category)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if field.value == candidate.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(12)
        .frame(width: 340)
    }
}

private struct EntryReferenceFieldEditor: View {
    @Binding var field: CustomField
    var templateField: FieldTemplate
    var entries: [VaultEntry]

    @State private var isPresented = false
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(templateField.name.isEmpty ? "Entry Reference" : templateField.name)
                .font(.callout)
                .foregroundStyle(.secondary)

            Button {
                isPresented = true
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text(statusText)
                        .foregroundStyle(statusColor)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Search entries", text: $searchText)
                        .textFieldStyle(.roundedBorder)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            if candidates.isEmpty {
                                Text("No matching entries")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 8)
                            } else {
                                ForEach(candidates) { candidate in
                                    Button {
                                        field.value = candidate.id
                                        searchText = ""
                                        isPresented = false
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(candidate.label.isEmpty ? "Untitled" : candidate.label)
                                                Text(candidate.category.isEmpty ? "Uncategorized" : candidate.category)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            if field.value == candidate.id {
                                                Image(systemName: "checkmark")
                                                    .foregroundStyle(.tint)
                                            }
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 260)

                    if !field.value.isEmpty {
                        Button("Clear Selection", role: .destructive) {
                            field.value = ""
                            searchText = ""
                            isPresented = false
                        }
                    }
                }
                .padding(12)
                .frame(width: 340)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }

    private var template: CategoryTemplate {
        CategoryTemplate(category: "", fields: [templateField])
    }

    private var resolution: EntryReferenceResolution? {
        resolveEntryReference(field: field, template: template, entries: entries)
    }

    private var candidates: [EntryReferenceCandidate] {
        entryReferenceCandidates(
            entries: entries,
            targetCategory: templateField.targetCategory,
            query: searchText
        )
    }

    private var statusText: String {
        let presentation = entryReferencePresentation(resolution)
        return resolution?.status == .empty || resolution == nil
            ? "Select an entry"
            : presentation.text
    }

    private var statusColor: Color {
        let presentation = entryReferencePresentation(resolution)
        return presentation.isError ? .red : (resolution?.status == .resolved ? .primary : .secondary)
    }
}

private struct TagMultiSelectField: View {
    @Binding var selectedTags: Set<String>
    var tags: [String]
    var onCreateTag: (String) -> Bool

    @State private var isPresented = false
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Selected tags")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                isPresented.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text(selectedTags.isEmpty ? "Select tags" : selectedTags.sorted().joined(separator: ", "))
                        .foregroundStyle(selectedTags.isEmpty ? .secondary : .primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    SearchCreationField(
                        placeholder: "Search tags",
                        text: $searchText,
                        canCreate: canCreateTag,
                        create: createTag
                    )

                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            if filteredTags.isEmpty {
                                Text(tags.isEmpty ? "No tags yet." : "No matching tags")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 8)
                            } else {
                                ForEach(filteredTags, id: \.self) { tag in
                                    Button {
                                        toggle(tag)
                                    } label: {
                                        HStack {
                                            Text(tag)
                                            Spacer()
                                            Image(systemName: selectedTags.contains(tag) ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(selectedTags.contains(tag) ? Color.accentColor : Color.secondary)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 240)

                    HStack {
                        Spacer()
                        Button("Done") {
                            isPresented = false
                        }
                    }
                }
                .padding(12)
                .frame(width: 340)
            }
        }
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredTags: [String] {
        guard !trimmedSearchText.isEmpty else { return tags }
        return tags.filter { $0.localizedCaseInsensitiveContains(trimmedSearchText) }
    }

    private var canCreateTag: Bool {
        !trimmedSearchText.isEmpty && !tags.contains { $0.caseInsensitiveCompare(trimmedSearchText) == .orderedSame }
    }

    private func createTag() {
        guard canCreateTag else { return }
        if onCreateTag(trimmedSearchText) {
            selectedTags.insert(trimmedSearchText)
            searchText = ""
        }
    }

    private func toggle(_ tag: String) {
        if selectedTags.contains(tag) {
            selectedTags.remove(tag)
        } else {
            selectedTags.insert(tag)
        }
    }
}

private struct SearchCreationField: View {
    var placeholder: String
    @Binding var text: String
    var canCreate: Bool
    var create: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if canCreate {
                        create()
                    }
                }

            Button(action: create) {
                Image(systemName: "plus.circle.fill")
                    .imageScale(.large)
            }
            .buttonStyle(.borderless)
            .disabled(!canCreate)
        }
    }
}

private struct CredentialEditor: View {
    @Binding var payload: CredentialPayload

    var body: some View {
        Section("Fields") {
            TextField("Username", text: $payload.username)
            SecureField("Password", text: $payload.password)
            TextField("Token", text: $payload.token)
            TextField("App ID", text: $payload.appId)
            TextField("Access Key", text: $payload.accessKey)
            SecureField("Secret Key", text: $payload.secretKey)
            TextField("Notes", text: $payload.notes, axis: .vertical)
        }
        AccountsEditor(accounts: $payload.accounts, title: "Accounts", emptyText: "No accounts.")
    }
}

private struct ServerEditor: View {
    @Binding var payload: ServerPayload

    var body: some View {
        Section("Fields") {
            TextField("Name", text: $payload.name)
            TextField("IP Address", text: $payload.ipAddress)
            TextField("Port", text: $payload.port)
            TextField("Username", text: $payload.username)
            SecureField("Password", text: $payload.password)
            TextField("Account ID", text: Binding(
                get: { payload.accountId ?? "" },
                set: { payload.accountId = $0.isEmpty ? nil : $0 }
            ))
            TextField("Basic Config", text: $payload.basicConfig, axis: .vertical)
            TextField("Operating System", text: $payload.operatingSystem)
            TextField("Location", text: $payload.location)
            TextField("Notes", text: $payload.notes, axis: .vertical)
        }

        AccountsEditor(accounts: $payload.accounts, title: "Accounts", emptyText: "No accounts.")
    }
}

private struct ServiceEditor: View {
    @Binding var payload: ServicePayload

    var body: some View {
        Section("Fields") {
            TextField("Name", text: $payload.name)
            TextField("Connection Address", text: $payload.connectionAddress)
            TextField("Connection Port", text: $payload.connectionPort)
            TextField("Account ID", text: Binding(
                get: { payload.accountId ?? "" },
                set: { payload.accountId = $0.isEmpty ? nil : $0 }
            ))
            TextField("Server IDs", text: Binding(
                get: { payload.serverIds.joined(separator: ", ") },
                set: { payload.serverIds = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
            ))
            TextField("Notes", text: $payload.notes, axis: .vertical)
        }

        AccountsEditor(accounts: $payload.accounts, title: "Service Accounts", emptyText: "No service accounts.")
    }
}

private extension VaultPayload {
    var hasLegacyEditorValues: Bool {
        switch self {
        case .credential(let payload):
            payload.accounts.isEmpty == false
                || payload.username.hasEditorValue
                || payload.password.hasEditorValue
                || payload.token.hasEditorValue
                || payload.appId.hasEditorValue
                || payload.accessKey.hasEditorValue
                || payload.secretKey.hasEditorValue
                || payload.notes.hasEditorValue
        case .server(let payload):
            payload.accounts.isEmpty == false
                || payload.name.hasEditorValue
                || payload.ipAddress.hasEditorValue
                || payload.port.hasEditorValue
                || payload.username.hasEditorValue
                || payload.password.hasEditorValue
                || payload.basicConfig.hasEditorValue
                || payload.operatingSystem.hasEditorValue
                || payload.location.hasEditorValue
                || payload.notes.hasEditorValue
        case .service(let payload):
            payload.accounts.isEmpty == false
                || payload.name.hasEditorValue
                || payload.connectionAddress.hasEditorValue
                || payload.connectionPort.hasEditorValue
                || (payload.accountId?.hasEditorValue ?? false)
                || payload.serverIds.contains { $0.hasEditorValue }
                || payload.notes.hasEditorValue
        }
    }
}

private extension String {
    var hasEditorValue: Bool {
        !trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct AccountsEditor: View {
    @Binding var accounts: [ServiceAccount]
    var title: String
    var emptyText: String

    var body: some View {
        Section(title) {
            if accounts.isEmpty {
                Text(emptyText)
                    .foregroundStyle(.secondary)
            }

            ForEach($accounts) { $account in
                AccountEditor(
                    account: $account,
                    title: accountTitle(for: account.id),
                    remove: { removeAccount(id: account.id) }
                )
            }

            Button(action: addAccount) {
                Label("Add Account", systemImage: "plus")
            }
        }
    }

    private func addAccount() {
        accounts.append(ServiceAccount())
    }

    private func removeAccount(id: UUID) {
        accounts.removeAll { $0.id == id }
    }

    private func accountTitle(for id: UUID) -> String {
        let index = accounts.firstIndex { $0.id == id } ?? 0
        return "Account \(index + 1)"
    }
}

private struct AccountEditor: View {
    @Binding var account: ServiceAccount
    var title: String
    var remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive, action: remove) {
                    Label("Remove Account", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
            }
            TextField("Username", text: $account.username)
            SecureField("Password", text: $account.password)
            TextField("Note", text: $account.note, axis: .vertical)
        }
    }
}
