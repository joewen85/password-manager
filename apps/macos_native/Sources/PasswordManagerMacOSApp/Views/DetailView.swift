import AppKit
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
                                Label(entry.payload.category.isEmpty ? L10n.t("Uncategorized") : entry.payload.category, systemImage: "folder")
                                    .foregroundStyle(.secondary)
                                Text(entry.label)
                                    .font(.largeTitle.bold())
                            }
                            Spacer()
                            Button(L10n.t("Export")) { exportEntry(entry) }
                            Button(L10n.t("Edit")) { editEntry(entry) }
                            Button(L10n.t("Delete"), role: .destructive) { deleteEntry(entry) }
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
                ContentUnavailableView {
                    Label(L10n.t("Select an Entry"), systemImage: "sidebar.left")
                } description: {
                    Text(L10n.t("Entry details and actions appear here."))
                }
            }
        }
    }
}

private struct DetailSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t(title))
                .font(.headline)
            content
        }
    }
}

private struct OverviewFieldsView: View {
    var entry: VaultEntry

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            FieldRow("Category", entry.payload.category.isEmpty ? L10n.t("Uncategorized") : entry.payload.category)
            FieldRow("Updated", entry.updatedAt.formatted(date: .abbreviated, time: .shortened))
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
                SecretRow("Accounts", credential.accounts.detailText)
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
                SecretRow("Accounts", server.accounts.detailText)
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
                SecretRow("Accounts", service.accounts.detailText)
                FieldRow("Notes", service.notes)
            }
        }
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
            Text(L10n.t(title))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(value.isEmpty ? "-" : value)
                    .textSelection(.enabled)
                Spacer()
                CopyButton(value: value)
            }
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
            Text(L10n.t(title))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                secretText
                Spacer()
                Button {
                    isRevealed.toggle()
                } label: {
                    Label(isRevealed ? L10n.t("Hide") : L10n.t("Reveal"), systemImage: isRevealed ? "eye.slash" : "eye")
                }
                .labelStyle(.iconOnly)
                .help(isRevealed ? L10n.t("Hide") : L10n.t("Reveal"))
                .disabled(value.isEmpty)
                CopyButton(value: value)
            }
        }
    }

    @ViewBuilder
    private var secretText: some View {
        if isRevealed {
            Text(displayValue)
                .textSelection(.enabled)
        } else {
            Text(displayValue)
                .fontDesign(.monospaced)
        }
    }

    private var displayValue: String {
        guard !value.isEmpty else { return "-" }
        return isRevealed ? value : String(repeating: "*", count: min(max(value.count, 8), 24))
    }
}

private struct CopyButton: View {
    var value: String

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } label: {
            Label(L10n.t("Copy"), systemImage: "doc.on.doc")
        }
        .labelStyle(.iconOnly)
        .help(L10n.t("Copy"))
        .disabled(value.isEmpty)
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
