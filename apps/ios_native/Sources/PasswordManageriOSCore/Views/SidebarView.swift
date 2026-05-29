import SwiftUI

struct SidebarView: View {
    var store: VaultStore
    @Binding var filter: VaultFilter
    @Binding var searchText: String
    var addEntry: () -> Void
    var runBackup: () -> Void
    var restoreBackup: () -> Void
    var exportSnapshot: () -> Void
    var importSnapshot: () -> Void
    var exportCategory: (String) -> Void
    var syncNow: () -> Void
    var showSettings: () -> Void

    var body: some View {
        List {
            Section {
                filterButton(.all) {
                    Label("All Items", systemImage: "tray.full")
                }

                ForEach(VaultEntryType.allCases) { type in
                    filterButton(.type(type)) {
                        Label(type.title, systemImage: type.systemImage)
                    }
                }
            }

            if !store.categories.isEmpty {
                Section("Categories") {
                    ForEach(store.categories, id: \.self) { category in
                        filterButton(.category(category)) {
                            Label(category, systemImage: "folder")
                        }
                            .contextMenu {
                                Button("Export Category") {
                                    exportCategory(category)
                                }
                            }
                    }
                }
            }

            if !store.tags.isEmpty {
                Section("Tags") {
                    ForEach(store.tags, id: \.self) { tag in
                        filterButton(.tag(tag)) {
                            Label(tag, systemImage: "tag")
                        }
                    }
                }
            }

            Section("Operations") {
                Button(action: syncNow) {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                }
                Button(action: runBackup) {
                    Label("Run Backup", systemImage: "externaldrive.badge.timemachine")
                }
                Button(action: restoreBackup) {
                    Label("Restore Backup", systemImage: "clock.arrow.circlepath")
                }
                Button(action: exportSnapshot) {
                    Label("Export JSON", systemImage: "square.and.arrow.up")
                }
                Button(action: importSnapshot) {
                    Label("Import JSON", systemImage: "square.and.arrow.down")
                }
                Button(action: showSettings) {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, prompt: "Search vault")
        .toolbar {
            ToolbarItem {
                Button(action: addEntry) {
                    Label("Add Entry", systemImage: "plus")
                }
            }
            ToolbarItem {
                Button(action: { store.lock() }) {
                    Label("Lock", systemImage: "lock")
                }
            }
        }
    }

    private func filterButton<LabelContent: View>(
        _ target: VaultFilter,
        @ViewBuilder label: () -> LabelContent
    ) -> some View {
        Button {
            filter = target
        } label: {
            label()
                .foregroundColor(filter == target ? .accentColor : .primary)
        }
    }
}
