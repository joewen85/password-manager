import SwiftUI

struct EntryEditorView: View {
    var entry: VaultEntry?
    var initialCategory: String
    var categories: [String]
    var categoryTemplates: [CategoryTemplate]
    var tags: [String]
    var onCreateCategory: (String, CategoryTypePreset?, [String]) -> Bool
    var onCreateTag: (String) -> Bool
    var onSave: (EntryDraft) -> Void
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
        tags: [String],
        onCreateCategory: @escaping (String, CategoryTypePreset?, [String]) -> Bool = { _, _, _ in false },
        onCreateTag: @escaping (String) -> Bool = { _ in false },
        onSave: @escaping (EntryDraft) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.entry = entry
        self.initialCategory = initialCategory
        self.categories = categories
        self.categoryTemplates = categoryTemplates
        self.tags = tags
        self.onCreateCategory = onCreateCategory
        self.onCreateTag = onCreateTag
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
                Section(L10n.t("Overview")) {
                    TextField(L10n.t("Label"), text: $draft.label)

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

                Section {
                    TagMultiSelectField(
                        selectedTags: $selectedTags,
                        tags: availableTags,
                        onCreateTag: createTag
                    )
                }

                if usesTemplateFields {
                    TemplateFieldsEditor(fields: $draft.customFields)
                } else {
                    switch draft.payload {
                    case .credential:
                        CredentialEditor(payload: $draft.credential)
                    case .server:
                        ServerEditor(payload: $draft.server)
                    case .service:
                        ServiceEditor(payload: $draft.service)
                    }

                    CustomFieldsEditor(fields: $draft.customFields)
                }
            }
            .formStyle(.grouped)
            .padding()

            Divider()

