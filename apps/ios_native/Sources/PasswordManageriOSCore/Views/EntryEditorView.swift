import SwiftUI

struct EntryEditorView: View {
    var entry: VaultEntry?
    var categories: [String]
    var tags: [String]
    var onSave: (EntryDraft) -> Void
    var onCancel: () -> Void

    @State private var draft: EntryDraft
    @State private var tagsText = ""

    init(
        entry: VaultEntry?,
        categories: [String],
        tags: [String],
        onSave: @escaping (EntryDraft) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.entry = entry
        self.categories = categories
        self.tags = tags
        self.onSave = onSave
        self.onCancel = onCancel
        let initialDraft = entry.map(EntryDraft.init(entry:)) ?? EntryDraft()
        _draft = State(initialValue: initialDraft)
        _tagsText = State(initialValue: initialDraft.tags.joined(separator: ", "))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Label", text: $draft.label)

                Picker("Type", selection: $draft.type) {
                    ForEach(VaultEntryType.allCases) { type in
                        Label(type.title, systemImage: type.systemImage)
                            .tag(type)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Category", text: Binding(
                    get: { draft.category },
                    set: { draft.category = $0 }
                ))
                TextField("Tags", text: $tagsText)

                switch draft.type {
                case .credential:
                    CredentialEditor(payload: $draft.credential)
                case .server:
                    ServerEditor(payload: $draft.server)
                case .service:
                    ServiceEditor(payload: $draft.service)
                }
            }
            .formStyle(.grouped)
            .padding()

            Divider()

            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button(entry == nil ? "Add Entry" : "Save Changes") {
                    draft.tags = tagsText
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    onSave(draft)
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
    }
}

private struct CredentialEditor: View {
    @Binding var payload: CredentialPayload

    var body: some View {
        Section("Credential") {
            TextField("Username", text: $payload.username)
            SecureField("Password", text: $payload.password)
            TextField("Token", text: $payload.token)
            TextField("App ID", text: $payload.appId)
            TextField("Access Key", text: $payload.accessKey)
            SecureField("Secret Key", text: $payload.secretKey)
            TextField("Notes", text: $payload.notes, axis: .vertical)
        }
    }
}

private struct ServerEditor: View {
    @Binding var payload: ServerPayload

    var body: some View {
        Section("Server") {
            TextField("Name", text: $payload.name)
            TextField("IP Address", text: $payload.ipAddress)
            TextField("Port", text: $payload.port)
            TextField("Username", text: $payload.username)
            SecureField("Password", text: $payload.password)
            TextField("Basic Config", text: $payload.basicConfig, axis: .vertical)
            TextField("Operating System", text: $payload.operatingSystem)
            TextField("Location", text: $payload.location)
            TextField("Notes", text: $payload.notes, axis: .vertical)
        }
    }
}

private struct ServiceEditor: View {
    @Binding var payload: ServicePayload

    var body: some View {
        Section("Service") {
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
    }
}
