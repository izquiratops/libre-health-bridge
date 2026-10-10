import XCTest

final class LibreHealthBridgeUITests: XCTestCase {
    @MainActor
    private func launch(scenario: String, screen: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "--ui-scenario", scenario
        ]
        if let screen { app.launchArguments += ["--ui-screen", screen] }
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
        XCTAssertEqual(tabs.buttons.count, 2)
        XCTAssertTrue(app.buttons["login.open"].waitForExistence(timeout: 5))
        screenshot(app, named: "signed-out-home")

        tabs.buttons["Information"].tap()
        XCTAssertTrue(app.navigationBars["Information"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "convenient way")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Privacy and limitations")).firstMatch.exists)
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
        let confirmation = app.switches["health.setup.confirm"]
        XCTAssertTrue(confirmation.exists)
        XCTAssertEqual(confirmation.value as? String, "0")
        screenshot(app, named: "setup-sheet")
        app.navigationBars.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["health.sync"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testConfirmationPermissionThenExplicitImport() {
        let app = launch(scenario: "setup", screen: "setup")
        let confirmation = app.switches["health.setup.confirm"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: confirmation)], timeout: 10), .completed)
        XCTAssertFalse(app.buttons["health.setup.sync"].isEnabled)
        // The outer Form row is also exposed as a switch. Tap its trailing control,
        // not the row's midpoint (which does not toggle on iOS 27).
        confirmation.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "1"), object: confirmation)], timeout: 5), .completed)
        screenshot(app, named: "after-confirmation")
        let permission = app.buttons["Allow Health access"]
        XCTAssertTrue(permission.waitForExistence(timeout: 5))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: permission)], timeout: 10), .completed)
        // Health access sits below the pinned import action on a compact sheet.
        app.swipeUp()
        XCTAssertTrue(permission.isHittable)
        permission.tap()
        XCTAssertTrue(app.staticTexts["Allowed"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["health.setup.sync"].waitForExistence(timeout: 5))
        let importButton = app.buttons["health.setup.sync"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: importButton)], timeout: 10), .completed)
        importButton.tap()
        XCTAssertTrue(app.buttons["health.stop"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Last completed sync"].exists)
    }

    @MainActor
    func testFailureOnActualImport() {
        let app = launch(scenario: "health-save")
        XCTAssertTrue(app.alerts["Action needed"].waitForExistence(timeout: 5))
        app.buttons["Dismiss"].tap()
        app.buttons["health.sync"].tap()
        XCTAssertTrue(app.alerts["Action needed"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Health import did not finish")).firstMatch.exists)
        XCTAssertFalse(app.alerts["Sync complete"].exists)
    }

    @MainActor
    func testStopBeforeOpeningHealthSetup() {
        let app = launch(scenario: "ready")
        XCTAssertFalse(app.buttons["profile.select"].exists)
        app.buttons["health.stop"].tap()
        XCTAssertTrue(app.buttons["health.sync"].waitForExistence(timeout: 5))
        app.buttons["health.sync"].tap()
        XCTAssertTrue(app.buttons["profile.select"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Synchronization stopped"].exists)
    }

    @MainActor
    func testErrorOnHome() {
        let app = launch(scenario: "error")
        XCTAssertTrue(app.alerts["Action needed"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "cloud request failed")).firstMatch.exists)
        screenshot(app, named: "network-error-home")
        app.buttons["Dismiss"].tap()
        XCTAssertFalse(app.alerts["Action needed"].exists)
    }

    @MainActor
    func testCloudFailuresUseSafeMessages() {
        let cases: [(String, String)] = [
            ("terms-required", "review its required terms"),
            ("rate-limited", "rate limit was reached"),
            ("wrong-patient", "another connection"),
            ("invalid-credentials", "Login failed"),
            ("invalid-response", "unexpected response"),
            ("secure-storage", "Secure storage is unavailable"),
            ("health-save", "Health import did not finish")
        ]
        for (scenario, message) in cases {
            let app = launch(scenario: scenario)
            XCTAssertTrue(app.alerts["Action needed"].waitForExistence(timeout: 5), scenario)
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", message)).firstMatch.exists, scenario)
            XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "fixture-patient-01")).firstMatch.exists)
            screenshot(app, named: "failure-\(scenario)")
            app.terminate()
        }
    }

    @MainActor
    func testMissingConnectionsBlockImport() {
        for (scenario, message) in [
            ("no-profiles", "No profiles available"),
            ("missing-profile", "Profile not found")
        ] {
            let app = launch(scenario: scenario, screen: "setup")
            XCTAssertTrue(app.buttons["profile.select"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["profile.select"].isEnabled)
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", message)).firstMatch.exists)
            XCTAssertFalse(app.buttons["health.setup.sync"].isEnabled)
            screenshot(app, named: "blocked-\(scenario)-setup")
            app.terminate()
        }
    }

    @MainActor
    func testMissingOrStaleReadingCannotBeConfirmed() {
        for (scenario, message) in [
            ("no-reading", "No valid recent reading"),
            ("stale-reading", "may be out of date")
        ] {
            let app = launch(scenario: scenario, screen: "setup")
            XCTAssertTrue(app.switches["health.setup.confirm"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", message)).firstMatch.exists)
            XCTAssertFalse(app.switches["health.setup.confirm"].isEnabled)
            XCTAssertFalse(app.buttons["health.setup.sync"].isEnabled)
            screenshot(app, named: "blocked-\(scenario)-setup")
            app.terminate()
        }
    }

    @MainActor
    func testHealthAccessBlockedUntilAuthorized() {
        for (scenario, message) in [
            ("permission-denied", "Enable Blood Glucose writes"),
            ("health-unavailable", "Health is unavailable")
        ] {
            let app = launch(scenario: scenario, screen: "setup")
            XCTAssertTrue(app.buttons["health.setup.sync"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", message)).firstMatch.exists)
            XCTAssertFalse(app.buttons["health.setup.sync"].isEnabled)
            if scenario == "health-unavailable" {
                XCTAssertFalse(app.buttons["Open Health to enable access"].exists)
            } else {
                let openHealth = app.buttons["Open Health to enable access"]
                if !openHealth.exists { app.swipeUp() }
                XCTAssertTrue(openHealth.waitForExistence(timeout: 5))
            }
            screenshot(app, named: "blocked-\(scenario)-setup")
            app.terminate()
        }
    }

    @MainActor
    func testStoppedSyncNeedsExplicitResume() {
        let app = launch(scenario: "paused")
        XCTAssertTrue(app.staticTexts["Synchronization stopped"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["health.stop"].exists)
        screenshot(app, named: "paused-home")
        app.buttons["health.sync"].tap()
        XCTAssertTrue(app.buttons["health.setup.sync"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["health.setup.sync"].isEnabled)
        XCTAssertEqual(app.switches["health.setup.confirm"].value as? String, "1")
        XCTAssertTrue(app.staticTexts["Synchronization stopped"].exists)
        screenshot(app, named: "paused-setup")
        app.buttons["health.setup.sync"].tap()
        XCTAssertTrue(app.buttons["health.stop"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Synchronization stopped"].exists)
    }

    @MainActor
    func testLoginAndLogoutUseSyntheticAdapters() {
        let app = launch(scenario: "signed-out", screen: "login")
        let email = app.textFields["login.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap()
        email.typeText("alex@example.invalid")
        let password = app.secureTextFields["login.password"]
        password.tap()
        password.typeText("synthetic-password")
        app.buttons["login.submit"].tap()
        XCTAssertTrue(app.buttons["account.logout"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["health.stop"].exists, "Login cannot import or start sync")
        app.buttons["account.logout"].tap()
        XCTAssertTrue(app.alerts["Log out?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Log out"].tap()
        XCTAssertTrue(app.buttons["login.open"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testEmptyLoginCannotSubmitAndLogoutCanBeCancelled() {
        let signedOut = launch(scenario: "signed-out", screen: "login")
        XCTAssertTrue(signedOut.buttons["login.submit"].waitForExistence(timeout: 5))
        XCTAssertFalse(signedOut.buttons["login.submit"].isEnabled)
        screenshot(signedOut, named: "blocked-empty-login")
        signedOut.terminate()

        let ready = launch(scenario: "ready")
        ready.buttons["account.logout"].tap()
        XCTAssertTrue(ready.alerts["Log out?"].waitForExistence(timeout: 5))
        screenshot(ready, named: "logout-confirmation")
        ready.buttons["Cancel"].tap()
        XCTAssertTrue(ready.buttons["health.stop"].exists)
    }
}
