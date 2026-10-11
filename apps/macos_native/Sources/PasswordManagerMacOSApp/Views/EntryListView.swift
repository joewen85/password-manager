import SwiftUI

struct EntryListView: View {
    var entries: [VaultEntry]
    @Binding var searchText: String
    @Binding var selection: VaultEntry.ID?
    var addEntry: () -> Void

    @State private var scrollPosition: VaultEntry.ID?

    var body: some View {
        VStack(spacing: 0) {
            searchBar

            Divider()

            List(entries, selection: $selection) { entry in
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.label)
                            .lineLimit(1)

                        Text(entry.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .tag(entry.id)
                .id(entry.id)
            }
            .scrollPosition(id: $scrollPosition)
            .onChange(of: entryIDs) { _, nextIDs in
                guard let scrollPosition, !nextIDs.contains(scrollPosition) else { return }
                self.scrollPosition = fallbackScrollPosition(in: nextIDs)
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.t("No Entries"), systemImage: "key.slash")
                    } description: {
                        Text(L10n.t("Create an entry and assign a custom category."))
                    } actions: {
                        Button(L10n.t("New Entry"), action: addEntry)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(L10n.t("Search vault"), text: $searchText)
                .textFieldStyle(.plain)
                .submitLabel(.search)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Label(L10n.t("Clear Search"), systemImage: "xmark.circle.fill")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L10n.t("Clear Search"))
                .accessibilityLabel(L10n.t("Clear Search"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var entryIDs: [VaultEntry.ID] {
        entries.map(\.id)
    }

    private func fallbackScrollPosition(in ids: [VaultEntry.ID]) -> VaultEntry.ID? {
        if let selection, ids.contains(selection) {
            return selection
        }
        return ids.first
    }
}

private extension VaultEntry {
    var subtitle: String {
        let categoryText = payload.category.isEmpty ? L10n.t("Uncategorized") : payload.category
        let tagText = payload.tags.isEmpty ? "" : " - \(payload.tags.map { "#\($0)" }.joined(separator: " "))"
        return "\(categoryText)\(tagText)"
    }
}
