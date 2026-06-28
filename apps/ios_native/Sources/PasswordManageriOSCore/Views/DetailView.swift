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
                                Label(entry.payload.category.isEmpty ? "Uncategorized" : entry.payload.category, systemImage: "folder")
                                    .foregroundStyle(.secondary)
                                Text(entry.label)
                                    .font(.largeTitle.bold())
                            }
                            Spacer()
                            Button("Export") { exportEntry(entry) }
                            Button("Edit") { editEntry(entry) }
                            Button("Delete", role: .destructive) { deleteEntry(entry) }
                        }

                        DetailSection(title: "Overview") {
                            OverviewFieldsView(entry: entry)
                        }

                        DetailSection(title: "Fields") {
                            PayloadFieldsView(payload: entry.payload)
                        }

                        if !entry.customFields.isEmpty {
                            DetailSection(title: "Custom Fields") {
                                CustomFieldsView(fields: entry.customFields)
                            }
                        }
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

private struct DetailSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content
        }
    }
}

private struct OverviewFieldsView: View {
    var entry: VaultEntry

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            FieldRow("Category", entry.payload.category.isEmpty ? "Uncategorized" : entry.payload.category)
            FieldRow("Tags", entry.payload.tags.isEmpty ? "None" : entry.payload.tags.joined(separator: ", "))
            FieldRow("Updated", entry.updatedAt.formatted(date: .abbreviated, time: .shortened))
        }
    }
}

struct PayloadFieldsView: View {
    var payload: VaultPayload

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            ForEach(rows) { row in
                if row.isSecret {
                    SecretRow(row.title, row.value)
                } else {
                    FieldRow(row.title, row.value)
                }
            }
        }
    }

    private var rows: [PayloadFieldRow] {
        switch payload {
        case .credential(let credential):
            return [
                PayloadFieldRow("Username", credential.username),
                PayloadFieldRow("Password", credential.password, isSecret: true),
                PayloadFieldRow("Accounts", credential.accounts.detailText, isSecret: true),
                PayloadFieldRow("Token", credential.token),
                PayloadFieldRow("App ID", credential.appId),
                PayloadFieldRow("Access Key", credential.accessKey),
                PayloadFieldRow("Secret Key", credential.secretKey, isSecret: true),
                PayloadFieldRow("Notes", credential.notes),
            ].filter(\.hasValue)
        case .server(let server):
            return [
                PayloadFieldRow("Name", server.name),
                PayloadFieldRow("IP Address", server.ipAddress),
                PayloadFieldRow("Port", server.port),
                PayloadFieldRow("Username", server.username),
                PayloadFieldRow("Password", server.password, isSecret: true),
                PayloadFieldRow("Account ID", server.accountId ?? ""),
                PayloadFieldRow("Accounts", server.accounts.detailText, isSecret: true),
                PayloadFieldRow("Config", server.basicConfig),
                PayloadFieldRow("OS", server.operatingSystem),
                PayloadFieldRow("Location", server.location),
                PayloadFieldRow("Notes", server.notes),
            ].filter(\.hasValue)
        case .service(let service):
            return [
                PayloadFieldRow("Name", service.name),
                PayloadFieldRow("Address", service.connectionAddress),
                PayloadFieldRow("Port", service.connectionPort),
                PayloadFieldRow("Account ID", service.accountId ?? ""),
                PayloadFieldRow("Servers", service.serverIds.joined(separator: ", ")),
                PayloadFieldRow("Accounts", service.accounts.detailText, isSecret: true),
                PayloadFieldRow("Notes", service.notes),
            ].filter(\.hasValue)
        }
    }
}

private struct PayloadFieldRow: Identifiable {
    let id: String
    let title: String
    let value: String
    let isSecret: Bool

    init(_ title: String, _ value: String, isSecret: Bool = false) {
        self.id = title
        self.title = title
        self.value = value
        self.isSecret = isSecret
    }

    var hasValue: Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct CustomFieldsView: View {
    var fields: [CustomField]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            ForEach(fields) { field in
                FieldRow(field.name, field.value)
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
    @State private var isRevealed = false

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(displayValue)
                    .fontDesign(isRevealed ? .default : .monospaced)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    isRevealed.toggle()
                } label: {
                    Label(isRevealed ? "Hide" : "Reveal", systemImage: isRevealed ? "eye.slash" : "eye")
                }
                .labelStyle(.iconOnly)
                .disabled(value.isEmpty)
            }
        }
    }

    private var displayValue: String {
        guard !value.isEmpty else { return "-" }
        return isRevealed ? value : String(repeating: "*", count: min(max(value.count, 8), 24))
    }
}

private extension Array where Element == ServiceAccount {
    var detailText: String {
        map { account in
            let suffix = account.note.isEmpty ? "" : " - \(account.note)"
            return "\(account.username): \(account.password)\(suffix)"
        }
        .joined(separator: "\n")
    }
}
