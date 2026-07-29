import SwiftUI

struct DetailView: View {
    var entry: VaultEntry?
    var entries: [VaultEntry] = []
    var categoryTemplates: [CategoryTemplate] = []
    var editEntry: (VaultEntry) -> Void
    var deleteEntry: (VaultEntry) -> Void
    var exportEntry: (VaultEntry) -> Void
    var openReference: (VaultEntry) -> Void = { _ in }
    var updateReference: (VaultEntry, String, String) -> Void = { _, _, _ in }
    var repairCategoryFields: (String) -> Void = { _ in }

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
                                CustomFieldsView(
                                    entry: entry,
                                    entries: entries,
                                    template: categoryTemplate(for: entry.payload.category),
                                    categoryTemplates: categoryTemplates,
                                    openReference: openReference,
                                    updateReference: updateReference,
                                    repairCategoryFields: repairCategoryFields
                                )
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

    private func categoryTemplate(for category: String) -> CategoryTemplate? {
        let normalized = category.trimmingCharacters(in: .whitespacesAndNewlines)
        return categoryTemplates.first {
            $0.category.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(normalized) == .orderedSame
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
    var entry: VaultEntry
    var entries: [VaultEntry]
    var template: CategoryTemplate?
    var categoryTemplates: [CategoryTemplate]
    var openReference: (VaultEntry) -> Void
    var updateReference: (VaultEntry, String, String) -> Void
    var repairCategoryFields: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(entry.customFields) { field in
                let semantics = customFieldSemantics(field: field, template: template)
                switch semantics.semantic {
                case .text:
                    Grid(alignment: .leading, horizontalSpacing: 16) {
                        FieldRow(field.name, field.value)
                    }
                case .unsupported:
                    UnsupportedCustomFieldRow(name: field.name)
                case .entryReference:
                    if let templateField = semantics.templateField {
                        EntryReferenceDetailRow(
                            entry: entry,
                            field: field,
                            templateField: templateField,
                            template: template,
                            entries: entries,
                            openReference: openReference,
                            updateReference: updateReference
                        )
                    }
                case .fieldReference:
                    if let templateField = semantics.templateField {
                        FieldReferenceDetailRow(
                            entry: entry,
                            field: field,
                            templateField: templateField,
                            categoryTemplates: categoryTemplates,
                            entries: entries,
                            openReference: openReference,
                            updateReference: updateReference,
                            repairCategoryFields: repairCategoryFields
                        )
                    }
                }
            }
        }
    }
}

private struct FieldReferenceDetailRow: View {
    var entry: VaultEntry
    var field: CustomField
    var templateField: FieldTemplate
    var categoryTemplates: [CategoryTemplate]
    var entries: [VaultEntry]
    var openReference: (VaultEntry) -> Void
    var updateReference: (VaultEntry, String, String) -> Void
    var repairCategoryFields: (String) -> Void

    @State private var isPresentingSelection = false
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(templateField.name.isEmpty ? "Field Reference" : templateField.name)
                    .foregroundStyle(.secondary)
                Spacer()
                Label("Field Reference", systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(presentation.text)
                .foregroundStyle(presentation.isError ? .red : .primary)
            Text("Target: \(targetCategory.isEmpty ? "Unavailable Category" : targetCategory) / \(targetFieldName)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let resolvedValue = fieldReferenceResolvedValue(resolution) {
                Text(resolvedValue)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                if let targetEntry {
                    Button("View") { openReference(targetEntry) }
                        .buttonStyle(.bordered)
                }
                Button(presentation.actionTitle, action: performPrimaryAction)
                    .buttonStyle(.borderedProminent)
                    .popover(isPresented: $isPresentingSelection, arrowEdge: .bottom) {
                        selectionContent
                    }
                if !field.value.isEmpty {
                    Button("Clear", role: .destructive) {
                        updateReference(entry, field.id, "")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var resolution: FieldReferenceResolution? {
        resolveFieldReference(
            sourceEntry: entry,
            field: field,
            categoryTemplates: categoryTemplates,
            entries: entries
        )
    }

    private var presentation: FieldReferencePresentation {
        guard fieldReferenceTemplateConfigurationIsValid(
            sourceCategory: entry.payload.category,
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
            sourceCategory: entry.payload.category,
            sourceField: templateField,
            templates: categoryTemplates
        ).first { $0.id == templateField.targetFieldId }?.name ?? "Unavailable Field"
    }

    private var targetEntry: VaultEntry? {
        guard presentation.canOpenTarget, let targetID = resolution?.target?.entryID else { return nil }
        return entries.first { $0.id == targetID && !$0.isDeleted }
    }

    private var candidates: [EntryReferenceCandidate] {
        entryReferenceCandidates(entries: entries, targetCategory: targetCategory, query: searchText)
    }

    private func performPrimaryAction() {
        switch presentation.actionDestination {
        case .categoryFields:
            repairCategoryFields(entry.payload.category)
        case .entrySelection:
            isPresentingSelection = true
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
                                updateReference(entry, field.id, candidate.id)
                                searchText = ""
                                isPresentingSelection = false
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

private struct UnsupportedCustomFieldRow: View {
    var name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name.isEmpty ? "Custom Field" : name)
                .foregroundStyle(.secondary)
            Text("This field is not supported by this version. Its stored value is preserved.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct EntryReferenceDetailRow: View {
    var entry: VaultEntry
    var field: CustomField
    var templateField: FieldTemplate
    var template: CategoryTemplate?
    var entries: [VaultEntry]
    var openReference: (VaultEntry) -> Void
    var updateReference: (VaultEntry, String, String) -> Void

    @State private var isPresentingSelection = false
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(templateField.name.isEmpty ? "Entry Reference" : templateField.name)
                .foregroundStyle(.secondary)
            Text(presentation.text)
                .foregroundStyle(statusColor)

            HStack(spacing: 8) {
                if let targetEntry {
                    Button("View") {
                        openReference(targetEntry)
                    }
                    .buttonStyle(.bordered)
                }

                Button(presentation.actionTitle) {
                    isPresentingSelection = true
                }
                .buttonStyle(.borderedProminent)
                .popover(isPresented: $isPresentingSelection, arrowEdge: .bottom) {
                    selectionContent
                }

                if !field.value.isEmpty {
                    Button("Clear", role: .destructive) {
                        updateReference(entry, field.id, "")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var resolution: EntryReferenceResolution? {
        resolveEntryReference(field: field, template: template, entries: entries)
    }

    private var targetEntry: VaultEntry? {
        guard presentation.canOpenTarget, let targetID = resolution?.target?.id else { return nil }
        return entries.first { $0.id == targetID && !$0.isDeleted }
    }

    private var presentation: EntryReferencePresentation {
        entryReferencePresentation(resolution)
    }

    private var statusColor: Color {
        presentation.isError ? .red : (resolution?.status == .resolved ? .primary : .secondary)
    }

    private var candidates: [EntryReferenceCandidate] {
        entryReferenceCandidates(
            entries: entries,
            targetCategory: templateField.targetCategory,
            query: searchText
        )
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
                                updateReference(entry, field.id, candidate.id)
                                searchText = ""
                                isPresentingSelection = false
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
        }
        .padding(12)
        .frame(width: 340)
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
