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
}
