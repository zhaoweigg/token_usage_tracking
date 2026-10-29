import XCTest

final class ApricotUITests: XCTestCase {
    private let claudeID = "10000000-0000-0000-0000-000000000011"
    private let chatGPTID = "10000000-0000-0000-0000-000000000012"

    private func fixture(activityHistory: Bool = false) throws -> String {
        let now = Date().timeIntervalSinceReferenceDate
        func reading(_ percent: Int, minutes: Int, reset: Double) -> [String: Any] {
            ["usedPercent": percent, "observedAt": now - 60, "resetsAt": now + reset, "source": "provider", "windowDurationMinutes": minutes]
        }
        var claude: [String: Any] = ["id": claudeID, "provider": "claude", "alias": "Personal", "plan": "Max",
                                    "session": reading(22, minutes: 300, reset: 8280), "weekly": reading(61, minutes: 10080, reset: 420000),
                                    "history": [], "lastSyncedAt": now - 60,
                                    "modelLimits": [["id": "style-sonnet", "modelName": "Sonnet", "windowLabel": "Weekly", "reading": reading(37, minutes: 10080, reset: 420000)]]]
        if activityHistory {
            func observation(_ age: Double, _ percent: Int) -> [String: Any] {
                ["id": UUID().uuidString, "date": now - age, "period": "session", "usedPercent": percent, "source": "provider"]
            }
            claude["history"] = (0..<20).map { _ in observation(4 * 86400, 20) } + [
                observation(3 * 86400, 8), observation(2 * 86400, 15),
                observation(86400, 3), observation(3600, 12), observation(60, 0)
            ]
        }
        let chatGPT: [String: Any] = ["id": chatGPTID, "provider": "chatGPT", "alias": "research.account.with.a.long.label@example.test", "plan": "Pro",
                                    "session": ["source": "provider"], "weekly": reading(38, minutes: 10080, reset: 525600),
                                    "history": [], "lastSyncedAt": now - 60, "modelLimits": []]
        return String(decoding: try JSONSerialization.data(withJSONObject: [claude, chatGPT]), as: UTF8.self)
    }

    @MainActor
    private func launch(dark: Bool = false, largeText: Bool = false, activityHistory: Bool = false) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-local-data"]
        if activityHistory { app.launchArguments.append("--preview-activity") }
        app.launchEnvironment["HEADROOM_UI_TEST_ACCOUNTS"] = try fixture(activityHistory: activityHistory)
        app.launchEnvironment["HEADROOM_UI_TEST_APPEARANCE"] = dark ? "dark" : "light"
        app.launchEnvironment["HEADROOM_UI_TEST_LARGE_TEXT"] = largeText ? "1" : "0"
        app.launch()
        return app
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor
    func testApricotOverviewFilteringAndBothWidgetSizes() throws {
        let app = try launch()
        XCTAssertTrue(app.buttons["provider-filter-chatGPT"].waitForExistence(timeout: 10))
        capture(app, name: "Apricot overview light")
        app.buttons["provider-filter-chatGPT"].tap()
        XCTAssertFalse(app.buttons["account-\(claudeID)"].exists)
        XCTAssertTrue(app.buttons["account-\(chatGPTID)"].exists)
        XCTAssertFalse(app.staticTexts["Session"].exists)
        app.buttons["provider-filter-all"].tap()
        app.buttons["widgets-button"].tap()
        XCTAssertTrue(app.staticTexts["Live overview"].waitForExistence(timeout: 5))
        capture(app, name: "Apricot medium widget light")
        app.segmentedControls["widget-size-picker"].buttons["Large"].tap()
        capture(app, name: "Apricot large widget light")
    }

    @MainActor
    func testApricotDarkModeWithAccessibilityTextAndLongAccountLabel() throws {
        let app = try launch(dark: true, largeText: true)
        XCTAssertTrue(app.buttons["provider-filter-chatGPT"].waitForExistence(timeout: 10))
        app.buttons["provider-filter-chatGPT"].tap()
        XCTAssertTrue(app.buttons["account-\(chatGPTID)"].exists)
        XCTAssertFalse(app.staticTexts["Session"].exists)
        capture(app, name: "Apricot dark accessibility text")
        app.buttons["account-\(chatGPTID)"].tap()
        XCTAssertTrue(app.staticTexts["Connection"].waitForExistence(timeout: 5))
        capture(app, name: "Apricot account detail dark accessibility text")
    }

    @MainActor
    func testActivityChartWithRepeatedCapturesInBothAppearances() throws {
        for dark in [false, true] {
            let app = try launch(dark: dark, activityHistory: true)
            let chart = app.descendants(matching: .any).matching(identifier: "quota-history-chart").firstMatch
            XCTAssertTrue(chart.waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["Captured quota observations"].exists)
            capture(app, name: dark ? "Quota history repeated captures dark" : "Quota history repeated captures light")
        }
    }
}
