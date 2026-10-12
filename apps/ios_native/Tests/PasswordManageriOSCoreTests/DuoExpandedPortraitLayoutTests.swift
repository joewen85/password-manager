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
func categoryTabLayoutShowsFiveCategoriesAndKeepsTheRestForMore() {
    let categories = (1...7).map { "Category \($0)" }
    let layout = DuoCategoryTabLayout(categories: categories)

    #expect(layout.visibleCategories == Array(categories.prefix(5)))
    #expect(layout.overflowCategories == ["Category 6", "Category 7"])
}

@Test
func categoryTabLayoutDoesNotAddMoreWhenFiveOrFewerExist() {
    let categories = ["Personal", "Work", "Servers", "Services", "Other"]
    let layout = DuoCategoryTabLayout(categories: categories)

    #expect(layout.visibleCategories == categories)
    #expect(layout.overflowCategories.isEmpty)
}

@Test
func categoryTabsHideWhenScrollingDownAndReturnWhenScrollingUp() {
    #expect(!DuoCategoryTabScrollState.isVisible(forFingerMovement: -20))
    #expect(DuoCategoryTabScrollState.isVisible(forFingerMovement: 20))
}

@Test
func actionBarShowsAtMostFourActionsAndKeepsTheRestForMore() {
    let actions = (1...6).map { index in
        DuoToolbarAction(
            id: "action.\(index)",
            title: "Action \(index)",
            systemImage: "circle",
            perform: {}
        )
    }
    let layout = DuoActionBarLayout(actions: actions)

    #expect(layout.visibleActions.map(\.id) == ["action.1", "action.2", "action.3", "action.4"])
    #expect(layout.overflowActions.map(\.id) == ["action.5", "action.6"])
}

@Test
func actionBarDoesNotOverflowFourOrFewerActions() {
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
