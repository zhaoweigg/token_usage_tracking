import XCTest
import Security
@testable import Headroom

@MainActor
final class DirectWidgetRefreshTests: XCTestCase {
    private func account(_ provider: AIProvider = .claude) -> UsageAccount {
        let reading = QuotaReading(usedPercent: 10, observedAt: .now.addingTimeInterval(-3600), resetsAt: nil, source: .provider)
        var account = UsageAccount(id: UUID(), provider: provider, alias: "Widget test", plan: "Test", session: reading, weekly: reading, history: [])
        account.providerUserID = "test-user"; account.workspaceID = "test-workspace"
        account.connectionMethod = provider == .claude ? .claudeOAuth : .codexOAuth
        account.connectionGeneration = UUID(); account.lastSyncedAt = reading.observedAt
        return account
    }
    private func capture(_ account: UsageAccount, percent: Double = 25) -> ProviderCapture {
        let reading = QuotaReading(usedPercent: percent, observedAt: .now, resetsAt: nil, source: .provider)
        let workspace = ProviderWorkspace(id: account.workspaceID!, name: "Test workspace")
        return .init(identity: .init(id: account.providerUserID!), workspaces: [workspace], workspace: workspace,
                     usage: .init(session: reading, weekly: reading, limits: [], plan: "Test", observedAt: reading.observedAt!))
    }
    private func until(_ check: () -> Bool) async throws {
        let end = Date().addingTimeInterval(2)
        while !check(), Date() < end { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(check())
    }

    func testWidgetFetchesBothProvidersAndAppCannotOverwriteNewReadingsWithOldDefaults() async throws {
        let accounts = [account(), account(.chatGPT)]
        try WidgetSnapshotStore.publish(accounts)
        defer { try? WidgetSnapshotStore.publish([]) }
        var reads = 0
        let reader = NativeUsageReader(readOverride: { account in reads += 1; return self.capture(account) })
        UserDefaults(suiteName: WidgetSnapshotStore.groupID)?.set(true, forKey: "headroom.automaticRefreshEnabled")
        let status = await WidgetUsageRefresh(reader: reader).refresh(automatic: true)
        XCTAssertEqual(reads, 2); XCTAssertEqual(status?.updated, 2)
        XCTAssertEqual(WidgetSnapshotStore.load().accounts.map(\.weekly.usedPercent), [25, 25])
        let suite = "HeadroomWidgetMerge.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(accounts), forKey: "headroom.accounts.v1")
        let reopened = UsageStore(defaults: defaults)
        XCTAssertEqual(reopened.accounts.map(\.weekly.usedPercent), [25, 25])
        XCTAssertEqual(WidgetSnapshotStore.load().accounts.map(\.weekly.usedPercent), [25, 25])
    }

    func testConcurrentAppAndWidgetReadsUseOneRequestAndPreserveTheCaptureTime() async throws {
        let account = account()
        try WidgetSnapshotStore.publish([account])
        defer { try? WidgetSnapshotStore.publish([]) }
        var calls = 0
        let reader = NativeUsageReader(readOverride: { account in
            calls += 1; try await Task.sleep(for: .milliseconds(80)); return self.capture(account)
        })
        let first = Task { try await reader.read(account, publish: true) }
        try await until { calls == 1 }
        let second = Task { try await reader.read(account, publish: true) }
        let one = try await first.value, two = try await second.value
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(one.usage?.observedAt, two.usage?.observedAt)
        XCTAssertEqual(WidgetSnapshotStore.load().accounts[0].lastSyncedAt, one.usage?.observedAt)
    }

    func testDeletedAccountCannotBeRepublishedByAWidgetRequest() async throws {
        let account = account()
        try WidgetSnapshotStore.publish([account])
        defer { try? WidgetSnapshotStore.publish([]) }
        var started = false
        let reader = NativeUsageReader(readOverride: { account in
            started = true; try await Task.sleep(for: .milliseconds(80)); return self.capture(account)
        })
        let work = Task { await WidgetUsageRefresh(reader: reader).refresh() }
        try await until { started }
        try WidgetSnapshotStore.publish([])
        _ = await work.value
        XCTAssertTrue(WidgetSnapshotStore.load().accounts.isEmpty)
    }

    func testReconnectGenerationRejectsAnOlderInFlightWidgetResponse() async throws {
        let original = account()
        try WidgetSnapshotStore.publish([original])
        defer { try? WidgetSnapshotStore.publish([]) }
        var started = false
        let reader = NativeUsageReader(readOverride: { account in
            started = true; try await Task.sleep(for: .milliseconds(80)); return self.capture(account, percent: 99)
        })
        let work = Task { await WidgetUsageRefresh(reader: reader).refresh() }
        try await until { started }
        var replacement = original; replacement.connectionGeneration = UUID()
        try WidgetSnapshotStore.publish([replacement])
        _ = await work.value
        let saved = try XCTUnwrap(WidgetSnapshotStore.load().accounts.first)
        XCTAssertEqual(saved.connectionGeneration, replacement.connectionGeneration)
        XCTAssertEqual(saved.weekly.usedPercent, 10)
    }

    func testProviderBackoffIsSharedAndFailureDoesNotFreshenSavedValues() async throws {
        let account = account()
        try WidgetSnapshotStore.publish([account])
        defer { try? WidgetSnapshotStore.publish([]) }
        var calls = 0
        let reader = NativeUsageReader(readOverride: { _ in calls += 1; throw ProviderSyncError.rateLimited(600) })
        let first = await WidgetUsageRefresh(reader: reader).refresh()
        let second = await WidgetUsageRefresh(reader: NativeUsageReader(readOverride: { account in calls += 1; return self.capture(account) })).refresh()
        XCTAssertEqual(first?.outcome, .waiting); XCTAssertEqual(second?.outcome, .waiting)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(WidgetSnapshotStore.load().accounts[0].weekly, account.weekly)
    }

    func testWidgetDeadlineCancelsWithoutPublishingALateResponse() async throws {
        let account = account()
        try WidgetSnapshotStore.publish([account])
        defer { try? WidgetSnapshotStore.publish([]) }
        let reader = NativeUsageReader(readOverride: { account in
            try? await Task.sleep(for: .milliseconds(150)); return self.capture(account, percent: 99)
        })
        let result = await WidgetUsageRefresh(reader: reader, budget: 0.02).refresh()
        XCTAssertEqual(result?.outcome, .expired)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(WidgetSnapshotStore.load().accounts[0].weekly, account.weekly)
    }

    func testPrivateKeychainCredentialMigratesToTheExistingSignedAppGroup() throws {
        let id = UUID(), service = "com.example.headroom.claude-oauth", vault = ClaudeCredentialVault()
        defer { vault.remove(id) }
        let credential = ClaudeCredential(accessToken: "synthetic-access", refreshToken: "synthetic-refresh", expiresAt: .now.addingTimeInterval(3600))
        let old: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: id.uuidString, kSecValueData as String: try JSONEncoder().encode(credential)]
        XCTAssertEqual(SecItemAdd(old as CFDictionary, nil), errSecSuccess)
        XCTAssertEqual(try vault.load(id), credential)
        let shared: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                     kSecAttrAccount as String: id.uuidString, kSecAttrAccessGroup as String: WidgetSnapshotStore.groupID]
        XCTAssertEqual(SecItemCopyMatching(shared as CFDictionary, nil), errSecSuccess)
        vault.remove(id)
        XCTAssertEqual(SecItemCopyMatching(shared as CFDictionary, nil), errSecItemNotFound)
    }

    func testAutomaticOffPreventsScheduledRequestsButKeepsManualRefreshAvailable() async throws {
        let account = account(), preferences = try XCTUnwrap(UserDefaults(suiteName: WidgetSnapshotStore.groupID))
        try WidgetSnapshotStore.publish([account])
        preferences.set(false, forKey: "headroom.automaticRefreshEnabled")
        defer { preferences.set(true, forKey: "headroom.automaticRefreshEnabled"); try? WidgetSnapshotStore.publish([]) }
        var calls = 0
        let reader = NativeUsageReader(readOverride: { account in calls += 1; return self.capture(account) })
        _ = await WidgetUsageRefresh(reader: reader).refresh(automatic: true)
        XCTAssertEqual(calls, 0)
        _ = await WidgetUsageRefresh(reader: reader).refresh()
        XCTAssertEqual(calls, 1)
    }
}
