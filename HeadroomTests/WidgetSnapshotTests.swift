import XCTest
@testable import Headroom

final class WidgetSnapshotTests: XCTestCase {
    private func withSnapshot(_ snapshot: WidgetSnapshot, run: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode(snapshot).write(to: url)
        try run(url)
    }

    func testLegacyDemoSnapshotCannotReplaceRealProviderReadings() throws {
        let now = Date()
        var real = UsageAccount(id: UUID(), provider: .chatGPT, alias: "Connected", plan: "Pro", session: .unavailable,
                                weekly: .init(usedPercent: 3, observedAt: now, resetsAt: now.addingTimeInterval(86400), source: .provider), history: [])
        real.providerUserID = "test-user"; real.workspaceID = "test-workspace"; real.connectionMethod = .codexOAuth
        try withSnapshot(.init(accounts: UsageFixtures.accounts(now: now) + [real], publishedAt: now)) { url in
            let result = WidgetSnapshotStore.loadResult(from: url)
            XCTAssertEqual(result.state, .ready)
            XCTAssertEqual(result.snapshot.accounts, [real])
            XCTAssertEqual(result.snapshot.accounts[0].weekly.widgetPercent(at: now), 3)
            XCTAssertEqual(result.snapshot.accounts[0].weekly.observedAt, now)
        }
    }

    func testUnreadableSnapshotIsAnErrorRatherThanAnEmptyAccountList() throws {
        XCTAssertEqual(WidgetSnapshotStore.loadResult(from: nil).state, .unavailable)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget-invalid-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(WidgetSnapshotStore.loadResult(from: url).state, .unavailable)
        try Data("invalid".utf8).write(to: url)
        XCTAssertEqual(WidgetSnapshotStore.loadResult(from: url).state, .unavailable)
        try withSnapshot(.empty) { XCTAssertEqual(WidgetSnapshotStore.loadResult(from: $0).state, .empty) }
    }

}
