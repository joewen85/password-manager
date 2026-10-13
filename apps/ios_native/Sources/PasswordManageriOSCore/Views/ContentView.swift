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
    @State private var duoNavigationPath: [String] = []
    @State private var isDuoCategoryTabBarVisible = true
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
                let usesDuoExpandedPortraitLayout = DuoToolbarLayout.usesExpandedPortraitLayout(
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

                Group {
                    if usesDuoExpandedPortraitLayout {
                        duoExpandedPortraitNavigation
                    } else {
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
                            .searchable(text: $searchText, prompt: "Search vault")
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
                                showsToolbarActions: true,
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
                            .navigationTitle("Entry")
                            .toolbar {
                                vaultToolbar
                            }
                        }
                        .navigationSplitViewStyle(.balanced)
                    }
                }
                .onChange(of: usesDuoExpandedPortraitLayout) { _, isExpandedPortrait in
                    if !isExpandedPortrait {
                        duoNavigationPath = []
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
                            if usesDuoExpandedPortraitLayout, let selection {
                                duoNavigationPath = [selection]
                            }
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

    private var duoExpandedPortraitNavigation: some View {
        NavigationStack(path: $duoNavigationPath) {
            VStack(spacing: 0) {
                EntryListView(
                    entries: visibleEntries,
                    selection: $selection,
                    onScrollDirectionChange: { isVisible in
                        isDuoCategoryTabBarVisible = isVisible
                    },
                    openEntry: { entry in
                        duoNavigationPath = [entry.id]
                    }
                )
            }
            .overlay(alignment: .bottom) {
                DuoCategoryTabBar(
                    categories: store.categories,
                    filter: $filter,
                    isVisible: isDuoCategoryTabBarVisible,
                    selectFilter: selectDuoFilter
                )
                .frame(maxWidth: 920)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("Entries")
                        .font(.headline)
                        .fixedSize()
                        .accessibilityIdentifier("duo.action-bar.title")
                }
                ToolbarItem(placement: .principal) {
                    duoPortraitSearchField
                }
                ToolbarItem(placement: .topBarTrailing) {
                    duoPortraitActionBar(for: nil)
                }
            }
            #endif
            .navigationDestination(for: String.self) { entryID in
                duoPortraitDetail(entryID: entryID)
            }
        }
        .onChange(of: duoNavigationPath) { _, path in
            selection = path.last
            if path.isEmpty {
                isDuoCategoryTabBarVisible = true
            }
        }
    }

    @ViewBuilder
    private func duoPortraitDetail(entryID: String) -> some View {
        let entry = store.entries.first { $0.id == entryID && !$0.isDeleted }
        VStack(spacing: 0) {
            DetailView(
                entry: entry,
                entries: store.entries,
                categoryTemplates: store.categoryTemplates,
                editEntry: beginEditing,
                deleteEntry: deleteSelectedEntry,
                exportEntry: { exportingEntry = $0 },
                showsToolbarActions: false,
                showsEntryTitle: true,
                openReference: { target in
                    filter = .all
                    searchText = ""
                    duoNavigationPath = [target.id]
                },
                updateReference: { source, fieldID, targetID in
                    _ = store.updateEntryReference(
                        entryID: source.id,
                        fieldID: fieldID,
                        targetID: targetID
                    )
                },
                repairCategoryFields: beginEditingCategoryFields
            )
        }
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                duoPortraitActionBar(for: entry)
            }
        }
        #endif
    }

    private var duoPortraitSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search vault", text: $searchText)
