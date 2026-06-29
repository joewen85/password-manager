import SwiftUI

struct TaxonomyManagementView: View {
    @Bindable var store: VaultStore
    var onChange: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var selectedKind: TaxonomyKind = .category
    @State private var newValue = ""
    @State private var categoryCustomFields: [CustomField] = []
    @State private var renameRequest: TaxonomyEditRequest?
    @State private var deleteRequest: TaxonomyEditRequest?

    private var values: [String] {
        switch selectedKind {
        case .category:
            store.categories
        case .tag:
            store.tags
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Manage", selection: $selectedKind) {
                    ForEach(TaxonomyKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 8) {
                    TextField(selectedKind.placeholder, text: $newValue)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addValue)
                    Button(action: addValue) {
                        Label("Add", systemImage: "plus")
                    }
                    .disabled(isAddDisabled)
                }

                if selectedKind == .category {
                    CategoryPresetShortcutButtons(fields: $categoryCustomFields)
                    CategoryTemplateFieldNameEditor(fields: $categoryCustomFields)
                }

                Group {
                    if values.isEmpty {
                        ContentUnavailableView(
                            L10n.tf("No %@", selectedKind.emptyLabel.capitalized),
                            systemImage: selectedKind.systemImage
                        )
                    } else {
                        List(values, id: \.self) { value in
                            HStack {
                                Label(value, systemImage: selectedKind.systemImage)
                                Spacer()
                                Button {
                                    renameRequest = TaxonomyEditRequest(kind: selectedKind, value: value)
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .labelStyle(.iconOnly)
                                .help("Rename")

                                Button(role: .destructive) {
                                    deleteRequest = TaxonomyEditRequest(kind: selectedKind, value: value)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .labelStyle(.iconOnly)
                                .help("Delete")
                            }
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                renameRequest = TaxonomyEditRequest(kind: selectedKind, value: value)
                            }
                            .contextMenu {
                                Button {
                                    renameRequest = TaxonomyEditRequest(kind: selectedKind, value: value)
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }

                                Button(role: .destructive) {
                                    deleteRequest = TaxonomyEditRequest(kind: selectedKind, value: value)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding()
            .navigationTitle("Manage Categories & Tags")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                ToolbarSpacer(.fixed)
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: addValue) {
                        Label(L10n.tf("Add %@", selectedKind.placeholder), systemImage: "plus")
                    }
                    .disabled(isAddDisabled)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 460)
        .onChange(of: selectedKind) { _, nextKind in
            if nextKind == .tag {
                categoryCustomFields = []
            }
        }
        .sheet(item: $renameRequest) { request in
            TaxonomyRenameView(store: store, request: request) {
                onChange()
            }
            .frame(width: 420, height: 180)
        }
        .alert(item: $deleteRequest) { request in
            Alert(
                title: Text(request.kind.deleteTitle),
                message: Text(request.kind.deleteMessage(for: request.value)),
                primaryButton: .destructive(Text("Delete")) {
                    deleteValue(request)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var isAddDisabled: Bool {
        newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addValue() {
        let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let didSave: Bool
        switch selectedKind {
        case .category:
            didSave = store.addCategory(
                value,
                preset: nil,
                customFieldNames: categoryCustomFields.map(\.name)
            )
        case .tag:
            didSave = store.addTag(value)
        }
        if didSave {
            newValue = ""
            categoryCustomFields = []
            onChange()
        }
    }

    private func deleteValue(_ request: TaxonomyEditRequest) {
        let didDelete: Bool
        switch request.kind {
        case .category:
            didDelete = store.deleteCategory(request.value)
        case .tag:
            didDelete = store.deleteTag(request.value)
        }
        if didDelete {
            onChange()
        }
    }
}

private struct TaxonomyRenameView: View {
    @Bindable var store: VaultStore
    let request: TaxonomyEditRequest
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var value: String

    init(store: VaultStore, request: TaxonomyEditRequest, onSaved: @escaping () -> Void) {
        self.store = store
        self.request = request
        self.onSaved = onSaved
        _value = State(initialValue: request.value)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(request.kind.placeholder, text: $value)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
            }
            .formStyle(.grouped)
            .navigationTitle(request.kind.renameTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        let didSave: Bool
        switch request.kind {
        case .category:
            didSave = store.renameCategory(request.value, to: value)
        case .tag:
            didSave = store.renameTag(request.value, to: value)
        }
        if didSave {
            onSaved()
            dismiss()
        }
    }
}

private struct TaxonomyEditRequest: Identifiable {
    let kind: TaxonomyKind
    let value: String

    var id: String { "\(kind.rawValue)|\(value)" }
}

private enum TaxonomyKind: String, CaseIterable, Identifiable {
    case category
    case tag

    var id: String { rawValue }

    var title: String {
        switch self {
        case .category: L10n.t("Categories")
        case .tag: L10n.t("Tags")
        }
    }

    var placeholder: String {
        switch self {
        case .category: L10n.t("Category")
        case .tag: L10n.t("Tag")
        }
    }

    var emptyLabel: String {
        switch self {
        case .category: L10n.t("categories")
        case .tag: L10n.t("tags")
        }
    }

    var systemImage: String {
        switch self {
        case .category: "folder"
        case .tag: "tag"
        }
    }

    var renameTitle: String {
        switch self {
        case .category: L10n.t("Rename Category")
        case .tag: L10n.t("Rename Tag")
        }
    }

    var deleteTitle: String {
        switch self {
        case .category: L10n.t("Delete Category")
        case .tag: L10n.t("Delete Tag")
        }
    }

    func deleteMessage(for value: String) -> String {
        switch self {
        case .category:
            L10n.tf("Delete category \"%@\"? Existing entries will become uncategorized.", value)
        case .tag:
            L10n.tf("Delete tag \"%@\"? Existing entries will lose this tag.", value)
        }
    }
}
