import XCTest
import JavaScriptCore
import WebKit
@testable import Headroom

final class ProviderUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testClaudeDiscoversModelLimitsAndPreservesZeroVersusMissing() throws {
        let usage = try ProviderUsageParser.claude([
            "five_hour": ["utilization": 0], "seven_day": ["utilization": 42],
            "seven_day_sonnet": ["utilization": 81], "seven_day_new_model": ["utilization": 13], "seven_day_opus": NSNull()
        ], observedAt: now)
        XCTAssertEqual(usage.session.usedPercent, 0)
        XCTAssertEqual(usage.session.observedAt, now)
        XCTAssertEqual(usage.session.source, .provider)
        XCTAssertEqual(usage.session.windowDurationMinutes, 300)
        XCTAssertEqual(usage.weekly.usedPercent, 42)
        XCTAssertEqual(usage.limits.map(\.modelName).sorted(), ["New Model", "Sonnet"])
        XCTAssertTrue(usage.limits.allSatisfy { $0.reading.windowDurationMinutes == 10080 && $0.count == nil })
    }

    func testClaudeTypedLimitsRejectBooleansAndMalformedResponses() throws {
        let usage = try ProviderUsageParser.claude(["limits": [
            ["kind": "session", "percent": NSNull()], ["kind": "weekly_all", "percent": 9],
            ["kind": "weekly_scoped", "model_group": "fable", "percent": 25],
            ["kind": "weekly_scoped", "model_group": "invalid", "percent": true]
        ]], observedAt: now)
        XCTAssertNil(usage.session.observedAt)
        XCTAssertEqual(usage.weekly.usedPercent, 9)
        XCTAssertEqual(usage.limits.map(\.modelName), ["Fable"])
        XCTAssertThrowsError(try ProviderUsageParser.claude([:], observedAt: now))
    }

    func testClaudeNestedModelScopesKeepNamesWindowsAndZeroReadings() throws {
        let usage = try ProviderUsageParser.claude(["five_hour": NSNull(), "seven_day": NSNull(), "limits": [
            ["kind": "session", "percent": 0],
            ["kind": "weekly_all", "percent": 19],
            ["kind": "weekly_scoped", "percent": 61, "scope": ["model": ["id": "model-a", "display_name": "Model A"], "surface": "chat"]],
            ["kind": "weekly_scoped", "percent": 7, "scope": ["model": ["id": "model-b", "display_name": "Model B"]]]
        ]], observedAt: now)
        XCTAssertEqual(usage.session.usedPercent, 0)
        XCTAssertEqual(usage.weekly.usedPercent, 19)
        XCTAssertEqual(usage.limits.map(\.modelName), ["Model A", "Model B"])
        XCTAssertTrue(usage.limits.allSatisfy { $0.windowLabel == "Weekly" })
        XCTAssertThrowsError(try ProviderUsageParser.claude(["five_hour": NSNull(), "seven_day": NSNull(), "limits": []], observedAt: now)) {
            XCTAssertEqual($0 as? ProviderSyncError, .unavailable)
        }
    }

    func testCodexMapsActualDurationsAndBothModelWindows() throws {
        let usage = try ProviderUsageParser.codex([
            "plan_type": "plus",
            "rate_limit": ["primary_window": ["used_percent": 18, "limit_window_seconds": 18000], "secondary_window": ["used_percent": 62, "limit_window_seconds": 604800]],
            "additional_rate_limits": [["limit_name": "Fast model", "limit_id": "fast", "rate_limit": ["primary_window": ["used_percent": 11, "limit_window_seconds": 18000], "secondary_window": ["used_percent": 30, "limit_window_seconds": 604800]]]]
        ], observedAt: now)
        XCTAssertEqual(usage.session.usedPercent, 18)
        XCTAssertEqual(usage.weekly.usedPercent, 62)
        XCTAssertEqual(usage.limits.count, 2)
        XCTAssertEqual(Set(usage.limits.map(\.windowLabel)), ["5-hour", "Weekly"])
        XCTAssertEqual(usage.plan, "plus")
    }

    func testCodexDoesNotRelabelUnknownOrMonthlyWindows() throws {
        let usage = try ProviderUsageParser.codex(["rate_limit": ["primary_window": ["used_percent": 20], "secondary_window": ["used_percent": 50, "limit_window_seconds": 2592000]]], observedAt: now)
        XCTAssertNil(usage.session.usedPercent)
        XCTAssertNil(usage.weekly.usedPercent)
        XCTAssertEqual(Set(usage.limits.map(\.windowLabel)), ["Allowance", "30-day"])
        XCTAssertThrowsError(try ProviderUsageParser.codex([:], observedAt: now))
        XCTAssertNil(ProviderUsageParser.timestamp(1e300))
    }

    @MainActor
    func testUpgradeRemovesDemoButPreservesManualAccounts() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "HeadroomMigration.\(UUID())"))
        let empty = UsageStore(defaults: defaults)
        XCTAssertTrue(empty.accounts.isEmpty)
        let id = empty.add(provider: .chatGPT, alias: "Mine", plan: "Plus")
        empty.record(accountID: id, period: .weekly, percent: 7, reset: nil, observedAt: now)
        defaults.set(try JSONEncoder().encode(UsageFixtures.accounts(now: now) + empty.accounts), forKey: "headroom.accounts.v1")
        let upgraded = UsageStore(defaults: defaults)
        XCTAssertEqual(upgraded.accounts.map(\.id), [id])
        XCTAssertEqual(upgraded.account(id)?.weekly.usedPercent, 7)
        upgraded.delete(id)
    }

    @MainActor
    func testTwoAccountsStayIsolatedAndDuplicatesAreRejected() throws {
        let store = UsageStore(defaults: try XCTUnwrap(UserDefaults(suiteName: "HeadroomIdentity.\(UUID())")))
        let usage = try ProviderUsageParser.claude(["five_hour": ["utilization": 10], "seven_day": ["utilization": 20]], observedAt: now)
        var capture = ProviderCapture(identity: .init(id: "user-one", email: "one@example.test"), workspaces: [], workspace: .init(id: "workspace", name: "Personal"), usage: usage)
        let first = UUID()
        try store.connect(profileID: first, provider: .claude, alias: "First", capture: capture)
        XCTAssertThrowsError(try store.connect(profileID: UUID(), provider: .claude, alias: "Duplicate", capture: capture))
        let original = store.account(first)
        capture.identity.id = "user-two"
        XCTAssertThrowsError(try store.connect(profileID: first, provider: .claude, alias: "Wrong", capture: capture))
        XCTAssertEqual(store.account(first), original)
        let second = UUID()
        try store.connect(profileID: second, provider: .claude, alias: "Second", capture: capture)
        XCTAssertEqual(store.account(first)?.providerUserID, "user-one")
        XCTAssertEqual(store.account(second)?.providerUserID, "user-two")
        XCTAssertEqual(store.account(second)?.weekly.source, .provider)
        store.delete(first); store.delete(second)
    }

    func testClaudeBrowserTransportReadsUsageAndDetectsAccountChanges() throws {
        let fixtures: [String: Any] = ["/api/account": ["uuid": "person"], "/api/organizations": [["uuid": "org", "name": "Personal"]], "/api/organizations/org/usage": ["five_hour": ["utilization": 5], "seven_day": ["utilization": 8]]]
        let data = try runScript(provider: .claude, workspace: "org", fixtures: fixtures)
        XCTAssertEqual(try ProviderUsageParser.capture(data: data, provider: .claude).usage?.weekly.usedPercent, 8)
        let changed = try runScript(provider: .claude, workspace: "org", fixtures: fixtures, afterUser: "other")
        XCTAssertThrowsError(try ProviderUsageParser.capture(data: changed, provider: .claude)) { XCTAssertEqual($0 as? ProviderSyncError, .wrongAccount) }
    }

    func testClaudeAuthenticatedEmailCanIdentifyAnAccountWithoutUUID() throws {
        let fixtures: [String: Any] = [
            "/api/account": ["email_address": "Owner@example.test", "memberships": []],
            "/api/organizations": [["uuid": "org", "name": "Personal"]],
            "/api/organizations/org/usage": ["seven_day": ["utilization": 8]]
        ]
        let data = try runScript(provider: .claude, workspace: "org", fixtures: fixtures)
        let capture = try ProviderUsageParser.capture(data: data, provider: .claude)
        XCTAssertEqual(capture.identity.id, "claude-email:owner@example.test")
        XCTAssertEqual(capture.usage?.weekly.usedPercent, 8)
        let changed = try runScript(provider: .claude, workspace: "org", fixtures: fixtures, afterUser: "other")
        XCTAssertThrowsError(try ProviderUsageParser.capture(data: changed, provider: .claude)) { XCTAssertEqual($0 as? ProviderSyncError, .wrongAccount) }
    }

    func testConnectionDiagnosticIdentifiesFailureWithoutExportingProviderContents() throws {
        let data = try runScript(provider: .claude, workspace: nil, fixtures: ["/api/account": ["$status": 404, "$text": "sensitive-token@example.test"]])
        let diagnostic = try XCTUnwrap(ProviderReadDiagnostic.read(data, provider: .claude))
        XCTAssertEqual(diagnostic.step, .identity)
        XCTAssertEqual(diagnostic.status, 404)
        XCTAssertEqual(diagnostic.result, .invalidResponse)
        let encoded = String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self)
        XCTAssertFalse(encoded.contains("sensitive-token"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("sensitive-token"))
    }

    @MainActor
    func testCaptureRunsInActualWebKitIsolatedWorld() async throws {
        let view = WKWebView()
        view.loadHTMLString("<html><body>Transport test</body></html>", baseURL: nil)
        let deadline = Date().addingTimeInterval(10)
        while view.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let setup = """
        const location = {origin:'https://claude.ai'};
        const fetch = async (path) => ({status:200, ok:true, headers:{get:()=>null}, text:async()=>JSON.stringify(
            path === '/api/account' ? {email_address:'isolated@example.test'} :
            path === '/api/organizations' ? [{uuid:'org',name:'Personal'}] : {seven_day:{utilization:17}}
        )});
        """
        let result = try await view.callAsyncJavaScript(setup + ProviderScripts.capture(for: .claude), arguments: ["workspaceID": "org"], in: nil, contentWorld: .defaultClient)
        let data = try XCTUnwrap((result as? String)?.data(using: .utf8))
        XCTAssertEqual(try ProviderUsageParser.capture(data: data, provider: .claude).usage?.weekly.usedPercent, 17)
    }

    func testChatGPTTransportRequiresWorkspaceSelectionAndNeverExportsBearer() throws {
        let fixtures: [String: Any] = [
            "/api/auth/session": ["user": ["id": "user"], "accessToken": "unit-test-secret"],
            "/backend-api/accounts/check/v4-2023-04-27": ["accounts": ["one": ["account": ["account_id": "one", "name": "Personal"]], "two": ["account": ["account_id": "two", "name": "Work"]]]],
            "/backend-api/wham/usage": ["account_id": "two", "rate_limit": ["primary_window": ["used_percent": 12, "limit_window_seconds": 18000]]]
        ]
        let unselected = try runScript(provider: .chatGPT, workspace: nil, fixtures: fixtures)
        let discovery = try ProviderUsageParser.capture(data: unselected, provider: .chatGPT)
        XCTAssertEqual(discovery.workspaces.count, 2)
        XCTAssertNil(discovery.usage)
        let selected = try runScript(provider: .chatGPT, workspace: "two", fixtures: fixtures)
        XCTAssertFalse(String(decoding: selected, as: UTF8.self).contains("unit-test-secret"))
        XCTAssertEqual(try ProviderUsageParser.capture(data: selected, provider: .chatGPT).usage?.session.usedPercent, 12)
    }

    func testExpiredSessionAndBrowserChallengeDoNotProduceUsage() throws {
        let expired = try runScript(provider: .claude, workspace: nil, fixtures: ["/api/account": ["$status": 401]])
        XCTAssertThrowsError(try ProviderUsageParser.capture(data: expired, provider: .claude)) { XCTAssertEqual($0 as? ProviderSyncError, .signInRequired) }
        let challenged = try runScript(provider: .claude, workspace: nil, fixtures: ["/api/account": ["$status": 403, "$text": "<html>Just a moment: cf-chl</html>"]])
        XCTAssertThrowsError(try ProviderUsageParser.capture(data: challenged, provider: .claude)) { XCTAssertEqual($0 as? ProviderSyncError, .challenge) }
        let limited = try runScript(provider: .claude, workspace: nil, fixtures: ["/api/account": ["$status": 429]])
        XCTAssertThrowsError(try ProviderUsageParser.capture(data: limited, provider: .claude)) { XCTAssertEqual($0 as? ProviderSyncError, .rateLimited(300)) }
    }

    private func runScript(provider: AIProvider, workspace: String?, fixtures: [String: Any], afterUser: String? = nil) throws -> Data {
        let context = try XCTUnwrap(JSContext())
        var returned: String?
        var jsError: String?
        context.exceptionHandler = { _, exception in jsError = exception?.toString() }
        let callback: @convention(block) (String) -> Void = { returned = $0 }
        context.setObject(callback, forKeyedSubscript: "report" as NSString)
        func json(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self) }
        let setup = """
        var location = {origin:'https://\(provider.host)'};
        var fixtures = \(try json(fixtures)), afterUser = \(try json(afterUser.map { $0 as Any } ?? NSNull())), identityReads = 0;
        var AbortController = function() { this.signal = {}; this.abort = function(){}; };
        function setTimeout() { return 1; } function clearTimeout() {}
        async function fetch(path, options) {
            if (options.method !== 'GET' || options.credentials !== 'include' || options.redirect !== 'error') throw {code:'invalidResponse'};
            if (path.includes('wham') && options.headers['ChatGPT-Account-Id'] !== 'two') throw {code:'wrongAccount'};
            if (path === '/api/account') identityReads++;
            var value = path === '/api/account' && identityReads > 1 && afterUser ? {uuid:afterUser} : fixtures[path];
            var status = value && value.$status || (value === undefined ? 404 : 200);
            return {status, ok:status >= 200 && status < 300, headers:{get:()=>null}, text:async()=>value && value.$text || JSON.stringify(value || {})};
        }
        """
        context.evaluateScript(setup + "\n(async function(workspaceID) {\n" + ProviderScripts.capture(for: provider) + "\n})(\(try json(workspace.map { $0 as Any } ?? NSNull()))).then(report);")
        XCTAssertNil(jsError, jsError ?? "")
        return try XCTUnwrap(returned, jsError ?? "JavaScript did not finish").data(using: .utf8)!
    }
}
