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

                        if entry.payload.hasDisplayFields || !entry.customFields.isEmpty {
                            DetailSection(title: "Fields") {
                                VStack(alignment: .leading, spacing: 12) {
                                    if entry.payload.hasDisplayFields {
                                        PayloadFieldsView(payload: entry.payload)
                                    }
                                    if !entry.customFields.isEmpty {
                                        CustomFieldsView(fields: entry.customFields)
                                    }
                                }
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

private extension VaultPayload {
    var hasDisplayFields: Bool {
        switch self {
        case .credential(let payload):
            payload.accounts.isEmpty == false
                || payload.username.hasDisplayValue
                || payload.password.hasDisplayValue
                || payload.token.hasDisplayValue
                || payload.appId.hasDisplayValue
                || payload.accessKey.hasDisplayValue
                || payload.secretKey.hasDisplayValue
                || payload.notes.hasDisplayValue
        case .server(let payload):
            payload.accounts.isEmpty == false
                || payload.name.hasDisplayValue
                || payload.ipAddress.hasDisplayValue
                || payload.port.hasDisplayValue
                || payload.username.hasDisplayValue
                || payload.password.hasDisplayValue
                || payload.basicConfig.hasDisplayValue
                || payload.operatingSystem.hasDisplayValue
                || payload.location.hasDisplayValue
                || payload.notes.hasDisplayValue
        case .service(let payload):
            payload.accounts.isEmpty == false
                || payload.name.hasDisplayValue
                || payload.connectionAddress.hasDisplayValue
                || payload.connectionPort.hasDisplayValue
                || (payload.accountId?.hasDisplayValue ?? false)
                || payload.serverIds.contains { $0.hasDisplayValue }
                || payload.notes.hasDisplayValue
        }
    }
}

private extension String {
    var hasDisplayValue: Bool {
        !trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
