import SwiftUI

struct EntryReferencePickerView: View {
    let fieldName: String
    let currentValue: String
    let targetCategory: String
    let entries: [VaultEntry]
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.tf(
                    "Target Category: %@",
                    targetCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? L10n.t("Any Category")
                        : targetCategory.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
                .font(.callout)
                .foregroundStyle(.secondary)

                TextField(L10n.t("Search entries"), text: $searchText)
                    .textFieldStyle(.roundedBorder)

                if !currentValue.isEmpty {
                    Button {
                        onSelect("")
                    } label: {
                        Label(L10n.t("Clear Reference"), systemImage: "xmark.circle")
                    }
                }

                Divider()

                if candidates.isEmpty {
                    ContentUnavailableView(
                        L10n.t("No matching entries"),
                        systemImage: "magnifyingglass"
                    )
                } else {
                    List(candidates) { candidate in
                        Button {
                            onSelect(candidate.id)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "link")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(candidate.label.isEmpty ? L10n.t("Untitled") : candidate.label)
                                        .foregroundStyle(.primary)
                                    Text(candidate.category.isEmpty ? L10n.t("Uncategorized") : candidate.category)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if candidate.id == currentValue {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.inset)
                }
            }
            .padding()
            .navigationTitle(
                fieldName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? L10n.t("Choose Entry")
                    : L10n.tf("Choose Entry - %@", fieldName.trimmingCharacters(in: .whitespacesAndNewlines))
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel"), action: onCancel)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 440)
    }

    private var candidates: [EntryReferenceCandidate] {
        entryReferenceCandidates(
            entries: entries,
            targetCategory: targetCategory,
            query: searchText
        )
    }
}

struct EntryReferenceFieldEditor: View {
    @Binding var field: CustomField
    let template: CategoryTemplate
    let entries: [VaultEntry]

