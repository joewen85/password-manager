import SwiftUI

struct SidebarView: View {
    var store: VaultStore
    @Binding var filter: VaultFilter
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
            ToolbarItem {
                Button(action: showBackups) {
                    Label(L10n.t("Backups"), systemImage: "externaldrive.badge.timemachine")
                }
                .help(L10n.t("Backups"))
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
