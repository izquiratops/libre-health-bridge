import XCTest

final class LibreHealthBridgeUITests: XCTestCase {
    @MainActor
    private func launch(scenario: String, screen: String = "home") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "--ui-scenario", scenario, "--ui-screen", screen
        ]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testNativeTabsAndInformationSafety() {
        let app = launch(scenario: "signed-out")
        let tabs = app.tabBars.firstMatch
        XCTAssertEqual(tabs.buttons.count, 3)
        XCTAssertTrue(app.buttons["login.open"].waitForExistence(timeout: 5))
        screenshot(app, named: "signed-out-home")

        tabs.buttons["Details"].tap()
        XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 5))
        screenshot(app, named: "signed-out-details")

        tabs.buttons["Information"].tap()
        XCTAssertTrue(app.navigationBars["Information"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "secondary record")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "treatment decisions")).firstMatch.exists)
        screenshot(app, named: "information-safety")

        tabs.buttons.matching(NSPredicate(format: "label == %@", "Summary")).firstMatch.tap()
        XCTAssertTrue(app.buttons["login.open"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLoginPresentationAndClose() {
        let app = launch(scenario: "signed-out")
        app.buttons["login.open"].tap()
        XCTAssertTrue(app.textFields["login.email"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["login.password"].exists)
        XCTAssertTrue(app.buttons["login.submit"].exists)
        screenshot(app, named: "login-sheet")

        app.navigationBars.buttons["Close"].tap()
        XCTAssertTrue(app.textFields["login.email"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["login.open"].exists)
    }

    @MainActor
    func testSetupPresentation() {
        let app = launch(scenario: "setup")
        XCTAssertTrue(app.buttons["health.sync"].waitForExistence(timeout: 5))
        app.buttons["health.sync"].tap()
        XCTAssertTrue(app.buttons["profile.select"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["health.setup.sync"].exists)
        screenshot(app, named: "setup-sheet")
        app.navigationBars.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["health.sync"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testDetailsReportAndError() {
        let app = launch(scenario: "ready", screen: "details")
        XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["details.health.configure"].exists)
        for label in ["Newly imported", "Updated", "Skipped"] {
            XCTAssertTrue(app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch.exists)
        }
        screenshot(app, named: "ready-details-report")

        app.terminate()
        let errorApp = launch(scenario: "error")
        XCTAssertTrue(errorApp.staticTexts["Action needed"].waitForExistence(timeout: 5))
        screenshot(errorApp, named: "error-home")
    }
}
