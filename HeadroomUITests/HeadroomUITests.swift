import XCTest

final class HeadroomUITests: XCTestCase {
    @MainActor
    func testWidgetHostRedactionDoesNotReplaceResolvedContentWithALoadingOrLockGate() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-local-data", "--preview-widgets", "--preview-widget-privacy"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Connect an account"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Unlock for usage"].exists)
        XCTAssertFalse(app.staticTexts["Loading saved usage"].exists)
        let version = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "v[0-9].*")).firstMatch
        XCTAssertTrue(version.exists, app.debugDescription)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Widget preview with visible version"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertFalse(app.switches["Hide account aliases"].exists)
        XCTAssertFalse(app.switches["Hide quota values"].exists)
        XCTAssertFalse(app.staticTexts["84%"].exists)
        XCTAssertTrue(app.staticTexts["Live overview"].exists)
        XCTAssertFalse(app.staticTexts["Account allowance"].exists)
        XCTAssertFalse(app.staticTexts["Accounts overview"].exists)
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-local-data"]
        app.launch()
        return app
    }

    @MainActor
    func testEmptyOverviewAndWidgetGalleryHaveNoSeededAccounts() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Your usage starts here"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["app-version-label"].exists)
        XCTAssertFalse(app.staticTexts["Demo data · providers not connected"].exists)
        XCTAssertFalse(app.staticTexts["Claude / Personal"].exists)
        app.buttons["widgets-button"].tap()
        XCTAssertTrue(app.navigationBars["Widgets"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Connect an account"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.tabBars.buttons["Activity"].tap()
        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testBackgroundRefreshSettingCanBeTurnedOffAndPersists() {
        let app = launch()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let toggle = app.switches["background-refresh-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if !toggle.isHittable { app.swipeUp() }
        XCTAssertEqual(toggle.value as? String, "1")
        // SwiftUI exposes the whole labeled row as the switch's frame. Target
        // the trailing switch control rather than the center of its label.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let switchedOff = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [switchedOff], timeout: 3), .completed)
        app.buttons["Done"].tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
    }

    @MainActor
    func testClaudeSignInDoesNotCreateAnUnverifiedAccount() {
        let app = launch()
        app.buttons["overview-connect-button"].tap()
        XCTAssertTrue(app.navigationBars["Connect account"].waitForExistence(timeout: 5))
        app.buttons["sign-in-provider-button"].tap()
        XCTAssertTrue(app.navigationBars["Sign in to Claude"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["claude-browser-sign-in-button"].exists)
        XCTAssertFalse(app.buttons["connect-provider-account-button"].isEnabled)
        XCTAssertFalse(app.secureTextFields["claude-authorization-code-field"].exists)
        app.buttons["Use website sign-in instead"].tap()
        XCTAssertTrue(app.buttons["check-provider-usage-button"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Connect account"].tap()
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Your usage starts here"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testChatGPTSignInIsAvailableWithoutAnAPIKey() {
        let app = launch()
        app.buttons["overview-connect-button"].tap()
        app.segmentedControls["provider-picker"].buttons["ChatGPT"].tap()
        app.buttons["sign-in-provider-button"].tap()
        XCTAssertTrue(app.navigationBars["Sign in to ChatGPT"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["codex-device-sign-in-button"].exists)
        XCTAssertFalse(app.buttons["connect-provider-account-button"].isEnabled)
        app.buttons["Use browser return link instead"].tap()
        XCTAssertTrue(app.buttons["codex-browser-sign-in-button"].exists)
        XCTAssertFalse(app.buttons["connect-provider-account-button"].isEnabled)
        app.buttons["Use website sign-in instead"].tap()
        XCTAssertTrue(app.buttons["check-provider-usage-button"].waitForExistence(timeout: 5))
    }
}
