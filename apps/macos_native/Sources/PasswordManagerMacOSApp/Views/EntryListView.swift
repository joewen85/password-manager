import SwiftUI

struct EntryListView: View {
    var entries: [VaultEntry]
    @Binding var selection: VaultEntry.ID?
    var addEntry: () -> Void

    @State private var scrollPosition: VaultEntry.ID?

    var body: some View {
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
                    Label("No Entries", systemImage: "key.slash")
                } description: {
                    Text("Create an entry and assign a custom category.")
                } actions: {
                    Button("New Entry", action: addEntry)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
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
