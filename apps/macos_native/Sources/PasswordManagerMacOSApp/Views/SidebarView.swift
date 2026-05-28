import SwiftUI

struct SidebarView: View {
    var store: VaultStore
    @Binding var filter: VaultFilter
    var addEntry: () -> Void
    var createCategory: () -> Void
    var createTag: () -> Void
    var showTaxonomyManager: () -> Void
    var showSyncCenter: () -> Void
    var showBackups: () -> Void
    var showExportCenter: () -> Void
    var showImportCenter: () -> Void
    var showClearData: () -> Void
    var exportCategory: (String) -> Void

    var body: some View {
        List(selection: $filter) {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L10n.t("Native macOS Vault"), systemImage: "lock.shield")
                        .font(.headline)
                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 4)
            }

            Section {
                Label(L10n.t("All Items"), systemImage: "tray.full")
                    .tag(VaultFilter.all)
            }

            if !store.categories.isEmpty {
                Section(L10n.t("Categories")) {
                    ForEach(store.categories, id: \.self) { category in
                        Label(category, systemImage: "folder")
                            .tag(VaultFilter.category(category))
                            .contextMenu {
                                Button(L10n.t("Export Category")) {
                                    exportCategory(category)
                                }
                            }
                    }
                }
            }

            if !store.tags.isEmpty {
                Section(L10n.t("Tags")) {
                    ForEach(store.tags, id: \.self) { tag in
                        Label(tag, systemImage: "tag")
                            .tag(VaultFilter.tag(tag))
                    }
                }
            }

            Section(L10n.t("Operations")) {
                Button(action: showTaxonomyManager) {
                    Label(L10n.t("Manage Categories & Tags"), systemImage: "tag")
                }
                Button(action: showSyncCenter) {
                    Label(L10n.t("Sync"), systemImage: "arrow.triangle.2.circlepath")
                }
                Button(action: showBackups) {
                    Label(L10n.t("Backups"), systemImage: "externaldrive.badge.timemachine")
                }
                Button(action: showExportCenter) {
                    Label(L10n.t("Export"), systemImage: "square.and.arrow.up")
                }
                Button(action: showImportCenter) {
                    Label(L10n.t("Import"), systemImage: "square.and.arrow.down")
                }
                Button(role: .destructive, action: showClearData) {
                    Label(L10n.t("Clear Data"), systemImage: "trash")
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.syncNow()
                } label: {
                    Label(L10n.t("Run Sync Now"), systemImage: "arrow.triangle.2.circlepath")
                }
                .help(L10n.t("Run Sync Now"))
                .disabled(store.syncSettings.providerType == .none)

                Button(action: showBackups) {
                    Label(L10n.t("Backups"), systemImage: "externaldrive.badge.timemachine")
                }
                .help(L10n.t("Backups"))
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Menu {
                    Button(action: addEntry) {
                        Label(L10n.t("Add Entry"), systemImage: "plus")
                    }
                    Button(action: createCategory) {
                        Label(L10n.t("Create Category"), systemImage: "folder.badge.plus")
                    }
                    Button(action: createTag) {
                        Label(L10n.t("Create Tag"), systemImage: "tag")
                    }
                } label: {
                    Label(L10n.t("Create"), systemImage: "plus")
                }
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button(action: { store.lock() }) {
                    Label(L10n.t("Lock"), systemImage: "lock")
                }
            }
        }
    }

    private var summaryText: String {
        L10n.tf(
            "Entries %d - Categories %d - Sync %@",
            activeEntryCount,
            store.categories.count,
            L10n.status(store.syncStatus)
        )
    }

    private var activeEntryCount: Int {
        store.entries.filter { !$0.isDeleted }.count
    }
}
