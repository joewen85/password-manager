import SwiftUI

struct DuoCategoryTabLayout: Equatable {
    static let maximumVisibleCategories = 5

    let visibleCategories: [String]
    let overflowCategories: [String]

    init(categories: [String]) {
        visibleCategories = Array(categories.prefix(Self.maximumVisibleCategories))
        overflowCategories = Array(categories.dropFirst(Self.maximumVisibleCategories))
    }
}

enum DuoCategoryTabScrollState {
    static func isVisible(forFingerMovement movement: CGFloat) -> Bool {
        movement > 0
    }
}

struct DuoCategoryTabBar: View {
    var categories: [String]
    @Binding var filter: VaultFilter
    var isVisible: Bool
    var selectFilter: (VaultFilter) -> Void

    @State private var isShowingMoreCategories = false

    private var tabLayout: DuoCategoryTabLayout {
        DuoCategoryTabLayout(categories: categories)
    }

    var body: some View {
        HStack(spacing: 2) {
            tabButton("All", systemImage: "tray.full", filter: .all, identifier: "duo.category.tab.all")

            ForEach(tabLayout.visibleCategories, id: \.self) { category in
                tabButton(
                    category,
                    systemImage: "folder",
                    filter: .category(category),
                    identifier: "duo.category.tab.\(category)"
                )
            }

            if !tabLayout.overflowCategories.isEmpty {
                Button {
                    isShowingMoreCategories = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .regular))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("More Categories")
                .accessibilityIdentifier("duo.category.tab.more")
                .popover(isPresented: $isShowingMoreCategories, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(tabLayout.overflowCategories, id: \.self) { category in
                            Button {
                                choose(.category(category))
                            } label: {
                                Label(category, systemImage: "folder")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("duo.category.overflow.\(category)")
                        }
                    }
                    .padding(12)
                    .frame(minWidth: 220, maxHeight: 420)
                    .presentationCompactAdaptation(.popover)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .modifier(DuoCategoryTabGlass())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("duo.category-tab-bar")
        .offset(y: isVisible ? 0 : 120)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
        .animation(.easeInOut(duration: 0.2), value: isVisible)
    }

    private func tabButton(
        _ title: String,
        systemImage: String,
        filter target: VaultFilter,
        identifier: String
    ) -> some View {
        Button {
            choose(target)
        } label: {
            tabLabel(title, systemImage: systemImage, isSelected: filter == target)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(filter == target ? "Selected" : "")
    }

    private func tabLabel(_ title: String, systemImage: String, isSelected: Bool = false) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .regular))
                .frame(height: 20)
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .contentShape(Rectangle())
    }

    private func choose(_ target: VaultFilter) {
        filter = target
        isShowingMoreCategories = false
        selectFilter(target)
    }
}

private struct DuoCategoryTabGlass: ViewModifier {
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
