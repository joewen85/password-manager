import XCTest
@testable import PasswordManageriOSCore

final class DuoToolbarLayoutTests: XCTestCase {
    func testBottomBarIsLimitedToRegularWidthPhoneInPortrait() {
        XCTAssertTrue(DuoToolbarLayout.usesBottomBar(
            isPhone: true,
            isRegularWidth: true,
            displaySize: CGSize(width: 669, height: 951)
        ))
    }

    func testLandscapePhoneKeepsSystemVerticalToolbar() {
        XCTAssertFalse(DuoToolbarLayout.usesBottomBar(
            isPhone: true,
            isRegularWidth: true,
            displaySize: CGSize(width: 951, height: 669)
        ))
    }

    func testIPadKeepsItsNativeToolbarInPortrait() {
        XCTAssertFalse(DuoToolbarLayout.usesBottomBar(
            isPhone: false,
            isRegularWidth: true,
            displaySize: CGSize(width: 1024, height: 1366)
        ))
    }

    func testCompactWidthPhoneKeepsItsNativeToolbar() {
        XCTAssertFalse(DuoToolbarLayout.usesBottomBar(
            isPhone: true,
            isRegularWidth: false,
            displaySize: CGSize(width: 466, height: 678)
        ))
    }

    func testSquareWindowKeepsItsNativeToolbar() {
        XCTAssertFalse(DuoToolbarLayout.usesBottomBar(
            isPhone: true,
            isRegularWidth: true,
            displaySize: CGSize(width: 669, height: 669)
        ))
    }
}
