import SwiftUI
#if os(iOS)
import UIKit
#endif

struct ContentView: View {
    @Bindable var store: VaultStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: VaultEntry.ID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .content
    @State private var filter: VaultFilter = .all
    @State private var searchText = ""
    @State private var editorPresentation: EntryEditorPresentation?
    @State private var isPresentingImport = false
    @State private var isPresentingScopedImport = false
    @State private var isPresentingSettings = false
    @State private var isPresentingCategoryCreation = false
    @State private var isPresentingCategoryTemplateEditor = false
    @State private var importFileName = ""
    @State private var scopedImportFileName = ""
    @State private var importStrategy: ImportConflictStrategy = .keepCopy
    @State private var editingCategoryTemplate = ""
    @State private var exportingEntry: VaultEntry?

    var body: some View {
        if store.isUnlocked {
            GeometryReader { geometry in
#if os(iOS)
                let supportsResizableColumns = UIDevice.current.userInterfaceIdiom == .pad
                let isPhone = UIDevice.current.userInterfaceIdiom == .phone
#else
                let supportsResizableColumns = false
                let isPhone = false
#endif
                let usesDuoBottomActionBar = DuoToolbarLayout.usesBottomBar(
                    isPhone: isPhone,
                    isRegularWidth: horizontalSizeClass == .regular,
                    displaySize: geometry.size
                )
                let minimumListWidth = EntryListDetailLayout.minimumListWidth
                let maximumListWidth = supportsResizableColumns
                    ? max(minimumListWidth, geometry.size.width * CGFloat(EntryListDetailLayout.maximumRatio))
                    : 400
                let idealListWidth = supportsResizableColumns
                    ? min(maximumListWidth, max(minimumListWidth, geometry.size.width * CGFloat(EntryListDetailLayout.defaultRatio)))
                    : 300

                    NavigationSplitView(
                        columnVisibility: $columnVisibility,
                        preferredCompactColumn: $preferredCompactColumn
                    ) {
                        SidebarView(
                            store: store,
                            filter: $filter,
                            showEntries: showEntries,
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
                        .contentMargins(.bottom, usesDuoBottomActionBar ? 96 : nil, for: .scrollContent)
                        .navigationTitle("Vault")
                        .toolbar {
                            if horizontalSizeClass == .compact {
                                vaultToolbar
                            }
                        }
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
                    } content: {
                        EntryListView(
                            entries: visibleEntries,
                            selection: $selection
                        )
                        .contentMargins(.bottom, usesDuoBottomActionBar ? 96 : nil, for: .scrollContent)
                        .navigationTitle("Entries")
                        .toolbar {
                            if horizontalSizeClass == .compact {
                                vaultToolbar
                            }
                        }
                        .navigationSplitViewColumnWidth(
                            min: minimumListWidth,
                            ideal: idealListWidth,
                            max: maximumListWidth
                        )
                        #if os(iOS)
                        .searchable(
                            text: $searchText,
                            placement: usesDuoBottomActionBar ? .navigationBarDrawer(displayMode: .always) : .automatic,
                            prompt: "Search vault"
                        )
                        #else
                        .searchable(text: $searchText, prompt: "Search vault")
                        #endif
                    } detail: {
                        DetailView(
                            entry: selectedEntry,
                            entries: store.entries,
                            categoryTemplates: store.categoryTemplates,
                            editEntry: beginEditing,
                            deleteEntry: deleteSelectedEntry,
                            exportEntry: { exportingEntry = $0 },
                            showsToolbarActions: !usesDuoBottomActionBar,
                            openReference: { target in
                                filter = .all
                                searchText = ""
                                selection = target.id
                                preferredCompactColumn = .detail
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
                        .contentMargins(.bottom, usesDuoBottomActionBar ? 96 : nil, for: .scrollContent)
                        .navigationTitle("Entry")
                        .toolbar {
                            if !usesDuoBottomActionBar {
                                vaultToolbar
                            }
                        }
                    }
                    .navigationSplitViewStyle(.balanced)
                    .overlay(alignment: .bottom) {
                        if usesDuoBottomActionBar {
                            duoBottomActionBar
                                .frame(maxWidth: 560)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 12)
                        }
                    }
                .sheet(item: $editorPresentation) { presentation in
                    EntryEditorView(
                        entry: presentation.entry,
                        initialCategory: currentCategoryFilter,
                        categories: store.categories,
                        categoryTemplates: store.categoryTemplates,
                        entries: store.entries,
                        tags: store.tags,
                        onCreateCategory: { category, preset, customFields in
                            store.addCategory(category, preset: preset, customFields: customFields)
                        },
                        onCreateTag: store.addTag,
                        onEditCategoryFields: beginEditingCategoryFields,
                        onSave: { draft in
                            guard store.upsert(draft, editing: presentation.entry) else {
                                return store.statusMessage ?? "Entry could not be saved."
                            }
                            selection = store.entries.sorted { $0.updatedAt > $1.updatedAt }.first?.id
                            editorPresentation = nil
                            preferredCompactColumn = .detail
                            return nil
                        },
                        onCancel: {
                            editorPresentation = nil
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .sheet(item: $exportingEntry) { entry in
                    EntryExportFieldSelectionView(
                        entry: entry,
                        exportAll: {
                            store.exportEntry(entry)
                            exportingEntry = nil
                        },
                        exportSelected: { selectedFieldIDs in
                            store.exportSelectedEntryText(entry, selectedFieldIDs: selectedFieldIDs)
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
                    NavigationStack {
                        Form {
                            Text("Place a snapshot JSON file in the imports directory, then enter its file name.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            TextField("vault-export-YYYYMMDD-HHMMSS.json", text: $importFileName)
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .navigationTitle("Import Snapshot JSON")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button { isPresentingImport = false } label: {
                                    Label("Cancel", systemImage: "xmark")
                                }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button {
                                    store.importSnapshot(fileName: importFileName)
                                    importFileName = ""
                                    isPresentingImport = false
                                } label: {
                                    Label("Import", systemImage: "square.and.arrow.down")
                                }
                                .disabled(importFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                }
                .sheet(isPresented: $isPresentingScopedImport) {
                    NavigationStack {
                        Form {
                            Text("Place an entry/category export JSON file in the imports directory, then enter its file name.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            TextField("entry-export-name-YYYYMMDD-HHMMSS.json", text: $scopedImportFileName)
                            Picker("Conflict Strategy", selection: $importStrategy) {
                                ForEach(ImportConflictStrategy.allCases) { strategy in
                                    Text(strategy.title).tag(strategy)
                                }
                            }
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .navigationTitle("Import Entry or Category JSON")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button { isPresentingScopedImport = false } label: {
                                    Label("Cancel", systemImage: "xmark")
                                }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button {
                                    store.importScopedExport(fileName: scopedImportFileName, strategy: importStrategy)
                                    scopedImportFileName = ""
                                    isPresentingScopedImport = false
                                } label: {
                                    Label("Import", systemImage: "square.and.arrow.down")
                                }
                                .disabled(scopedImportFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                }
            }
        } else {
            UnlockView(store: store)
        }
    }

    @ToolbarContentBuilder
    private var vaultToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button(action: beginAddingEntry) {
                Label("Add Entry", systemImage: "plus")
            }
            Button { isPresentingScopedImport = true } label: {
                Label("Import Entry/Category JSON", systemImage: "square.and.arrow.down")
            }
            Button { store.lock() } label: {
                Label("Lock", systemImage: "lock")
            }
        }
    }

    private var duoBottomActionBar: some View {
        HStack(spacing: 4) {
            duoActionButton("Add Entry", systemImage: "plus", identifier: "duo.action.add", action: beginAddingEntry)
            duoActionButton("Import", accessibilityTitle: "Import Entry/Category JSON", systemImage: "square.and.arrow.down", identifier: "duo.action.import") {
                isPresentingScopedImport = true
            }
            duoActionButton("Lock", systemImage: "lock", identifier: "duo.action.lock", action: store.lock)
            if let selectedEntry {
                duoActionButton("Export", systemImage: "square.and.arrow.up", identifier: "duo.action.export") {
                    exportingEntry = selectedEntry
                }
                duoActionButton("Edit", systemImage: "pencil", identifier: "duo.action.edit") {
                    beginEditing(selectedEntry)
                }
                duoActionButton("Delete", systemImage: "trash", identifier: "duo.action.delete", role: .destructive) {
                    deleteSelectedEntry(selectedEntry)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("duo.action-bar")
        .modifier(DuoToolbarGlass())
        .contentShape(Capsule())
    }

    private func duoActionButton(
        _ title: LocalizedStringKey,
        accessibilityTitle: LocalizedStringKey? = nil,
        systemImage: String,
        identifier: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .regular))
                    .frame(height: 28)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(accessibilityTitle ?? title))
        .accessibilityLabel(accessibilityTitle ?? title)
        .accessibilityIdentifier(identifier)
    }

    private var visibleEntries: [VaultEntry] {
        store.filteredEntries(searchText: searchText, filter: filter)
    }

    private var selectedEntry: VaultEntry? {
        guard let selection else { return nil }
        return store.entries.first { $0.id == selection && !$0.isDeleted }
    }

    private func showEntries() {
        columnVisibility = .doubleColumn
        preferredCompactColumn = .content
    }

    private func beginAddingEntry() {
        editorPresentation = EntryEditorPresentation(entry: nil)
    }

    private func beginEditing(_ entry: VaultEntry) {
        editorPresentation = EntryEditorPresentation(entry: entry)
    }

    private func beginEditingCategoryFields(_ category: String) {
        let normalized = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        editorPresentation = nil
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

private enum EntryListDetailLayout {
    static let defaultRatio = 0.36
    static let maximumRatio = 0.50
    static let minimumListWidth: CGFloat = 240
}

enum DuoToolbarLayout {
    static func usesBottomBar(isPhone: Bool, isRegularWidth: Bool, displaySize: CGSize) -> Bool {
        isPhone && isRegularWidth && displaySize.height > displaySize.width
    }
}

private struct DuoToolbarGlass: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
        #else
        content.background(.regularMaterial, in: Capsule())
        #endif
    }
}

private struct EntryEditorPresentation: Identifiable {
    let id = UUID()
    var entry: VaultEntry?
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
                    Button { dismiss() } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button(action: exportAll) {
                        Label("Export All", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        exportSelected(selectedFieldIDs)
                    } label: {
                        Label("Export Selected", systemImage: "checkmark")
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
