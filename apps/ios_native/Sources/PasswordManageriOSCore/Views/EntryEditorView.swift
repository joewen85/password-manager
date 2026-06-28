import SwiftUI

struct EntryEditorView: View {
    var entry: VaultEntry?
    var categories: [String]
    var tags: [String]
    var onCreateCategory: (String, CategoryTypePreset?) -> Bool
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
        categories: [String],
        tags: [String],
        onCreateCategory: @escaping (String, CategoryTypePreset?) -> Bool = { _, _ in false },
        onCreateTag: @escaping (String) -> Bool = { _ in false },
        onSave: @escaping (EntryDraft) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.entry = entry
        self.categories = categories
        self.tags = tags
        self.onCreateCategory = onCreateCategory
        self.onCreateTag = onCreateTag
        self.onSave = onSave
        self.onCancel = onCancel
        let initialDraft = entry.map(EntryDraft.init(entry:)) ?? EntryDraft()
        _draft = State(initialValue: initialDraft)
        _selectedTags = State(initialValue: Set(initialDraft.tags))
        _availableCategories = State(initialValue: categories)
        _availableTags = State(initialValue: tags)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Overview") {
                    TextField("Label", text: $draft.label)

                    Picker("Type", selection: $draft.type) {
                        ForEach(VaultEntryType.allCases) { type in
                            Label(type.title, systemImage: type.systemImage)
                                .tag(type)
                        }
                    }
                    .pickerStyle(.segmented)

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

                Section("Tags") {
                    TagMultiSelectField(
                        selectedTags: $selectedTags,
                        tags: availableTags,
                        onCreateTag: createTag
                    )
                }

                switch draft.type {
                case .credential:
                    CredentialEditor(payload: $draft.credential)
                case .server:
                    ServerEditor(payload: $draft.server)
                case .service:
                    ServiceEditor(payload: $draft.service)
                }

                CustomFieldsEditor(fields: $draft.customFields)
            }
            .formStyle(.grouped)
            .padding()

            Divider()

            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button(entry == nil ? "Add Entry" : "Save Changes") {
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
        let nextDraft = entry.map(EntryDraft.init(entry:)) ?? EntryDraft()
        draft = nextDraft
        selectedTags = Set(nextDraft.tags)
        taxonomyMessage = nil
    }

    private func createCategory(_ value: String, preset: CategoryTypePreset?) -> Bool {
        guard !value.isEmpty else { return false }
        if onCreateCategory(value, preset) {
            availableCategories = mergedValues(availableCategories + [value])
            draft.category = value
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

    private func mergedValues(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }
}

private struct CategorySelectField: View {
    @Binding var selectedCategory: String
    var categories: [String]
    var onCreateCategory: (String, CategoryTypePreset?) -> Bool

    @State private var isPresented = false
    @State private var searchText = ""
    @State private var selectedPreset: CategoryTypePreset?

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

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Field shortcuts")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            ForEach(CategoryTypePreset.allCases) { preset in
                                Button {
                                    selectedPreset = selectedPreset == preset ? nil : preset
                                } label: {
                                    Text(preset.title)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(selectedPreset == preset ? .accentColor : .gray)
                            }
                        }
                        Text("New categories use only Name and Notes unless a shortcut is selected.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
        if onCreateCategory(trimmedSearchText, selectedPreset) {
            selectedCategory = trimmedSearchText
            searchText = ""
            selectedPreset = nil
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

            ForEach(accounts.indices, id: \.self) { index in
                AccountEditor(
                    account: $accounts[index],
                    title: "Account \(index + 1)",
                    remove: { removeAccount(at: index) }
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

    private func removeAccount(at index: Int) {
        guard accounts.indices.contains(index) else { return }
        accounts.remove(at: index)
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

private struct CustomFieldsEditor: View {
    @Binding var fields: [CustomField]

    var body: some View {
        Section("Custom Fields") {
            if fields.isEmpty {
                Text("No custom fields.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach($fields) { $field in
                    HStack(alignment: .top, spacing: 8) {
                        TextField("Field Name", text: $field.name)
                        TextField("Field Value", text: $field.value, axis: .vertical)
                        Button(role: .destructive) {
                            remove(field.id)
                        } label: {
                            Label("Remove Field", systemImage: "trash")
                        }
                        .labelStyle(.iconOnly)
                    }
                }
            }

            Button(action: addField) {
                Label("Add Field", systemImage: "plus")
            }
        }
    }

    private func addField() {
        fields.append(CustomField())
    }

    private func remove(_ id: UUID) {
        fields.removeAll { $0.id == id }
    }
}
