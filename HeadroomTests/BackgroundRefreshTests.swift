import XCTest
import UIKit
@testable import Headroom

@MainActor
final class BackgroundRefreshTests: XCTestCase {
    private final class Clock { var date = Date(timeIntervalSince1970: 1_800_000_000) }
    private func defaults() throws -> UserDefaults { try XCTUnwrap(UserDefaults(suiteName: "HeadroomBackground.\(UUID())")) }
    private func capture(provider: AIProvider, user: String, workspace: String, percent: Double, at date: Date) throws -> ProviderCapture {
        let raw: [String: Any] = provider == .claude ? ["five_hour": ["utilization": percent], "seven_day": ["utilization": percent + 1]] : ["rate_limit": ["primary_window": ["used_percent": percent, "limit_window_seconds": 18000], "secondary_window": ["used_percent": percent + 1, "limit_window_seconds": 604800]]]
        let usage = try provider == .claude ? ProviderUsageParser.claude(raw, observedAt: date) : ProviderUsageParser.codex(raw, observedAt: date)
        let workspace = ProviderWorkspace(id: workspace, name: "Test workspace")
        return .init(identity: .init(id: user), workspaces: [workspace], workspace: workspace, usage: usage)
    }
    private func result(_ account: UsageAccount, percent: Double, at date: Date) throws -> ProviderCapture {
        try capture(provider: account.provider, user: account.providerUserID!, workspace: account.workspaceID!, percent: percent, at: date)
    }
    private func add(_ store: UsageStore, provider: AIProvider = .claude, at date: Date, native: Bool = true) throws -> UUID {
        let id = UUID(), user = "user-\(UUID())", workspace = "workspace-\(UUID())"
        let capture = try capture(provider: provider, user: user, workspace: workspace, percent: 10, at: date)
        let claude = native && provider == .claude ? ClaudeCredential(accessToken: "synthetic-access", refreshToken: "synthetic-refresh", expiresAt: date.addingTimeInterval(3600)) : nil
        let codex = native && provider == .chatGPT ? CodexCredential(accessToken: "synthetic-access", refreshToken: "synthetic-refresh", expiresAt: date.addingTimeInterval(3600), userID: user, accountID: workspace) : nil
        try store.connect(profileID: id, provider: provider, alias: "Test", capture: capture, claudeCredential: claude, codexCredential: codex)
        return id
    }
    private func until(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate())
    }

    func testBackgroundRefreshUpdatesBothNativeProvidersWithoutCreatingWebViews() async throws {
        let clock = Clock(), prefs = try defaults()
        var readIDs: [UUID] = []
        let store = UsageStore(defaults: prefs, now: { clock.date }, readOverride: { account in
            readIDs.append(account.id)
            return try self.result(account, percent: 25, at: clock.date)
        })
        let claude = try add(store, at: clock.date), codex = try add(store, provider: .chatGPT, at: clock.date)
        let web = try add(store, at: clock.date, native: false)
        defer { store.delete(claude); store.delete(codex); store.delete(web) }
        clock.date += 61
        let report = await store.refreshInBackground()
        XCTAssertEqual(report, .init(attempted: 2, updated: 2))
        XCTAssertEqual(Set(readIDs), Set([claude, codex]))
        XCTAssertEqual(store.account(claude)?.weekly.usedPercent, 26)
        XCTAssertEqual(store.account(codex)?.lastSyncedAt, clock.date)
        XCTAssertEqual(store.account(web)?.weekly.usedPercent, 11)
        XCTAssertTrue(store.browsers.browsers.isEmpty)
        let shared = WidgetSnapshotStore.load()
        XCTAssertEqual(shared.accounts.first { $0.id == codex }?.weekly.usedPercent, 26)
    }

    func testCancellationCannotPublishAResponseThatArrivesAfterExpiry() async throws {
        let clock = Clock()
        let store = UsageStore(defaults: try defaults(), now: { clock.date }, readOverride: { account in
            try? await Task.sleep(for: .milliseconds(150)) // Deliberately ignores cancellation.
            return try self.result(account, percent: 99, at: clock.date)
        })
        let id = try add(store, at: clock.date)
        defer { store.delete(id) }
        clock.date += 61
        let run = Task { await store.refreshInBackground() }
        try await until { store.refreshingIDs.contains(id) }
        run.cancel()
        let report = await run.value
        XCTAssertTrue(report.cancelled)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(store.account(id)?.weekly.usedPercent, 11)
        XCTAssertNil(store.account(id)?.syncError)
        XCTAssertFalse(store.isRefreshing)
    }

    func testCancellingBackgroundWorkDoesNotCancelForegroundRefresh() async throws {
        let clock = Clock()
        let store = UsageStore(defaults: try defaults(), now: { clock.date }, readOverride: { account in
            try await Task.sleep(for: .milliseconds(300))
            return try self.result(account, percent: 20, at: clock.date)
        })
        let foreground = try add(store, at: clock.date), background = try add(store, provider: .chatGPT, at: clock.date)
        defer { store.stopRefreshing(); store.delete(foreground); store.delete(background) }
        clock.date += 61
        store.refresh(accountID: foreground)
        let run = Task { await store.refreshInBackground() }
        try await until { store.refreshingIDs.count == 2 }
        run.cancel(); _ = await run.value
        XCTAssertTrue(store.refreshingIDs.contains(foreground))
        XCTAssertFalse(store.refreshingIDs.contains(background))
    }

    func testRateLimitCooldownPersistsAcrossRelaunchWithoutFresheningReadings() async throws {
        let clock = Clock(), prefs = try defaults()
        let store = UsageStore(defaults: prefs, now: { clock.date }, readOverride: { _ in throw ProviderSyncError.rateLimited(600) })
        let id = try add(store, at: clock.date)
        defer { store.delete(id) }
        let original = store.account(id)?.weekly
        clock.date += 61
        let failed = await store.refreshInBackground()
        XCTAssertEqual(failed.failed, 1)
        XCTAssertEqual(store.account(id)?.weekly, original)
        var reads = 0
        let restored = UsageStore(defaults: prefs, now: { clock.date }, readOverride: { account in
            reads += 1; return try self.result(account, percent: 30, at: clock.date)
        })
        defer { restored.delete(id) }
        let waiting = await restored.refreshInBackground()
        XCTAssertEqual(waiting.attempted, 0); XCTAssertEqual(reads, 0)
        clock.date += 601
        let updated = await restored.refreshInBackground()
        XCTAssertEqual(updated.updated, 1); XCTAssertEqual(reads, 1)
    }

    func testWidgetRefreshScopesAccountsAndKeepsOneMinuteCooldown() async throws {
        let clock = Clock()
        var reads: [UUID] = []
        let store = UsageStore(defaults: try defaults(), now: { clock.date }, readOverride: { account in
            reads.append(account.id); return try self.result(account, percent: 50, at: clock.date)
        })
        let first = try add(store, at: clock.date), second = try add(store, provider: .chatGPT, at: clock.date)
        defer { store.delete(first); store.delete(second) }
        clock.date += 61
        let report = await store.refreshInBackground(force: true, accountIDs: [first])
        XCTAssertEqual(report.updated, 1); XCTAssertEqual(reads, [first])
        XCTAssertEqual(store.account(second)?.weekly.usedPercent, 11)
        let cooldown = await store.refreshInBackground(force: true, accountIDs: [first])
        XCTAssertEqual(cooldown.attempted, 0)
        clock.date += 61
        let next = await store.refreshInBackground(force: true, accountIDs: [first])
        XCTAssertEqual(next.updated, 1)
    }

    func testSchedulingAddsNoDelayDeduplicatesAndHonorsOffAndSystemRestrictions() throws {
        let clock = Clock(), prefs = try defaults()
        let store = UsageStore(defaults: prefs, now: { clock.date })
        let id = try add(store, at: clock.date)
        defer { store.delete(id) }
        var requests: [Date?] = [], registrations = 0, cancellations = 0, availability = UIBackgroundRefreshStatus.available
        let controller = BackgroundRefreshController(store: store, defaults: prefs, availability: { availability }, registerTask: { _ in registrations += 1; return true }, submit: { requests.append($0) }, cancel: { cancellations += 1 })
        controller.schedule()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(controller.statusText, "Not registered")
        controller.register() // App launch alone queues the first request.
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(controller.registered)
        XCTAssertNotNil(controller.lastRequestedAt)
        XCTAssertEqual(controller.statusText, "Scheduled by iOS")
        controller.register()
        controller.schedule(); controller.schedule()
        XCTAssertEqual(registrations, 1)
        XCTAssertEqual(requests.count, 1); XCTAssertNil(requests[0])
        controller.enabled = false
        XCTAssertGreaterThan(cancellations, 0)
        controller.enabled = true
        XCTAssertEqual(requests.count, 2)
        availability = .denied; controller.updateAvailability()
        XCTAssertEqual(controller.statusText, "Off in iPhone Settings")
        XCTAssertEqual(requests.count, 2)
    }

    func testFailedRegistrationNeverSubmitsOrClaimsBackgroundWorkIsScheduled() throws {
        let clock = Clock(), prefs = try defaults()
        let store = UsageStore(defaults: prefs, now: { clock.date })
        let id = try add(store, at: clock.date)
        defer { store.delete(id) }
        var registrations = 0, requests = 0
        let controller = BackgroundRefreshController(store: store, defaults: prefs, availability: { .available }, registerTask: { _ in registrations += 1; return false }, submit: { _ in requests += 1 }, cancel: {})
        controller.register(); controller.register(); controller.updateAvailability()
        XCTAssertEqual(registrations, 1)
        XCTAssertEqual(requests, 0)
        XCTAssertFalse(controller.registered)
        XCTAssertFalse(controller.hasPendingRequest)
        XCTAssertNil(controller.lastRequestedAt)
        XCTAssertFalse(prefs.bool(forKey: "headroom.background.registered"))
        XCTAssertEqual(controller.statusText, "Could not schedule")
    }

    func testFailedSubmissionCanRetryWithoutRegisteringTheTaskAgain() throws {
        let clock = Clock(), prefs = try defaults()
        let store = UsageStore(defaults: prefs, now: { clock.date })
        let id = try add(store, at: clock.date)
        defer { store.delete(id) }
        var shouldFail = true, registrations = 0
        let controller = BackgroundRefreshController(store: store, defaults: prefs, availability: { .available }, registerTask: { _ in registrations += 1; return true }, submit: { _ in
            if shouldFail { throw ProviderSyncError.unavailable }
        }, cancel: {})
        controller.register()
        XCTAssertEqual(controller.statusText, "Could not schedule")
        XCTAssertFalse(controller.hasPendingRequest)
        XCTAssertNil(controller.lastRequestedAt)
        shouldFail = false
        controller.schedule()
        XCTAssertEqual(registrations, 1)
        XCTAssertTrue(controller.hasPendingRequest)
        XCTAssertEqual(controller.statusText, "Scheduled by iOS")
        XCTAssertEqual(prefs.object(forKey: "headroom.background.requestedAt") as? Date, controller.lastRequestedAt)
    }

    func testDeadlineCompletesOnceAndCancelsRequestsWithoutChangingSavedReadings() async throws {
        let clock = Clock(), prefs = try defaults()
        let store = UsageStore(defaults: prefs, now: { clock.date }, readOverride: { account in
            try? await Task.sleep(for: .milliseconds(150))
            return try self.result(account, percent: 90, at: clock.date)
        })
        let id = try add(store, at: clock.date)
        defer { store.delete(id) }
        clock.date += 61
        let controller = BackgroundRefreshController(store: store, defaults: prefs, budget: 0.02, availability: { .available }, submit: { _ in }, cancel: {})
        var completions: [Bool] = []
        controller.beginRun { completions.append($0) }
        try await until { !completions.isEmpty }
        controller.expireActive()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(completions, [false])
        XCTAssertEqual(controller.lastOutcome, .expired)
        XCTAssertEqual(store.account(id)?.weekly.usedPercent, 11)
        XCTAssertFalse(store.isRefreshing)
    }
}
