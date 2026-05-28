import SwiftUI

struct ContentView: View {
    @Bindable var store: VaultStore
    @State private var selection: VaultEntry.ID?
    @State private var filter: VaultFilter = .all
    @State private var searchText = ""
    @State private var isPresentingEditor = false
    @State private var isPresentingImport = false
    @State private var isPresentingScopedImport = false
    @State private var importFileName = ""
    @State private var scopedImportFileName = ""
    @State private var importStrategy: ImportConflictStrategy = .keepCopy
    @State private var editingEntry: VaultEntry?

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
                    syncNow: store.syncNow
                )
            } content: {
                EntryListView(
                    entries: visibleEntries,
                    selection: $selection
                )
            } detail: {
                DetailView(
                    entry: selectedEntry,
                    editEntry: beginEditing,
                    deleteEntry: deleteSelectedEntry,
                    exportEntry: store.exportEntry
                )
            }
            .sheet(isPresented: $isPresentingEditor) {
                EntryEditorView(
                    entry: editingEntry,
                    categories: store.categories,
                    tags: store.tags,
                    onSave: { draft in
                        store.upsert(draft, editing: editingEntry)
                        selection = store.entries.sorted { $0.updatedAt > $1.updatedAt }.first?.id
                        isPresentingEditor = false
                    },
                    onCancel: {
                        isPresentingEditor = false
                    }
                )
                .frame(minWidth: 520, minHeight: 600)
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

    private func deleteSelectedEntry(_ entry: VaultEntry) {
        store.delete(entry)
        if selection == entry.id {
            selection = visibleEntries.first?.id
        }
    }
}
