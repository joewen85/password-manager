import Foundation
import Testing
@testable import PasswordManageriOSCore

@Test
func expandedPortraitLayoutIsLimitedToRegularWidthPhonesInPortrait() {
    #expect(DuoToolbarLayout.usesExpandedPortraitLayout(
        isPhone: true,
        isRegularWidth: true,
        displaySize: CGSize(width: 669, height: 951)
    ))
    #expect(!DuoToolbarLayout.usesExpandedPortraitLayout(
        isPhone: true,
        isRegularWidth: true,
        displaySize: CGSize(width: 951, height: 669)
    ))
    #expect(!DuoToolbarLayout.usesExpandedPortraitLayout(
        isPhone: false,
        isRegularWidth: true,
        displaySize: CGSize(width: 1024, height: 1366)
    ))
    #expect(!DuoToolbarLayout.usesExpandedPortraitLayout(
        isPhone: true,
        isRegularWidth: false,
        displaySize: CGSize(width: 466, height: 678)
    ))
    #expect(!DuoToolbarLayout.usesExpandedPortraitLayout(
        isPhone: true,
        isRegularWidth: true,
        displaySize: CGSize(width: 669, height: 669)
    ))
}

@Test
func categoryTabLayoutKeepsAllAndMoreWithinSixTabs() {
    let categories = (1...7).map { "Category \($0)" }
    let layout = DuoCategoryTabLayout(categories: categories)

    #expect(layout.visibleCategories == Array(categories.prefix(4)))
    #expect(layout.overflowCategories == Array(categories.suffix(3)))
}

@Test
func categoryTabLayoutDoesNotAddMoreWhenFiveOrFewerExist() {
    let categories = ["Personal", "Work", "Servers", "Services", "Other"]
    let layout = DuoCategoryTabLayout(categories: categories)

    #expect(layout.visibleCategories == categories)
    #expect(layout.overflowCategories.isEmpty)
}

@Test
func categoryTabLayoutUsesTheSixthSlotForMoreWhenNeeded() {
    let categories = (1...6).map { "Category \($0)" }
    let layout = DuoCategoryTabLayout(categories: categories)

    #expect(layout.visibleCategories == Array(categories.prefix(4)))
    #expect(layout.overflowCategories == ["Category 5", "Category 6"])
    #expect(1 + layout.visibleCategories.count + 1 == DuoCategoryTabLayout.maximumVisibleTabs)
}

@Test
func categoryTabsHideOnDownwardContentScrollAndReturnOnUpwardScroll() {
    #expect(DuoCategoryTabScrollState.visibility(forContentOffsetDelta: 20, isScrollActive: true) == false)
    #expect(DuoCategoryTabScrollState.visibility(forContentOffsetDelta: -20, isScrollActive: true) == true)
    #expect(DuoCategoryTabScrollState.visibility(forContentOffsetDelta: 0, isScrollActive: true) == nil)
}

@Test
func categoryTabsIgnoreSmallIdleLayoutOffsetsButFollowLargeScrollJumps() {
    #expect(DuoCategoryTabScrollState.visibility(forContentOffsetDelta: 52, isScrollActive: false) == nil)
    #expect(DuoCategoryTabScrollState.visibility(forContentOffsetDelta: 73, isScrollActive: false) == false)
    #expect(DuoCategoryTabScrollState.visibility(forContentOffsetDelta: -73, isScrollActive: false) == true)
}

@Test
func actionBarShowsSyncEditExportDeleteAndLockBeforeMore() {
    let actionIDs = ["sync", "edit", "export", "delete", "lock", "add"]
    let actions = actionIDs.map { id in
        DuoToolbarAction(
            id: id,
            title: id.capitalized,
            systemImage: "circle",
            perform: {}
        )
    }
    let layout = DuoActionBarLayout(actions: actions)

    #expect(layout.visibleActions.map(\.id) == ["sync", "edit", "export", "delete", "lock"])
    #expect(layout.overflowActions.map(\.id) == ["add"])
}

@Test
func actionBarDoesNotOverflowFiveOrFewerActions() {
    let actions = (1...4).map { index in
        DuoToolbarAction(
            id: "action.\(index)",
            title: "Action \(index)",
            systemImage: "circle",
            perform: {}
        )
    }
    let layout = DuoActionBarLayout(actions: actions)

    #expect(layout.visibleActions.count == 4)
    #expect(layout.overflowActions.isEmpty)
}