    @State private var isSelecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(field.name.isEmpty ? L10n.t("Custom Field") : field.name)
                    .font(.callout.weight(.medium))
                Spacer()
                Label(L10n.t("Entry Reference"), systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(statusText)
                .font(.callout)
                .foregroundStyle(isFailure ? .red : .secondary)

            Text(L10n.tf(
                "Target Category: %@",
                targetCategory.isEmpty ? L10n.t("Any Category") : targetCategory
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button {
                    isSelecting = true
                } label: {
                    Label(actionTitle, systemImage: "link.badge.plus")
                }
                .buttonStyle(.borderedProminent)

                if !field.value.isEmpty {
                    Button {
                        field.value = ""
                    } label: {
                        Label(L10n.t("Clear Reference"), systemImage: "xmark.circle")
                    }
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
        .sheet(isPresented: $isSelecting) {
            EntryReferencePickerView(
                fieldName: field.name,
                currentValue: field.value,
                targetCategory: targetCategory,
                entries: entries,
                onSelect: { value in
                    field.value = value
                    isSelecting = false
                },
                onCancel: { isSelecting = false }
            )
        }
    }

    private var resolution: EntryReferenceResolution? {
        resolveEntryReference(field: field, template: template, entries: entries)
    }

    private var targetCategory: String {
        customFieldSemantics(field: field, template: template)
            .templateField?.targetCategory
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var statusText: String {
        entryReferenceStatusText(resolution)
    }

    private var actionTitle: String {
        entryReferenceActionTitle(resolution)
    }

    private var isFailure: Bool {
        guard let resolution else { return false }
        return resolution.status == .missing
            || resolution.status == .deleted
            || resolution.status == .categoryMismatch
    }
}

func entryReferenceStatusText(_ resolution: EntryReferenceResolution?) -> String {
    switch resolution?.status {
    case .empty, nil:
        return L10n.t("No entry selected.")
    case .resolved:
        guard let target = resolution?.target else { return L10n.t("Referenced entry is unavailable.") }
        let category = target.category.isEmpty ? L10n.t("Uncategorized") : target.category
        return "\(target.label.isEmpty ? L10n.t("Untitled") : target.label) · \(category)"
    case .missing:
        return L10n.t("Referenced entry is unavailable.")
    case .deleted:
        return L10n.t("Referenced entry was deleted.")
    case .categoryMismatch:
        return L10n.t("Referenced entry is outside the target category.")
    }
}

func entryReferenceActionTitle(_ resolution: EntryReferenceResolution?) -> String {
    switch resolution?.status {
    case .resolved:
        L10n.t("Change")
    case .missing, .deleted, .categoryMismatch:
        L10n.t("Repair")
    case .empty, nil:
        L10n.t("Select Entry")
    }
}

struct FieldReferenceFieldEditor: View {
    @Binding var field: CustomField
    let sourceCategory: String
    let templateField: FieldTemplate
    let categoryTemplates: [CategoryTemplate]
    let entries: [VaultEntry]
    let onEditCategoryFields: (String) -> Void

    @State private var isSelecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(field.name.isEmpty ? L10n.t("Custom Field") : field.name)
                    .font(.callout.weight(.medium))
                Spacer()
                Label(L10n.t("Field Reference"), systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(presentation.text)
                .font(.callout)
                .foregroundStyle(presentation.isError ? .red : .secondary)
            Text(L10n.tf(
                "Target: %@ / %@",
                targetCategory.isEmpty ? L10n.t("Unavailable Category") : targetCategory,
                targetFieldName
            ))
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
                    Button {
                        field.value = ""
                    } label: {
                        Label(L10n.t("Clear Reference"), systemImage: "xmark.circle")
                    }
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
        .sheet(isPresented: $isSelecting) {
            EntryReferencePickerView(
                fieldName: field.name,
                currentValue: field.value,
                targetCategory: targetCategory,
                entries: entries,
                onSelect: { targetID in
                    field.value = targetID
                    isSelecting = false
                },
                onCancel: { isSelecting = false }
            )
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
        ).first { $0.id == templateField.targetFieldId }?.name ?? L10n.t("Unavailable Field")
    }

    private func performPrimaryAction() {
        switch presentation.actionDestination {
        case .categoryFields:
            onEditCategoryFields(sourceCategory)
        case .entrySelection:
            isSelecting = true
        }
    }
}

struct FieldReferenceDetailRow: View {
    let entry: VaultEntry
    let field: CustomField
    let templateField: FieldTemplate
    let categoryTemplates: [CategoryTemplate]
    let entries: [VaultEntry]
    let openEntryReference: (VaultEntry) -> Void
    let updateEntryReference: (VaultEntry, String, String) -> Void
    let repairCategoryFields: (String) -> Void

    @State private var isSelecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(field.name.isEmpty ? L10n.t("Custom Field") : field.name)
                    .font(.callout.weight(.medium))
                Spacer()
                Label(L10n.t("Field Reference"), systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(presentation.text)
                .font(.callout)
                .foregroundStyle(presentation.isError ? .red : .primary)
            Text(L10n.tf(
                "Target: %@ / %@",
                targetCategory.isEmpty ? L10n.t("Unavailable Category") : targetCategory,
                targetFieldName
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            if let resolvedValue = fieldReferenceResolvedValue(resolution) {
                Text(resolvedValue)
                    .textSelection(.enabled)
            }

            HStack {
                if let liveTarget {
                    Button {
                        openEntryReference(liveTarget)
                    } label: {
                        Label(L10n.t("View Entry"), systemImage: "arrow.right.circle")
                    }
                }

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
                    Button {
                        updateEntryReference(entry, field.id, "")
                    } label: {
                        Label(L10n.t("Clear Reference"), systemImage: "xmark.circle")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .sheet(isPresented: $isSelecting) {
            EntryReferencePickerView(
                fieldName: field.name,
                currentValue: field.value,
                targetCategory: targetCategory,
                entries: entries,
                onSelect: { targetID in
                    updateEntryReference(entry, field.id, targetID)
                    isSelecting = false
                },
                onCancel: { isSelecting = false }
            )
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
        ).first { $0.id == templateField.targetFieldId }?.name ?? L10n.t("Unavailable Field")
    }

    private var liveTarget: VaultEntry? {
        guard presentation.canOpenTarget, let targetID = resolution?.target?.entryID else { return nil }
        return entries.first { $0.id == targetID && !$0.isDeleted }
    }

    private func performPrimaryAction() {
        switch presentation.actionDestination {
        case .categoryFields:
            repairCategoryFields(entry.payload.category)
        case .entrySelection:
            isSelecting = true
        }
    }
}
