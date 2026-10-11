import XCTest

final class PasswordManageriOSLaunchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testInitialVaultScreenHasRequiredControls() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        let initializeTitle = app.staticTexts["Initialize Vault"]
        let unlockTitle = app.staticTexts["Unlock Vault"]
        XCTAssertTrue(
            initializeTitle.waitForExistence(timeout: 8) || unlockTitle.waitForExistence(timeout: 1),
            "Expected the launch screen to show Initialize Vault or Unlock Vault."
        )

        XCTAssertTrue(
            app.secureTextFields["Master password"].waitForExistence(timeout: 3),
            "Expected the master password field to be visible on launch."
        )

        if initializeTitle.exists {
            XCTAssertTrue(
                app.secureTextFields["Confirm master password"].exists,
                "Expected the confirmation field for first-run vault setup."
            )
            XCTAssertTrue(
                app.buttons["Create Vault"].exists,
                "Expected the Create Vault action for first-run vault setup."
            )
        } else {
            XCTAssertTrue(
                app.buttons["Unlock"].exists,
                "Expected the Unlock action for an existing vault."
            )
        }
    }

    func testVaultFormRemainsReachableWithKeyboardAndRotation() throws {
        let app = XCUIApplication()
        app.launch()
        let password = app.secureTextFields["Master password"]
        XCTAssertTrue(password.waitForExistence(timeout: 8))
        password.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "Tapping an input must show the software keyboard.")
        let instruction = app.staticTexts["Enter the master password to continue."].exists
            ? app.staticTexts["Enter the master password to continue."]
            : app.staticTexts["Set a master password for the local native vault."]
        instruction.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        password.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        // Exercise layout without submitting or changing the vault credential.
        password.typeText("layout-test-input")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))

        let action = app.buttons["Create Vault"].exists
            ? app.buttons["Create Vault"] : app.buttons["Unlock"]
        for _ in 0..<4 where !action.isHittable {
            app.scrollViews.firstMatch.swipeUp()
        }
        let keyboardScreenshot = XCTAttachment(screenshot: app.screenshot())
        keyboardScreenshot.name = "Vault form after keyboard and rotation"
        keyboardScreenshot.lifetime = .keepAlways
        add(keyboardScreenshot)
        XCTAssertTrue(action.isHittable, "The primary vault action must remain reachable with the keyboard open.")
        XCTAssertGreaterThan(password.frame.width, 0)
        let windowBounds = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(password.frame.minX, windowBounds.minX)
        XCTAssertLessThanOrEqual(password.frame.maxX, windowBounds.maxX)
    }

    #if DEBUG
    private func launchFixture(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-vault", "-ApplePersistenceIgnoreState", "YES"] + extraArguments
        app.launch()
        XCTAssertTrue(app.staticTexts["Duo Test Alpha"].waitForExistence(timeout: 12))
        return app
    }

    func testCategoryKeyboardDismissalAndCredentialShortcuts() throws {
        let app = launchFixture()
        showSidebar(in: app)
        for _ in 0..<5 where !app.buttons["Create Category"].firstMatch.isHittable {
            app.swipeUp()
        }
        tapVisibleButton("Create Category", in: app)
        let category = app.textFields["Category"]
        XCTAssertTrue(category.waitForExistence(timeout: 3))
        category.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        category.typeText("Keyboard Regression")
        app.staticTexts["Create a category without opening the entry editor."].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3), "Tapping non-input content must end editing.")
        category.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        app.buttons["服务器"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3), "Shortcut buttons must also end editing.")
        for title in ["服务", "账号", "服务器"] {
            app.buttons[title].tap()
        }
        // The Form lazily creates rows; scroll through the appended fields.
        let form = app.descendants(matching: .any)["category-creation-form"].firstMatch
        XCTAssertTrue(form.exists)
        for _ in 0..<6 where !app.textFields.matching(NSPredicate(format: "value == '密码'")).firstMatch.isHittable {
            form.swipeUp()
        }
        let username = app.textFields.matching(NSPredicate(format: "value == '用户名'")).firstMatch
        let password = app.textFields.matching(NSPredicate(format: "value == '密码'")).firstMatch
        XCTAssertTrue(username.exists, app.textFields.debugDescription)
        XCTAssertTrue(password.isHittable, app.textFields.debugDescription)
        password.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        username.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Switching inputs must keep editing active.")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Keyboard Regression"].exists, "Cancel must not save the category.")
    }

    func testEntryNavigationAndSearchSurviveRotation() throws {
        let app = launchFixture()
        app.staticTexts["Duo Test Alpha"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 3))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 3))
        XCUIDevice.shared.orientation = .portrait
        // A collapsed split view exposes a native back button; wide layouts keep the list visible.
        if !app.staticTexts["Duo Test Beta"].firstMatch.isHittable {
            let back = app.buttons["BackButton"].exists
                ? app.buttons["BackButton"] : app.navigationBars.buttons["Entries"].firstMatch
            XCTAssertTrue(back.isHittable)
            back.tap()
        }
        let search = app.searchFields.firstMatch
        if !search.isHittable, app.buttons["Search"].firstMatch.isHittable {
            app.buttons["Search"].firstMatch.tap()
        }
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("Beta")
        XCTAssertTrue(app.staticTexts["Duo Test Beta"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.cells.containing(.staticText, identifier: "Duo Test Alpha").firstMatch.isHittable)
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(app.staticTexts["Duo Test Beta"].firstMatch.waitForExistence(timeout: 3))
        defer { XCUIDevice.shared.orientation = .portrait }
    }
    private func tapVisibleButton(_ name: String, in app: XCUIApplication) {
        // Native toolbars move actions into More when the current width or text size needs it.
        if !app.buttons.matching(identifier: name).allElementsBoundByIndex.contains(where: { $0.isHittable }),
           app.buttons["More"].firstMatch.isHittable {
            app.buttons["More"].firstMatch.tap()
        }
        let reachable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons.matching(identifier: name).allElementsBoundByIndex.contains { $0.isHittable }
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [reachable], timeout: 5), .completed,
                       "Expected a reachable \(name) action after navigation. \(app.buttons.debugDescription)")
        let button = app.buttons.matching(identifier: name).allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(button, "Expected a reachable \(name) action. \(app.buttons.debugDescription)")
        button?.tap()
    }

    func testEditorToolbarSaveCancelAndExport() throws {
        let app = launchFixture()
        app.staticTexts["Duo Test Alpha"].firstMatch.tap()
        app.buttons["Edit"].tap()
        let label = app.textFields["Label"]
        XCTAssertTrue(label.waitForExistence(timeout: 3))
        XCTAssertEqual(label.value as? String, "Duo Test Alpha")
        label.tap()
        label.typeText(" Updated")
        app.navigationBars["Edit Entry"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertEqual(label.value as? String, "Duo Test Alpha Updated")
        XCTAssertTrue(app.buttons["entry-editor-save"].isHittable)
        app.buttons["entry-editor-save"].tap()
        XCTAssertTrue(app.staticTexts["entry-detail-title"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["entry-detail-title"].label, "Duo Test Alpha Updated")
        app.buttons["Export"].tap()
        XCTAssertTrue(app.buttons["Export All"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Export Selected"].isEnabled)
        app.buttons["Cancel"].tap()
        tapVisibleButton("Add Entry", in: app)
        XCTAssertTrue(app.textFields["Label"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["entry-editor-save"].isEnabled)
        app.buttons["entry-editor-cancel"].tap()
        tapVisibleButton("Import Entry/Category JSON", in: app)
        XCTAssertTrue(app.buttons["Import"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Import"].isEnabled)
        app.buttons["Cancel"].tap()
        tapVisibleButton("Lock", in: app)
        XCTAssertTrue(app.staticTexts["Unlock Vault"].waitForExistence(timeout: 3))
    }
    func testUnsavedEditorDraftSurvivesRotationAndCancelDoesNotSave() throws {
        let app = launchFixture()
        app.staticTexts["Duo Test Alpha"].firstMatch.tap()
        app.buttons["Edit"].tap()
        let label = app.textFields["Label"]
        XCTAssertTrue(label.waitForExistence(timeout: 3))
        label.tap()
        label.typeText(" Unsaved")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(label.value as? String, "Duo Test Alpha Unsaved")
        XCTAssertTrue(app.buttons["entry-editor-save"].isHittable)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(label.value as? String, "Duo Test Alpha Unsaved")
        app.buttons["entry-editor-cancel"].tap()
        XCTAssertEqual(app.staticTexts["entry-detail-title"].label, "Duo Test Alpha")
        app.buttons["Edit"].tap()
        XCTAssertEqual(app.textFields["Label"].value as? String, "Duo Test Alpha")
        app.buttons["entry-editor-cancel"].tap()
    }

    private func showSidebar(in app: XCUIApplication) {
        for _ in 0..<2 where !app.buttons["All Items"].firstMatch.isHittable {
            let navigation = app.buttons.matching(NSPredicate(
                format: "identifier CONTAINS[c] 'Sidebar' OR label CONTAINS[c] 'Sidebar' OR identifier == 'BackButton' OR label == 'Vault'"
            )).allElementsBoundByIndex.first { $0.isHittable }
            XCTAssertNotNil(navigation, app.buttons.debugDescription)
            navigation?.tap()
        }
        XCTAssertTrue(app.buttons["All Items"].firstMatch.isHittable)
    }

    func testSettingsDraftSurvivesRotationWithoutSaving() throws {
        let app = launchFixture()
        showSidebar(in: app)
        let sidebar = app.descendants(matching: .any)["vault-sidebar"].firstMatch
        for _ in 0..<4 where !app.buttons["Settings"].firstMatch.isHittable {
            sidebar.swipeUp()
        }
        tapVisibleButton("Settings", in: app)
        let provider = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Provider'")).firstMatch
        XCTAssertTrue(provider.waitForExistence(timeout: 3))
        provider.tap()
        app.buttons["WebDAV"].tap()
        let url = app.textFields["WebDAV URL"]
        XCTAssertTrue(url.waitForExistence(timeout: 3))
        url.tap()
        url.typeText("https://example.invalid/duo-draft")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(url.value as? String, "https://example.invalid/duo-draft")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(url.value as? String, "https://example.invalid/duo-draft")
        app.buttons["Done"].tap()
        if !app.buttons["Settings"].firstMatch.isHittable {
            showSidebar(in: app)
        }
        for _ in 0..<4 where !app.buttons["Settings"].firstMatch.isHittable {
            sidebar.swipeUp()
        }
        tapVisibleButton("Settings", in: app)
        XCTAssertFalse(app.textFields["WebDAV URL"].exists)
        app.buttons["Done"].tap()
    }
    func testFilterNavigationAndEmptySearch() throws {
        let app = launchFixture()
        showSidebar(in: app)
        tapVisibleButton("Server", in: app)
        XCTAssertTrue(app.staticTexts["Duo Test Beta"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.cells.containing(.staticText, identifier: "Duo Test Alpha").firstMatch.isHittable)
        let search = app.searchFields.firstMatch
        if !search.isHittable, app.buttons["Search"].firstMatch.isHittable {
            app.buttons["Search"].firstMatch.tap()
        }
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("No matching Duo entry")
        XCTAssertTrue(app.staticTexts["No Entries"].waitForExistence(timeout: 3))
    }

    func testAccessibilityTextSizeKeepsEditorActionsReachable() throws {
        let app = launchFixture(extraArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        let rowTitle = app.staticTexts["Duo Test Alpha"].firstMatch
        let icon = app.cells.containing(.staticText, identifier: "Duo Test Alpha")
            .images.matching(NSPredicate(format: "identifier BEGINSWITH 'entry-list-icon-'"))
            .firstMatch
        XCTAssertTrue(icon.exists)
        XCTAssertGreaterThan(icon.frame.width, 18)
        XCTAssertLessThanOrEqual(icon.frame.maxX, rowTitle.frame.minX)
        app.staticTexts["Duo Test Alpha"].firstMatch.tap()
        let title = app.staticTexts["entry-detail-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(title.frame.height, 60, "The test must actually use an accessibility text size.")
        let detailScreenshot = XCTAttachment(screenshot: app.screenshot())
        detailScreenshot.name = "Accessibility detail toolbar"
        detailScreenshot.lifetime = .keepAlways
        add(detailScreenshot)
        tapVisibleButton("Edit", in: app)
        let label = app.textFields["Label"]
        XCTAssertTrue(label.waitForExistence(timeout: 3))
        label.tap()
        label.typeText(" Large")
        let capturedScreen = app.screenshot()
        let windowBounds = app.windows.firstMatch.frame
        let screenshot = XCTAttachment(screenshot: capturedScreen)
        screenshot.name = "Accessibility editor after typing"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertTrue(app.buttons["entry-editor-save"].isHittable)
        XCTAssertTrue(app.buttons["entry-editor-cancel"].isHittable)
        // Duo's inner display can rotate independently of the app orientation reported by XCTest.
        // The window follows the display's current geometry in the same point coordinates as the field.
        XCTAssertGreaterThanOrEqual(label.frame.minX, windowBounds.minX)
        XCTAssertLessThanOrEqual(label.frame.maxX, windowBounds.maxX)
        app.buttons["entry-editor-cancel"].tap()
        XCTAssertEqual(title.label, "Duo Test Alpha")
    }
    #endif

}