#if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
#endif
                .accessibilityIdentifier("duo.entries.search")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 120, maxWidth: 240)
        .frame(height: 52)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(.quaternary, lineWidth: 0.5)
        }
    }

    private func duoPortraitActionBar(for entry: VaultEntry?) -> some View {
        let layout = DuoActionBarLayout(actions: duoPortraitActions(for: entry))

        return HStack(spacing: 4) {
            ForEach(layout.visibleActions) { action in
                duoActionButton(action)
            }

            Menu {
                if !layout.overflowActions.isEmpty {
                    Section {
                        ForEach(layout.overflowActions) { action in
                            Button(role: action.role, action: action.perform) {
                                Label(action.title, systemImage: action.systemImage)
                            }
                            .disabled(action.id == "duo.action.sync" && store.isSyncing)
                            .accessibilityIdentifier("\(action.id).overflow")
                        }
                    }
                }
                Section("Entry Types") {
                    ForEach(VaultEntryType.allCases) { type in
                        Button {
                            selectDuoFilter(.type(type))
                        } label: {
                            Label(type.title, systemImage: type.systemImage)
                        }
                    }
                }
                if !store.tags.isEmpty {
                    Section("Tags") {
                        ForEach(store.tags, id: \.self) { tag in
                            Button {
                                selectDuoFilter(.tag(tag))
                            } label: {
                                Label(tag, systemImage: "tag")
                            }
                        }
                    }
                }
                if case .category(let category) = filter {
                    Section(category) {
                        Button {
                            editingCategoryTemplate = category
                            isPresentingCategoryTemplateEditor = true
                        } label: {
                            Label("Edit Fields", systemImage: "slider.horizontal.3")
                        }
                        Button {
                            store.exportCategory(category)
                        } label: {
                            Label("Export Category", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                Section("Vault") {
                    Button {
                        isPresentingCategoryCreation = true
                    } label: {
                        Label("Create Category", systemImage: "folder.badge.plus")
                    }
                    Button {
                        isPresentingScopedImport = true
                    } label: {
                        Label("Import Entry/Category JSON", systemImage: "square.and.arrow.down")
                    }
                    Button(action: store.runBackup) {
                        Label("Run Backup", systemImage: "externaldrive.badge.timemachine")
                    }
                    Button(action: store.restoreLatestBackup) {
                        Label("Restore Backup", systemImage: "clock.arrow.circlepath")
                    }
                    Button(action: store.exportSnapshot) {
                        Label("Export JSON", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        isPresentingImport = true
                    } label: {
                        Label("Import JSON", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        isPresentingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .regular))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More Actions")
            .accessibilityIdentifier("duo.action.more")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("duo.action-bar")
        .modifier(DuoToolbarGlass())
        .contentShape(Capsule())
    }

    private func duoPortraitActions(for entry: VaultEntry?) -> [DuoToolbarAction] {
        let syncAction = DuoToolbarAction(
            id: "duo.action.sync",
            title: "Sync Now",
            systemImage: "arrow.triangle.2.circlepath",
            perform: store.syncNow
        )
        let addAction = DuoToolbarAction(
            id: "duo.action.add",
            title: "Add Entry",
            systemImage: "plus",
            perform: beginAddingEntry
        )
        let importAction = DuoToolbarAction(
            id: "duo.action.import",
            title: "Import Entry/Category JSON",
            systemImage: "square.and.arrow.down",
            perform: { isPresentingScopedImport = true }
        )
        let lockAction = DuoToolbarAction(
            id: "duo.action.lock",
            title: "Lock",
            systemImage: "lock",
            perform: store.lock
        )

        guard let entry else {
            return [syncAction, addAction, lockAction]
        }

        return [
            syncAction,
            DuoToolbarAction(
                id: "duo.action.edit",
                title: "Edit Entry",
                systemImage: "pencil",
                perform: { beginEditing(entry) }
            ),
            DuoToolbarAction(
                id: "duo.action.export",
                title: "Export Entry",
                systemImage: "square.and.arrow.up",
                perform: { exportingEntry = entry }
            ),
            DuoToolbarAction(
                id: "duo.action.delete",
                title: "Delete Entry",
                systemImage: "trash",
                role: .destructive,
                perform: { deleteSelectedEntry(entry) }
            ),
            lockAction,
            addAction,
            importAction
        ]
    }

    private func duoActionButton(_ action: DuoToolbarAction) -> some View {
        Button(role: action.role, action: action.perform) {
            Image(systemName: action.systemImage)
                .font(.system(size: 20, weight: .regular))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action.id == "duo.action.sync" && store.isSyncing)
        .help(action.title)
        .accessibilityLabel(action.title)
        .accessibilityIdentifier(action.id)
    }

    private func selectDuoFilter(_ target: VaultFilter) {
        filter = target
        searchText = ""
        selection = nil
        duoNavigationPath = []
        isDuoCategoryTabBarVisible = true
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
    static func usesExpandedPortraitLayout(isPhone: Bool, isRegularWidth: Bool, displaySize: CGSize) -> Bool {
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
