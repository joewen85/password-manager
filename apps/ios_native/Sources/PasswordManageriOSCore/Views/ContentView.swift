import SwiftUI

struct ContentView: View {
    @Bindable var store: VaultStore
    @State private var selection: VaultEntry.ID?
    @State private var filter: VaultFilter = .all
    @State private var searchText = ""
    @State private var isPresentingEditor = false
    @State private var isPresentingImport = false
    @State private var isPresentingScopedImport = false
    @State private var isPresentingSettings = false
    @State private var isPresentingCategoryCreation = false
    @State private var isPresentingCategoryTemplateEditor = false
    @State private var importFileName = ""
    @State private var scopedImportFileName = ""
    @State private var importStrategy: ImportConflictStrategy = .keepCopy
    @State private var editingEntry: VaultEntry?
    @State private var editingCategoryTemplate = ""
    @State private var exportingEntry: VaultEntry?

    var body: some View {
        if store.isUnlocked {
            NavigationSplitView {
                SidebarView(
                    store: store,
                    filter: $filter,
                    searchText: $searchText,
                    addEntry: beginAddingEntry,
                    runBackup: store.runBackup,
                    restoreBackup: store.restoreLatestBackup,
                    exportSnapshot: store.exportSnapshot,
                    importSnapshot: { isPresentingImport = true },
                    exportCategory: store.exportCategory,
                    editCategoryFields: { category in
                        editingCategoryTemplate = category
                        isPresentingCategoryTemplateEditor = true
                    },
                    syncNow: store.syncNow,
                    createCategory: { isPresentingCategoryCreation = true },
                    showSettings: { isPresentingSettings = true }
                )
            } content: {
                EntryListView(
                    entries: visibleEntries,
                    selection: $selection
                )
            } detail: {
                DetailView(
                    entry: selectedEntry,
                    entries: store.entries,
                    categoryTemplates: store.categoryTemplates,
                    editEntry: beginEditing,
                    deleteEntry: deleteSelectedEntry,
                    exportEntry: { exportingEntry = $0 },
                    openReference: { target in
                        filter = .all
                        searchText = ""
                        selection = target.id
                    },
                    updateReference: { entry, fieldID, targetID in
                        _ = store.updateEntryReference(
                            entryID: entry.id,
                            fieldID: fieldID,
                            targetID: targetID
                        )
                    },
                    repairCategoryFields: beginEditingCategoryFields
                )
            }
            .sheet(isPresented: $isPresentingEditor) {
                EntryEditorView(
                    entry: editingEntry,
                    initialCategory: currentCategoryFilter,
                    categories: store.categories,
                    categoryTemplates: store.categoryTemplates,
                    entries: store.entries,
                    tags: store.tags,
                    onCreateCategory: { category, preset, customFieldNames in
                        store.addCategory(category, preset: preset, customFieldNames: customFieldNames)
                    },
                    onCreateTag: store.addTag,
                    onEditCategoryFields: beginEditingCategoryFields,
                    onSave: { draft in
                        guard store.upsert(draft, editing: editingEntry) else {
                            return store.statusMessage ?? "Entry could not be saved."
                        }
                        selection = store.entries.sorted { $0.updatedAt > $1.updatedAt }.first?.id
                        isPresentingEditor = false
                        return nil
                    },
                    onCancel: {
                        isPresentingEditor = false
                    }
                )
                .frame(minWidth: 520, minHeight: 600)
            }
            .sheet(item: $exportingEntry) { entry in
                EntryExportFieldSelectionView(
                    entry: entry,
                    exportAll: {
                        store.exportEntry(entry)
                        exportingEntry = nil
                    },
                    exportSelected: { selectedFieldIDs in
                        store.exportEntry(entry, selectedFieldIDs: selectedFieldIDs)
                        exportingEntry = nil
                    }
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $isPresentingSettings) {
                SettingsView(store: store)
            }
            .sheet(isPresented: $isPresentingCategoryCreation) {
                CategoryCreationView(store: store) {
                    validateCurrentFilter()
                }
            }
            .sheet(isPresented: $isPresentingCategoryTemplateEditor) {
                CategoryTemplateEditorView(
                    store: store,
                    category: editingCategoryTemplate
                )
            }
            .sheet(isPresented: $isPresentingImport) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Import Snapshot JSON")
                        .font(.title2)
                    Text("Place a snapshot JSON file in the imports directory, then enter its file name.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextField("vault-export-YYYYMMDD-HHMMSS.json", text: $importFileName)
                    HStack {
                        Spacer()
                        Button("Cancel") {
                            isPresentingImport = false
                        }
                        Button("Import") {
                            store.importSnapshot(fileName: importFileName)
                            importFileName = ""
                            isPresentingImport = false
                        }
                        .disabled(importFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding()
                .frame(width: 460)
            }
            .sheet(isPresented: $isPresentingScopedImport) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Import Entry or Category JSON")
                        .font(.title2)
                    Text("Place an entry/category export JSON file in the imports directory, then enter its file name.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextField("entry-export-name-YYYYMMDD-HHMMSS.json", text: $scopedImportFileName)
                    Picker("Conflict Strategy", selection: $importStrategy) {
                        ForEach(ImportConflictStrategy.allCases) { strategy in
                            Text(strategy.title).tag(strategy)
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Cancel") {
                            isPresentingScopedImport = false
                        }
                        Button("Import") {
                            store.importScopedExport(fileName: scopedImportFileName, strategy: importStrategy)
                            scopedImportFileName = ""
                            isPresentingScopedImport = false
                        }
                        .disabled(scopedImportFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding()
                .frame(width: 520)
            }
            .toolbar {
                ToolbarItem {
                    Button("Import Entry/Category JSON") {
                        isPresentingScopedImport = true
                    }
                }
            }
        } else {
            UnlockView(store: store)
        }
    }

    private var visibleEntries: [VaultEntry] {
        store.filteredEntries(searchText: searchText, filter: filter)
    }

    private var selectedEntry: VaultEntry? {
        guard let selection else { return nil }
        return store.entries.first { $0.id == selection && !$0.isDeleted }
    }

    private func beginAddingEntry() {
        editingEntry = nil
        isPresentingEditor = true
    }

    private func beginEditing(_ entry: VaultEntry) {
        editingEntry = entry
        isPresentingEditor = true
    }

    private func beginEditingCategoryFields(_ category: String) {
        let normalized = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        isPresentingEditor = false
        editingCategoryTemplate = normalized
        DispatchQueue.main.async {
            isPresentingCategoryTemplateEditor = true
        }
    }

    private func deleteSelectedEntry(_ entry: VaultEntry) {
        store.delete(entry)
        if selection == entry.id {
            selection = visibleEntries.first?.id
        }
    }

    private func validateCurrentFilter() {
        switch filter {
        case .category(let category):
            if !store.categories.contains(category) {
                filter = .all
            }
        case .tag(let tag):
            if !store.tags.contains(tag) {
                filter = .all
            }
        case .all, .type:
            break
        }
    }
}

private extension ContentView {
    var currentCategoryFilter: String {
        if case .category(let category) = filter {
            return category
        }
        return ""
    }
}

private struct EntryExportFieldSelectionView: View {
    var entry: VaultEntry
    var exportAll: () -> Void
    var exportSelected: (Set<String>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedFieldIDs: Set<String> = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Choose the fields to include when exporting this entry. Fields are not selected by default because full export is available separately.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section("Fields") {
                    ForEach(entry.exportFields) { field in
                        Button {
                            toggle(field.id)
                        } label: {
                            HStack {
                                Text(field.title)
                                Spacer()
                                Image(systemName: selectedFieldIDs.contains(field.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedFieldIDs.contains(field.id) ? Color.accentColor : Color.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Choose Export Fields")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("Export All", action: exportAll)
                    Button("Export Selected") {
                        exportSelected(selectedFieldIDs)
                    }
                    .disabled(selectedFieldIDs.isEmpty)
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if selectedFieldIDs.contains(id) {
            selectedFieldIDs.remove(id)
        } else {
            selectedFieldIDs.insert(id)
        }
    }
}
