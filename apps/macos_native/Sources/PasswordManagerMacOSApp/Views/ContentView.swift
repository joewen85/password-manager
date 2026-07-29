import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var store: VaultStore
    @Binding var shouldAutoPromptBiometricsOnLaunch: Bool
    @State private var selection: VaultEntry.ID?
    @State private var filter: VaultFilter = .all
    @State private var searchText = ""
    @State private var isPresentingImport = false
    @State private var isPresentingScopedImport = false
    @State private var isPresentingBackups = false
    @State private var isPresentingSyncCenter = false
    @State private var isPresentingTaxonomyManager = false
    @State private var isPresentingExportCenter = false
    @State private var isPresentingImportCenter = false
    @State private var isPresentingClearData = false
    @State private var isPresentingSnapshotImportOptions = false
    @State private var isPresentingScopedImportOptions = false
    @State private var entryPendingExport: VaultEntry?
    @State private var selectedExportFieldIDs: Set<String> = []
    @State private var isImportingSnapshotFile = false
    @State private var isImportingScopedFile = false
    @State private var isExportingJSON = false
    @State private var exportDocument = JSONExportDocument()
    @State private var exportFileName = "vault-export.json"
    @State private var exportCategoryValue = ""
    @State private var importFileName = ""
    @State private var scopedImportFileName = ""
    @State private var importStrategy: ImportConflictStrategy = .keepCopy
    @State private var importResultMessage: String?
    @State private var isPresentingCreateTaxonomy = false
    @State private var createTaxonomyKind: CreateTaxonomyKind = .category
    @State private var createTaxonomyValue = ""
    @State private var createCategoryCustomFields: [CustomField] = []
    @State private var createTaxonomyError: String?
    @State private var clearDataPassword = ""
    @State private var clearDataError: String?
    @State private var editorSession: EntryEditorSession?
    @State private var taxonomyFieldRepairCategory: String?

    private let biometricCredentialStore = MacBiometricCredentialStore()

    var body: some View {
        if store.isUnlocked {
            NavigationSplitView {
                SidebarView(
                    store: store,
                    filter: $filter,
                    showTaxonomyManager: { isPresentingTaxonomyManager = true },
                    showSyncCenter: { isPresentingSyncCenter = true },
                    showBackups: { isPresentingBackups = true },
                    showExportCenter: beginExportCenter,
                    showImportCenter: { isPresentingImportCenter = true },
                    showClearData: beginClearingData,
                    exportCategory: exportCategory
                )
            } content: {
                EntryListView(
                    entries: visibleEntries,
                    searchText: $searchText,
                    selection: $selection,
                    addEntry: beginAddingEntry
                )
            } detail: {
                DetailView(
                    entry: selectedEntry,
                    entries: store.entries,
                    categoryTemplates: store.categoryTemplates,
                    editEntry: beginEditing,
                    deleteEntry: deleteSelectedEntry,
                    exportEntry: exportEntry,
                    openEntryReference: openEntryReference,
                    updateEntryReference: updateEntryReference,
                    repairCategoryFields: beginEditingCategoryFields
                )
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        store.syncNow()
                    } label: {
                        Label(L10n.t("Run Sync Now"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .help(L10n.t("Run Sync Now"))
                    .disabled(store.syncSettings.providerType == .none)

                    Menu {
                        Button(action: beginAddingEntry) {
                            Label(L10n.t("Add Entry"), systemImage: "plus")
                        }
                        Button {
                            beginCreatingTaxonomy(.category)
                        } label: {
                            Label(L10n.t("Create Category"), systemImage: "folder.badge.plus")
                        }
                        Button {
                            beginCreatingTaxonomy(.tag)
                        } label: {
                            Label(L10n.t("Create Tag"), systemImage: "tag")
                        }
                    } label: {
                        Label(L10n.t("Create"), systemImage: "plus")
                    }
                    .help(L10n.t("Create"))
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.lock()
                    } label: {
                        Label(L10n.t("Lock"), systemImage: "lock.fill")
                    }
                    .labelStyle(.iconOnly)
                    .help(L10n.t("Lock Vault"))
                    .accessibilityLabel(L10n.t("Lock Vault"))
                }
            }
            .sheet(item: $editorSession, onDismiss: {
                editorSession = nil
            }) { session in
                EntryEditorView(
                    entry: session.entry,
                    initialCategory: session.initialCategory,
                    categories: store.categories,
                    categoryTemplates: store.categoryTemplates,
                    entries: store.entries,
                    tags: store.tags,
                    onCreateCategory: { category, preset, customFieldNames in
                        store.addCategory(category, preset: preset, customFieldNames: customFieldNames)
                    },
                    onCreateTag: { store.addTag($0) },
                    onEditCategoryFields: beginEditingCategoryFields,
                    onSave: { draft in
                        store.upsert(draft, editing: session.entry)
                        selection = store.entries.sorted { $0.updatedAt > $1.updatedAt }.first?.id
                        validateNavigationState()
                        editorSession = nil
                    },
                    onCancel: {
                        editorSession = nil
                    }
                )
                .frame(minWidth: 520, minHeight: 600)
            }
            .sheet(isPresented: $isPresentingBackups) {
                BackupCenterView(store: store)
                    .frame(minWidth: 560, minHeight: 420)
            }
            .sheet(isPresented: $isPresentingSyncCenter) {
                SyncCenterView(store: store)
                    .frame(minWidth: 560, minHeight: 460)
            }
            .sheet(isPresented: $isPresentingTaxonomyManager, onDismiss: {
                taxonomyFieldRepairCategory = nil
            }) {
                TaxonomyManagementView(
                    store: store,
                    onChange: validateCurrentFilter,
                    initialFieldEditCategory: taxonomyFieldRepairCategory
                )
                    .frame(minWidth: 540, minHeight: 460)
            }
            .sheet(isPresented: $isPresentingExportCenter) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Export")
                        .font(.title2)
                    Text("Save a full vault snapshot, the selected entry, or a category JSON file. You can also create an encrypted local backup.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Button {
                        isPresentingExportCenter = false
                        DispatchQueue.main.async {
                            exportSnapshot()
                        }
                    } label: {
                        Label("Save Full Vault JSON", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        let entry = selectedEntry
                        isPresentingExportCenter = false
                        DispatchQueue.main.async {
                            if let entry {
                                exportEntry(entry)
                            }
                        }
                    } label: {
                        Label("Save Selected Entry JSON", systemImage: "doc")
                    }
                    .disabled(selectedEntry == nil)

                    Divider()

                    if store.categories.isEmpty {
                        TextField("Category", text: $exportCategoryValue)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Picker("Category", selection: $exportCategoryValue) {
                            ForEach(store.categories, id: \.self) { category in
                                Text(category).tag(category)
                            }
                        }
                    }

                    Button {
                        let category = exportCategoryValue
                        isPresentingExportCenter = false
                        DispatchQueue.main.async {
                            exportCategory(category)
                        }
                    } label: {
                        Label("Save Category JSON", systemImage: "folder")
                    }
                    .disabled(exportCategoryValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Divider()

                    Button {
                        store.runBackup()
                    } label: {
                        Label("Create Local Backup", systemImage: "externaldrive.badge.plus")
                    }

                    if let statusMessage = store.statusMessage {
                        Text(L10n.status(statusMessage))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    HStack {
                        Spacer()
                        Button("Close") {
                            isPresentingExportCenter = false
                        }
                    }
                }
                .padding()
                .frame(width: 520)
            }
            .sheet(item: $entryPendingExport) { entry in
                EntryExportOptionsView(
                    entry: entry,
                    selectedFieldIDs: $selectedExportFieldIDs,
                    exportAll: {
                        entryPendingExport = nil
                        DispatchQueue.main.async {
                            presentExport(store.makeEntryExport(entry))
                        }
                    },
                    exportSelected: {
                        let fieldIDs = selectedExportFieldIDs
                        entryPendingExport = nil
                        DispatchQueue.main.async {
                            presentExport(store.makeEntryExport(entry, selectedFieldIDs: fieldIDs))
                        }
                    },
                    cancel: {
                        entryPendingExport = nil
                    }
                )
                .frame(width: 460, height: 520)
            }
            .sheet(isPresented: $isPresentingImportCenter) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Import")
                        .font(.title2)
                    Text("Choose a full vault snapshot or an entry/category JSON file.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Button {
                        isPresentingImportCenter = false
                        DispatchQueue.main.async {
                            isPresentingSnapshotImportOptions = true
                        }
                    } label: {
                        Label("Choose Full Vault JSON", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        isPresentingImportCenter = false
                        DispatchQueue.main.async {
                            isPresentingScopedImportOptions = true
                        }
                    } label: {
                        Label("Choose Entry/Category JSON", systemImage: "doc.badge.arrow.up")
                    }

                    Menu("Legacy Imports Folder") {
                        Button("Snapshot from Imports Folder") {
                            isPresentingImportCenter = false
                            DispatchQueue.main.async {
                                isPresentingImport = true
                            }
                        }
                        Button("Entry/Category from Imports Folder") {
                            isPresentingImportCenter = false
                            DispatchQueue.main.async {
                                isPresentingScopedImport = true
                            }
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Close") {
                            isPresentingImportCenter = false
                        }
                    }
                }
                .padding()
                .frame(width: 520)
            }
            .sheet(isPresented: $isPresentingCreateTaxonomy) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(createTaxonomyKind.title)
                        .font(.title2)
                    Text(createTaxonomyKind.hint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextField(createTaxonomyKind.placeholder, text: $createTaxonomyValue)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveCreatedTaxonomy)
                    if createTaxonomyKind == .category {
                        CategoryPresetShortcutButtons(fields: $createCategoryCustomFields)
                        CategoryTemplateFieldNameEditor(fields: $createCategoryCustomFields)
                    }
                    if let createTaxonomyError {
                        Text(createTaxonomyError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    HStack {
                        Spacer()
                        Button("Cancel") {
                            isPresentingCreateTaxonomy = false
                        }
                        Button("Save", action: saveCreatedTaxonomy)
                            .buttonStyle(.borderedProminent)
                            .disabled(createTaxonomyValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding()
                .frame(width: 420)
            }
            .sheet(isPresented: $isPresentingClearData) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Clear Data")
                        .font(.title2)
                    Text("This clears all entries, categories, tags, and vault security settings. This does not change the master password.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    SecureField("Master password", text: $clearDataPassword)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(clearData)
                    if let clearDataError {
                        Text(clearDataError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    HStack {
                        Spacer()
                        Button("Cancel") {
                            isPresentingClearData = false
                        }
                        Button("Clear Data", role: .destructive, action: clearData)
                            .disabled(clearDataPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding()
                .frame(width: 460)
            }
            .sheet(isPresented: $isPresentingSnapshotImportOptions) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Import Full Vault")
                        .font(.title2)
                    Text("Choose a snapshot JSON file. Importing a full vault replaces current entries, categories, tags, security settings, and local status fields.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Cancel") {
                            isPresentingSnapshotImportOptions = false
                        }
                        Button("Choose File") {
                            isPresentingSnapshotImportOptions = false
                            DispatchQueue.main.async {
                                isImportingSnapshotFile = true
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                .frame(width: 520)
            }
            .sheet(isPresented: $isPresentingScopedImportOptions) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Import Entry or Category JSON")
                        .font(.title2)
                    Text("Choose an entry/category export JSON file and select how conflicts should be handled.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Picker("Conflict Strategy", selection: $importStrategy) {
                        ForEach(ImportConflictStrategy.allCases) { strategy in
                            Text(strategy.title).tag(strategy)
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Cancel") {
                            isPresentingScopedImportOptions = false
                        }
                        Button("Choose File") {
                            isPresentingScopedImportOptions = false
                            DispatchQueue.main.async {
                                isImportingScopedFile = true
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                .frame(width: 520)
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
                            performSnapshotImport(fileName: importFileName)
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
                            performScopedImport(fileName: scopedImportFileName, strategy: importStrategy)
                            scopedImportFileName = ""
                            isPresentingScopedImport = false
                        }
                        .disabled(scopedImportFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding()
                .frame(width: 520)
            }
            .fileImporter(
                isPresented: $isImportingSnapshotFile,
                allowedContentTypes: [.json]
            ) { result in
                if case .success(let url) = result {
                    performSnapshotImport(from: url)
                }
            }
            .fileImporter(
                isPresented: $isImportingScopedFile,
                allowedContentTypes: [.json]
            ) { result in
                if case .success(let url) = result {
                    performScopedImport(from: url, strategy: importStrategy)
                }
            }
            .fileExporter(
                isPresented: $isExportingJSON,
                document: exportDocument,
                contentType: .json,
                defaultFilename: exportFileName
            ) { _ in }
            .alert("Import", isPresented: isShowingImportResult) {
                Button("Close") {
                    importResultMessage = nil
                }
            } message: {
                Text(importResultMessage.map(L10n.status) ?? "")
            }
            .onChange(of: filter) { _, _ in
                validateNavigationState()
            }
            .onChange(of: searchText) { _, _ in
                validateNavigationState()
            }
            .onChange(of: store.entries) { _, _ in
                validateNavigationState()
            }
            .onChange(of: store.categories) { _, _ in
                validateNavigationState()
            }
            .onChange(of: store.tags) { _, _ in
                validateNavigationState()
            }
        } else {
            UnlockView(
                store: store,
                shouldAutoPromptBiometricsOnLaunch: $shouldAutoPromptBiometricsOnLaunch
            )
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
        editorSession = EntryEditorSession(entry: nil, initialCategory: currentCategoryFilter)
    }

    private func beginCreatingTaxonomy(_ kind: CreateTaxonomyKind) {
        createTaxonomyKind = kind
        createTaxonomyValue = ""
        createCategoryCustomFields = []
        createTaxonomyError = nil
        isPresentingCreateTaxonomy = true
    }

    private func saveCreatedTaxonomy() {
        let value = createTaxonomyValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            createTaxonomyError = L10n.t("Value is required.")
            return
        }
        let didSave: Bool
        switch createTaxonomyKind {
        case .category:
            didSave = store.addCategory(
                value,
                preset: nil,
                customFieldNames: createCategoryCustomFields.map(\.name)
            )
        case .tag:
            didSave = store.addTag(value)
        }
        if didSave {
            createTaxonomyValue = ""
            createCategoryCustomFields = []
            createTaxonomyError = nil
            isPresentingCreateTaxonomy = false
        } else {
            createTaxonomyError = store.statusMessage ?? L10n.t("Operation failed.")
        }
    }

    private func beginClearingData() {
        clearDataPassword = ""
        clearDataError = nil
        isPresentingClearData = true
    }

    private func clearData() {
        guard !clearDataPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clearDataError = L10n.t("Value is required.")
            return
        }
        if store.clearAllData(password: clearDataPassword) {
            biometricCredentialStore.clear()
            selection = nil
            filter = .all
            searchText = ""
            clearDataPassword = ""
            clearDataError = nil
            isPresentingClearData = false
        } else {
            clearDataError = store.statusMessage ?? L10n.t("Operation failed.")
        }
    }

    private func beginEditing(_ entry: VaultEntry) {
        editorSession = EntryEditorSession(entry: entry)
    }

    private func beginEditingCategoryFields(_ category: String) {
        let normalized = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        editorSession = nil
        taxonomyFieldRepairCategory = normalized
        DispatchQueue.main.async {
            isPresentingTaxonomyManager = true
        }
    }

    private func openEntryReference(_ entry: VaultEntry) {
        guard !entry.isDeleted else { return }
        filter = .all
        searchText = ""
        selection = entry.id
    }

    private func updateEntryReference(_ entry: VaultEntry, fieldID: String, targetID: String) {
        _ = store.updateEntryReference(entryID: entry.id, fieldID: fieldID, targetID: targetID)
    }

    private func deleteSelectedEntry(_ entry: VaultEntry) {
        store.delete(entry)
        if selection == entry.id {
            selection = visibleEntries.first?.id
        }
    }

    private func beginExportCenter() {
        exportCategoryValue = store.categories.first ?? ""
        isPresentingExportCenter = true
    }

    private func exportSnapshot() {
        presentExport(store.makeSnapshotExport())
    }

    private func exportEntry(_ entry: VaultEntry) {
        selectedExportFieldIDs = []
        entryPendingExport = entry
    }

    private func exportCategory(_ category: String) {
        presentExport(store.makeCategoryExport(category))
    }

    private func presentExport(_ export: VaultExportFile?) {
        guard let export else { return }
        exportDocument = JSONExportDocument(data: export.data)
        exportFileName = export.fileName
        isExportingJSON = true
    }

    private func performSnapshotImport(fileName: String) {
        store.importSnapshot(fileName: fileName)
        finishImport()
    }

    private func performSnapshotImport(from url: URL) {
        store.importSnapshot(from: url)
        finishImport()
    }

    private func performScopedImport(fileName: String, strategy: ImportConflictStrategy) {
        store.importScopedExport(fileName: fileName, strategy: strategy)
        finishImport()
    }

    private func performScopedImport(from url: URL, strategy: ImportConflictStrategy) {
        store.importScopedExport(from: url, strategy: strategy)
        finishImport()
    }

    private func finishImport() {
        let message = store.statusMessage ?? L10n.t("Import complete.")
        if message.hasPrefix("Imported ") {
            resetVaultViewState()
        }
        importResultMessage = message
    }

    private func resetVaultViewState() {
        selection = nil
        filter = .all
        searchText = ""
    }

    private func validateNavigationState() {
        validateCurrentFilter()
        guard let selection else { return }
        if !visibleEntries.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }

    private func validateCurrentFilter() {
        switch filter {
        case .category(let category) where !store.categories.contains(category):
            filter = .all
        case .tag(let tag) where !store.tags.contains(tag):
            filter = .all
        default:
            break
        }
    }

    private var isShowingImportResult: Binding<Bool> {
        Binding(
            get: { importResultMessage != nil },
            set: { isShowing in
                if !isShowing {
                    importResultMessage = nil
                }
            }
        )
    }
}

private struct EntryEditorSession: Identifiable {
    let id = UUID()
    var entry: VaultEntry?
    var initialCategory: String = ""
}

private extension ContentView {
    var currentCategoryFilter: String {
        if case .category(let category) = filter {
            return category
        }
        return ""
    }
}

private struct EntryExportOptionsView: View {
    var entry: VaultEntry
    @Binding var selectedFieldIDs: Set<String>
    var exportAll: () -> Void
    var exportSelected: () -> Void
    var cancel: () -> Void

    private var fields: [EntryExportField] {
        entry.exportFields
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("Export Entry"))
                .font(.title2)
            Text(L10n.t("Select fields to export. Export all keeps the complete entry; export selected writes only checked fields."))
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(fields) { field in
                        Toggle(isOn: binding(for: field.id)) {
                            Text(field.title)
                        }
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 260)

            Text(L10n.tf("Selected Fields: %d", selectedFieldIDs.count))
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(L10n.t("Cancel"), action: cancel)
                Button(L10n.t("Export All"), action: exportAll)
                Button(L10n.t("Export Selected"), action: exportSelected)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedFieldIDs.isEmpty)
            }
        }
        .padding()
    }

    private func binding(for fieldID: String) -> Binding<Bool> {
        Binding(
            get: { selectedFieldIDs.contains(fieldID) },
            set: { isSelected in
                if isSelected {
                    selectedFieldIDs.insert(fieldID)
                } else {
                    selectedFieldIDs.remove(fieldID)
                }
            }
        )
    }
}

struct CategoryPresetShortcutButtons: View {
    @Binding var fields: [CustomField]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("Field Shortcuts"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(CategoryTypePreset.allCases) { preset in
                    Button {
                        appendFields(for: preset)
                    } label: {
                        Text(preset.title)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(L10n.tf("Add %@ fields", preset.title))
                }
            }
            Text(L10n.t("New categories use only Name and Notes until you add custom fields."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func appendFields(for preset: CategoryTypePreset) {
        var existing = Set(
            fields.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        for name in preset.fields {
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, existing.insert(key).inserted else { continue }
            fields.append(CustomField(name: name))
        }
    }
}

struct CategoryTemplateFieldNameEditor: View {
    @Binding var fields: [CustomField]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("Fields"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if fields.isEmpty {
                Text(L10n.t("No custom fields."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(fields.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.t("Field Name"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            TextField(L10n.t("Field Name"), text: $fields[index].name)
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 160)
                        }
                        Button(role: .destructive) {
                            remove(at: index)
                        } label: {
                            Label(L10n.t("Remove Field"), systemImage: "trash")
                        }
                        .labelStyle(.iconOnly)
                        .help(L10n.t("Remove Field"))
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                }
            }

            Button(action: addField) {
                Label(L10n.t("Add Field"), systemImage: "plus")
            }
            .controlSize(.small)
        }
    }

    private func addField() {
        fields.append(CustomField())
    }

    private func remove(at index: Int) {
        guard fields.indices.contains(index) else { return }
        fields.remove(at: index)
    }
}

private enum CreateTaxonomyKind {
    case category
    case tag

    var title: String {
        switch self {
        case .category: L10n.t("Create Category")
        case .tag: L10n.t("Create Tag")
        }
    }

    var hint: String {
        switch self {
        case .category: L10n.t("Create a category without opening the entry editor.")
        case .tag: L10n.t("Create a tag without opening the entry editor.")
        }
    }

    var placeholder: String {
        switch self {
        case .category: L10n.t("Category")
        case .tag: L10n.t("Tag")
        }
    }
}