            HStack {
                Button(L10n.t("Cancel"), action: onCancel)
                Spacer()
                Button(entry == nil ? L10n.t("Add Entry") : L10n.t("Save Changes")) {
                    draft.tags = selectedTags.sorted()
                    onSave(draft)
                }
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

    private func resetDraft(from entry: VaultEntry?) {
        let nextDraft: EntryDraft
        if let entry {
            var draft = EntryDraft(entry: entry)
            if Self.shouldUseTemplateFields(
                for: draft,
                isCreating: false,
                in: categoryTemplates
            ), let fields = Self.categoryTemplateFields(for: draft.category, in: categoryTemplates) {
                draft.configureTemplateFields(fields)
            }
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
            taxonomyMessage = L10n.t("Category added.")
            return true
        } else {
            taxonomyMessage = L10n.t("Category could not be added.")
            return false
        }
    }

    private func createTag(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if onCreateTag(value) {
            availableTags = mergedValues(availableTags + [value])
            selectedTags.insert(value)
            taxonomyMessage = L10n.t("Tag added.")
            return true
        } else {
            taxonomyMessage = L10n.t("Tag could not be added.")
            return false
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
            fields = CategoryTemplate.defaultCategoryFields()
        } else {
            return
        }
        draft.configureTemplateFields(fields)
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
            ?? CategoryTemplate.defaultCategoryFields()
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
            Text(L10n.t("Category"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                isPresented.toggle()
            } label: {
                HStack {
                    Text(selectedCategory.isEmpty ? L10n.t("Uncategorized") : selectedCategory)
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
                        placeholder: L10n.t("Search categories"),
                        text: $searchText,
                        canCreate: canCreateCategory,
                        create: createCategory
                    )

                    if canCreateCategory {
                        CategoryPresetShortcutButtons(fields: $customFields)
                        CategoryTemplateFieldNameEditor(fields: $customFields)
                    }

                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            categoryRow(label: L10n.t("Uncategorized"), value: "")

                            if filteredCategories.isEmpty {
                                Text(L10n.t("No matching categories"))
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

private struct TagMultiSelectField: View {
    @Binding var selectedTags: Set<String>
    var tags: [String]
    var onCreateTag: (String) -> Bool

    @State private var isPresented = false
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("Selected tags"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                isPresented.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text(selectedTags.isEmpty ? L10n.t("Select tags") : selectedTags.sorted().joined(separator: ", "))
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
                        placeholder: L10n.t("Search tags"),
                        text: $searchText,
                        canCreate: canCreateTag,
                        create: createTag
                    )

                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            if filteredTags.isEmpty {
                                Text(tags.isEmpty ? L10n.t("No tags yet.") : L10n.t("No matching tags"))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 8)
                            } else {
                                ForEach(filteredTags, id: \.self) { tag in
                                    Toggle(tag, isOn: Binding(
                                        get: { selectedTags.contains(tag) },
                                        set: { isSelected in
                                            if isSelected {
                                                selectedTags.insert(tag)
                                            } else {
                                                selectedTags.remove(tag)
                                            }
                                        }
                                    ))
                                    .toggleStyle(.checkbox)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 240)

                    HStack {
                        Spacer()
                        Button(L10n.t("Done")) {
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
            .help(L10n.t("Create"))
            .disabled(!canCreate)
        }
    }
}

private struct CredentialEditor: View {
    @Binding var payload: CredentialPayload

    var body: some View {
        Section(L10n.t("Fields")) {
            TextField(L10n.t("Username"), text: $payload.username)
            SecureField(L10n.t("Password"), text: $payload.password)
            TextField(L10n.t("Token"), text: $payload.token)
            TextField(L10n.t("App ID"), text: $payload.appId)
            TextField(L10n.t("Access Key"), text: $payload.accessKey)
            SecureField(L10n.t("Secret Key"), text: $payload.secretKey)
            TextField(L10n.t("Notes"), text: $payload.notes, axis: .vertical)
        }

        ServiceAccountsEditor(title: L10n.t("Credential Accounts"), emptyMessage: L10n.t("No accounts."), accounts: $payload.accounts)
    }
}

private struct ServerEditor: View {
    @Binding var payload: ServerPayload

    var body: some View {
        Section(L10n.t("Fields")) {
            TextField(L10n.t("Name"), text: $payload.name)
            TextField(L10n.t("IP Address"), text: $payload.ipAddress)
            TextField(L10n.t("Port"), text: $payload.port)
            TextField(L10n.t("Username"), text: $payload.username)
            SecureField(L10n.t("Password"), text: $payload.password)
            TextField(L10n.t("Basic Config"), text: $payload.basicConfig, axis: .vertical)
            TextField(L10n.t("Operating System"), text: $payload.operatingSystem)
            TextField(L10n.t("Location"), text: $payload.location)
            TextField(L10n.t("Notes"), text: $payload.notes, axis: .vertical)
        }

        ServiceAccountsEditor(title: L10n.t("Server Accounts"), emptyMessage: L10n.t("No accounts."), accounts: $payload.accounts)
    }
}

private struct ServiceEditor: View {
    @Binding var payload: ServicePayload

    var body: some View {
        Section(L10n.t("Fields")) {
            TextField(L10n.t("Name"), text: $payload.name)
            TextField(L10n.t("Connection Address"), text: $payload.connectionAddress)
            TextField(L10n.t("Connection Port"), text: $payload.connectionPort)
            TextField(L10n.t("Account ID"), text: Binding(
                get: { payload.accountId ?? "" },
                set: { payload.accountId = $0.isEmpty ? nil : $0 }
            ))
            TextField(L10n.t("Server IDs"), text: Binding(
                get: { payload.serverIds.joined(separator: ", ") },
                set: { payload.serverIds = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
            ))
            TextField(L10n.t("Notes"), text: $payload.notes, axis: .vertical)
        }

        ServiceAccountsEditor(title: L10n.t("Service Accounts"), emptyMessage: L10n.t("No service accounts."), accounts: $payload.accounts)
    }
}

private struct ServiceAccountsEditor: View {
    var title: String
    var emptyMessage: String
    @Binding var accounts: [ServiceAccount]

    var body: some View {
        Section(title) {
            if accounts.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
            }

            ForEach(accounts.indices, id: \.self) { index in
                ServiceAccountEditor(
                    account: $accounts[index],
                    title: L10n.tf("Account %d", index + 1),
                    remove: { removeAccount(at: index) }
                )
            }

            Button(action: addAccount) {
                Label(L10n.t("Add Account"), systemImage: "plus")
            }
        }
    }

    private func addAccount() {
        accounts.append(ServiceAccount())
    }

    private func removeAccount(at index: Int) {
        guard accounts.indices.contains(index) else { return }
        accounts.remove(at: index)
    }
}

private struct CustomFieldsEditor: View {
    @Binding var fields: [CustomField]

    var body: some View {
        Section(L10n.t("Fields")) {
            if fields.isEmpty {
                Text(L10n.t("No custom fields."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(fields.indices, id: \.self) { index in
                    CustomFieldRow(field: $fields[index], showsValue: true, remove: { remove(at: index) })
                }
            }

            Button(action: addField) {
                Label(L10n.t("Add Field"), systemImage: "plus")
            }
        }
    }

    private func addField() {
        fields.append(CustomField())
    }

    private func remove(at index: Int) {
        guard fields.indices.contains(index) else { return }
        fields.remove(at: index)
    }
}

private struct TemplateFieldsEditor: View {
    @Binding var fields: [CustomField]

    var body: some View {
        Section(L10n.t("Fields")) {
            if fields.isEmpty {
                Text(L10n.t("No custom fields."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(fields.indices, id: \.self) { index in
                    CustomFieldRow(field: $fields[index], showsValue: true, remove: { remove(at: index) })
                }
            }

            Button(action: addField) {
                Label(L10n.t("Add Field"), systemImage: "plus")
            }
        }
    }

    private func addField() {
        fields.append(CustomField())
    }

    private func remove(at index: Int) {
        guard fields.indices.contains(index) else { return }
        fields.remove(at: index)
    }
}

private struct ServiceAccountEditor: View {
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
                    Label(L10n.t("Remove Account"), systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .help(L10n.t("Remove Account"))
            }
            TextField(L10n.t("Username"), text: $account.username)
            SecureField(L10n.t("Password"), text: $account.password)
            TextField(L10n.t("Note"), text: $account.note, axis: .vertical)
        }
    }
}

private struct CustomFieldRow: View {
    @Binding var field: CustomField
    var showsValue: Bool
    var remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("Field Name"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField(L10n.t("Field Name"), text: $field.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 160)
                }
                Spacer()
                Button(role: .destructive, action: remove) {
                    Label(L10n.t("Remove Field"), systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .help(L10n.t("Remove Field"))
            }

            if showsValue {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("Field Value"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField(L10n.t("Field Value"), text: $field.value, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
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
