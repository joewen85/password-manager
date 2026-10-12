import SwiftUI

struct EntryListView: View {
    var entries: [VaultEntry]
    @Binding var selection: VaultEntry.ID?
    var onScrollDirectionChange: ((Bool) -> Void)? = nil
    var openEntry: ((VaultEntry) -> Void)? = nil

    @State private var scrollPosition: VaultEntry.ID?
    @State private var lastDragTranslation: CGFloat = 0
    @State private var lastObservedContentOffset: CGFloat?
    @State private var isScrollPhaseActive = false
    @ScaledMetric(relativeTo: .body) private var iconWidth = 18

    @ViewBuilder
    var body: some View {
        if onScrollDirectionChange != nil {
            if #available(iOS 18.0, macOS 15.0, *) {
                entryList
                    .onScrollGeometryChange(for: CGFloat.self) { geometry in
                        geometry.contentOffset.y
                    } action: { _, currentOffset in
                        let lastOffset = lastObservedContentOffset
                        lastObservedContentOffset = currentOffset
                        guard let lastOffset else { return }
                        reportVisibility(
                            forContentOffsetDelta: currentOffset - lastOffset,
                            isScrollActive: isScrollPhaseActive
                        )
                    }
                    .onScrollPhaseChange { _, phase in
                        isScrollPhaseActive = phase == .interacting
                            || phase == .decelerating
                            || phase == .animating
                    }
            } else {
                entryList.simultaneousGesture(scrollDirectionGesture)
            }
        } else {
            entryList
        }
    }

    private var scrollDirectionGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let difference = value.translation.height - lastDragTranslation
                guard abs(difference) > 3 else { return }
                lastDragTranslation = value.translation.height
                reportVisibility(forContentOffsetDelta: -difference, isScrollActive: true)
            }
            .onEnded { _ in
                lastDragTranslation = 0
            }
    }

    private func reportVisibility(forContentOffsetDelta delta: CGFloat, isScrollActive: Bool) {
        guard let isVisible = DuoCategoryTabScrollState.visibility(
            forContentOffsetDelta: delta,
            isScrollActive: isScrollActive
        ) else { return }
        onScrollDirectionChange?(isVisible)
    }

    private var entryList: some View {
        Group {
            if let openEntry {
                List(entries) { entry in
                    Button {
                        selection = entry.id
                        openEntry(entry)
                    } label: {
                        entryRow(entry)
                    }
                    .buttonStyle(.plain)
                    .id(entry.id)
                }
            } else {
                List(entries, selection: $selection) { entry in
                    NavigationLink(value: entry.id) {
                        entryRow(entry)
                    }
                    .tag(entry.id)
                    .id(entry.id)
                }
            }
        }
        .scrollPosition(id: $scrollPosition)
        .contentMargins(.bottom, onScrollDirectionChange == nil ? nil : 92, for: .scrollContent)
        .onChange(of: entryIDs) { _, nextIDs in
            guard let scrollPosition, !nextIDs.contains(scrollPosition) else { return }
            self.scrollPosition = fallbackScrollPosition(in: nextIDs)
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("No Entries", systemImage: "key.slash")
            }
        }
    }

    private func entryRow(_ entry: VaultEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.type.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: iconWidth)
                .accessibilityIdentifier("entry-list-icon-\(entry.id)")

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.label)
                    .lineLimit(1)

                Text(entry.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
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
        let categoryText = payload.category.isEmpty ? "Uncategorized" : payload.category
        let tagText = payload.tags.isEmpty ? "" : " - \(payload.tags.map { "#\($0)" }.joined(separator: " "))"
        return "\(type.title) - \(categoryText)\(tagText)"
    }
}
