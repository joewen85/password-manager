import SwiftUI

struct DetailView: View {
    var entry: VaultEntry?
    var editEntry: (VaultEntry) -> Void
    var deleteEntry: (VaultEntry) -> Void
    var exportEntry: (VaultEntry) -> Void

    var body: some View {
        Group {
            if let entry {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(entry.type.title, systemImage: entry.type.systemImage)
                                    .foregroundStyle(.secondary)
                                Text(entry.label)
                                    .font(.largeTitle.bold())
                            }
                            Spacer()
                            Button("Export") { exportEntry(entry) }
                            Button("Edit") { editEntry(entry) }
                            Button("Delete", role: .destructive) { deleteEntry(entry) }
                        }

                        PayloadFieldsView(payload: entry.payload)

                        LabeledContent("Category", value: entry.payload.category.isEmpty ? "Uncategorized" : entry.payload.category)
                        LabeledContent("Tags", value: entry.payload.tags.isEmpty ? "None" : entry.payload.tags.joined(separator: ", "))
                        LabeledContent("Updated", value: entry.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    .padding(24)
                    .frame(maxWidth: 760, alignment: .leading)
                }
            } else {
                ContentUnavailableView("Select an Entry", systemImage: "sidebar.left")
            }
        }
    }
}

struct PayloadFieldsView: View {
    var payload: VaultPayload

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            switch payload {
            case .credential(let credential):
                FieldRow("Username", credential.username)
                SecretRow("Password", credential.password)
                FieldRow("Token", credential.token)
                FieldRow("App ID", credential.appId)
                FieldRow("Access Key", credential.accessKey)
                SecretRow("Secret Key", credential.secretKey)
                FieldRow("Notes", credential.notes)
            case .server(let server):
                FieldRow("Name", server.name)
                FieldRow("IP Address", server.ipAddress)
                FieldRow("Port", server.port)
                FieldRow("Username", server.username)
                SecretRow("Password", server.password)
                FieldRow("Config", server.basicConfig)
                FieldRow("OS", server.operatingSystem)
                FieldRow("Location", server.location)
                FieldRow("Notes", server.notes)
            case .service(let service):
                FieldRow("Name", service.name)
                FieldRow("Address", service.connectionAddress)
                FieldRow("Port", service.connectionPort)
                FieldRow("Account ID", service.accountId ?? "")
                FieldRow("Servers", service.serverIds.joined(separator: ", "))
                FieldRow("Accounts", service.accounts.map(\.username).joined(separator: ", "))
                FieldRow("Notes", service.notes)
            }
        }
    }
}

private struct FieldRow: View {
    var title: String
    var value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "-" : value)
                .textSelection(.enabled)
        }
    }
}

private struct SecretRow: View {
    var title: String
    var value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            SecureField("", text: .constant(value))
                .textFieldStyle(.plain)
        }
    }
}
