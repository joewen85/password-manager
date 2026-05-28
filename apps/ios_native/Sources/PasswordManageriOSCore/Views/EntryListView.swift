import SwiftUI

struct EntryListView: View {
    var entries: [VaultEntry]
    @Binding var selection: VaultEntry.ID?

    var body: some View {
        List(entries, selection: $selection) { entry in
            HStack(spacing: 10) {
                Image(systemName: entry.type.systemImage)
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
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("No Entries", systemImage: "key.slash")
            }
        }
    }
}

private extension VaultEntry {
    var subtitle: String {
        let categoryText = payload.category.isEmpty ? "Uncategorized" : payload.category
        let tagText = payload.tags.isEmpty ? "" : " - \(payload.tags.map { "#\($0)" }.joined(separator: " "))"
        return "\(type.title) - \(categoryText)\(tagText)"
    }
}
