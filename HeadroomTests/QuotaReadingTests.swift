import XCTest
@testable import Headroom

final class QuotaReadingTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testUnknownIsNotZero() {
        let reading = QuotaReading.unavailable
        XCTAssertNil(reading.displayPercent)
        XCTAssertNil(reading.widgetPercent(at: now))
        XCTAssertEqual(reading.state(at: now), .unavailable)
    }

    func testPassedResetDoesNotInventFreshCapacity() {
        let reading = QuotaReading(usedPercent: 84, observedAt: now.addingTimeInterval(-60), resetsAt: now.addingTimeInterval(-1), source: .manual)
        XCTAssertEqual(reading.state(at: now), .awaitingReset)
        XCTAssertNil(reading.widgetPercent(at: now))
        XCTAssertEqual(reading.displayPercent, 84, "Retain the historical reading")
    }

    func testStaleReadingPreservesValueAndObservationTime() {
        let observed = now.addingTimeInterval(-3600)
        let reading = QuotaReading(usedPercent: 31, observedAt: observed, resetsAt: now.addingTimeInterval(3600), source: .manual)
        XCTAssertEqual(reading.state(at: now), .stale)
        XCTAssertEqual(reading.widgetPercent(at: now), 31)
        XCTAssertEqual(reading.observedAt, observed)
    }

    func testPercentBoundsAndNonFiniteValues() {
        var reading = QuotaReading(usedPercent: -10, observedAt: now, resetsAt: nil, source: .manual)
        XCTAssertEqual(reading.displayPercent, 0)
        reading.usedPercent = 120
        XCTAssertEqual(reading.displayPercent, 100)
        reading.usedPercent = .nan
        XCTAssertNil(reading.displayPercent)
    }

    func testWeeklyUpdateDoesNotFreshenSessionOrAnotherAccount() {
        var accounts = UsageFixtures.accounts(now: now)
        let originalSession = accounts[0].session
        let otherAccount = accounts[1]
        accounts[0].record(.init(usedPercent: 90, observedAt: now, resetsAt: nil, source: .manual), for: .weekly)
        XCTAssertEqual(accounts[0].session, originalSession)
        XCTAssertEqual(accounts[0].weekly.usedPercent, 90)
        XCTAssertEqual(accounts[1], otherAccount)
        XCTAssertEqual(accounts[0].history.last?.period, .weekly)
    }

    func testOlderAccountsDecodeWithoutModelLimits() throws {
        let original = UsageFixtures.accounts(now: now)[0]
        let data = try JSONEncoder().encode(original)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "modelLimits")
        if var observations = legacy["history"] as? [[String: Any]] {
            for index in observations.indices {
                observations[index].removeValue(forKey: "modelLimitID")
                observations[index].removeValue(forKey: "windowLabel")
            }
            legacy["history"] = observations
        }
        let migrated = try JSONDecoder().decode(UsageAccount.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(migrated.modelLimits.isEmpty)
        XCTAssertEqual(migrated.weekly, original.weekly)
        XCTAssertEqual(migrated.history, original.history)
    }

    func testModelUpdateIsIsolatedFromAccountAndOtherModelLimits() throws {
        var account = UsageFixtures.accounts(now: now)[0]
        let original = account
        var limit = try XCTUnwrap(account.modelLimits.first)
        limit.reading = .init(usedPercent: 91, observedAt: now, resetsAt: nil, source: .manual)
        account.recordModelLimit(limit)
        XCTAssertEqual(account.session, original.session)
        XCTAssertEqual(account.weekly, original.weekly)
        XCTAssertEqual(account.modelLimits[1], original.modelLimits[1])
        XCTAssertEqual(account.modelLimits.count, original.modelLimits.count)
        XCTAssertEqual(account.history.last?.modelLimitID, limit.id)
        XCTAssertNil(account.history.last?.period)
        XCTAssertEqual(try JSONDecoder().decode(UsageAccount.self, from: JSONEncoder().encode(account)), account)
    }

    func testCountsNormalizeWithoutInventingTokenTotals() {
        let count = QuotaCount(used: 18, limit: 50, unit: .messages)
        let model = ModelQuotaLimit(modelName: "Example", windowLabel: "Daily", reading: .init(usedPercent: nil, observedAt: now, resetsAt: nil, source: .manual), count: count)
        XCTAssertEqual(model.quotaReading.displayPercent, 36)
        XCTAssertEqual(model.count?.unit, .messages)
        XCTAssertNil(QuotaCount(used: 1, limit: 0, unit: .tokens).percent)
        XCTAssertNil(QuotaCount(used: .infinity, limit: 100, unit: .tokens).percent)
        XCTAssertNil(QuotaCount(used: 1, limit: .infinity, unit: .tokens).percent)
        XCTAssertNil(UsageFixtures.accounts(now: now)[0].modelLimits[0].count)
    }

    func testModelResetAndIdentityAreAccountScoped() {
        let accounts = UsageFixtures.accounts(now: now)
        var model = accounts[0].modelLimits[0]
        XCTAssertNotEqual(model.scopedID(accountID: accounts[0].id), model.scopedID(accountID: accounts[1].id))
        model.reading.resetsAt = now.addingTimeInterval(-1)
        XCTAssertNil(model.quotaReading.widgetPercent(at: now))
        XCTAssertEqual(accounts[0].weekly.widgetPercent(at: now), 52)
    }

    @MainActor
    func testManualAccountPersistsWithoutBecomingConnected() throws {
        let suite = "HeadroomTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(defaults: defaults)
        let id = store.add(provider: .claude, alias: "Second", plan: "Pro")
        store.record(accountID: id, period: .weekly, percent: 42, reset: nil, observedAt: now)
        store.recordModelLimit(accountID: id, id: nil, modelName: "Example", windowLabel: "Daily", percent: 25, count: .init(used: 5, limit: 20, unit: .messages), reset: nil, observedAt: now)
        let reopened = UsageStore(defaults: defaults)
        XCTAssertEqual(reopened.account(id)?.weekly.usedPercent, 42)
        XCTAssertNil(reopened.account(id)?.session.usedPercent)
        XCTAssertEqual(reopened.account(id)?.weekly.source, .manual)
        XCTAssertEqual(reopened.account(id)?.modelLimits.first?.quotaReading.displayPercent, 25)
        XCTAssertEqual(reopened.account(id)?.modelLimits.first?.count?.unit, .messages)
        reopened.delete(id)
        XCTAssertNil(reopened.account(id))
    }
}
