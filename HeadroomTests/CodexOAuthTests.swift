import XCTest
import CryptoKit
@testable import Headroom

final class CodexOAuthTests: XCTestCase {
    private func token(user: String = "user", account: String = "workspace") throws -> String {
        let payload: [String: Any] = ["sub": user, "https://api.openai.com/auth": ["chatgpt_user_id": user, "chatgpt_account_id": account, "chatgpt_plan_type": "plus"], "https://api.openai.com/profile": ["email": "user@example.test"]]
        let encoded = try JSONSerialization.data(withJSONObject: payload).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "fixture.\(encoded).signature"
    }
    @MainActor
    private func service() -> CodexOAuthService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexOAuthFixtureProtocol.self]
        return CodexOAuthService(session: URLSession(configuration: configuration))
    }

    func testBrowserAttemptUsesPKCEAndRejectsUnrelatedReturnLinks() throws {
        let attempt = try CodexAuthorizationAttempt()
        let items = try XCTUnwrap(URLComponents(url: attempt.url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "scope" }?.value, "openid profile email offline_access")
        XCTAssertEqual(items.first { $0.name == "originator" }?.value, "headroom_ios")
        XCTAssertFalse(attempt.url.absoluteString.contains(attempt.verifier))
        let valid = "http://localhost:1455/auth/callback?code=fixture-code&state=\(attempt.state)"
        XCTAssertEqual(try attempt.code(from: valid), "fixture-code")
        for input in ["fixture-code", valid.replacingOccurrences(of: "localhost", with: "unrelated.example"), valid + "&state=duplicate", valid.replacingOccurrences(of: "1455", with: "9999"), valid.replacingOccurrences(of: attempt.state, with: "wrong")] {
            XCTAssertThrowsError(try attempt.code(from: input))
        }
        XCTAssertThrowsError(try attempt.code(from: valid, now: attempt.createdAt.addingTimeInterval(601)))
    }

    func testDeviceAttemptHonorsServerIntervalAndRejectsMalformedPayloads() throws {
        XCTAssertEqual(try CodexDeviceAttempt.parse(["device_auth_id": "device", "user_code": "ABCD-EFGH", "interval": "7"]).interval, 7)
        XCTAssertEqual(try CodexDeviceAttempt.parse(["device_auth_id": "device", "usercode": "ABCD", "interval": 0]).interval, 5)
        XCTAssertThrowsError(try CodexDeviceAttempt.parse(["user_code": "ABCD"]))
        XCTAssertThrowsError(try CodexDeviceAttempt.parse(["device_auth_id": "device", "user_code": "ABCD", "interval": 1e200]))
    }

    @MainActor
    func testTokenMetadataBindsAccountAndRejectsRefreshIdentityChanges() throws {
        let credential = try CodexOAuthService.credential(["access_token": token(), "refresh_token": "refresh-one", "expires_in": 3600], previous: nil)
        XCTAssertEqual(credential.userID, "user")
        XCTAssertEqual(credential.accountID, "workspace")
        XCTAssertEqual(credential.email, "user@example.test")
        let refreshed = try CodexOAuthService.credential(["access_token": token(), "expires_in": 3600], previous: credential)
        XCTAssertEqual(refreshed.refreshToken, "refresh-one")
        XCTAssertThrowsError(try CodexOAuthService.credential(["access_token": token(user: "other"), "refresh_token": "two"], previous: credential)) { XCTAssertEqual($0 as? ProviderSyncError, .wrongAccount) }
        XCTAssertThrowsError(try CodexOAuthService.credential(["access_token": "unbound", "refresh_token": "one"], previous: nil))
    }

    @MainActor
    func testDeviceApprovalPendingExchangeAndUsageUseCorrectEndpoints() async throws {
        let access = try token(), verifier = "test-verifier"
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var polls = 0
        CodexOAuthFixtureProtocol.handler = { request in
            switch request.url?.path {
            case "/api/accounts/deviceauth/usercode":
                guard request.httpMethod == "POST", request.value(forHTTPHeaderField: "Authorization") == nil else { throw URLError(.badURL) }
                return (200, ["device_auth_id": "fixture-device", "user_code": "ABCD-EFGH", "interval": "5"], [:])
            case "/api/accounts/deviceauth/token":
                polls += 1
                return polls == 1 ? (403, ["error": "authorization_pending"], [:]) : (200, ["authorization_code": "fixture-code", "code_verifier": verifier, "code_challenge": challenge], [:])
            case "/oauth/token":
                guard request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded" else { throw URLError(.badURL) }
                let body = CodexOAuthFixtureProtocol.body(request)
                guard body.contains("redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback"), body.contains("code_verifier=test-verifier") else { throw URLError(.badURL) }
                return (200, ["access_token": access, "refresh_token": "refresh", "expires_in": 3600], [:])
            case "/backend-api/wham/usage":
                guard request.httpMethod == "GET", request.value(forHTTPHeaderField: "Authorization") == "Bearer \(access)", request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "workspace" else { throw URLError(.badURL) }
                return (200, ["account_id": "workspace", "plan_type": "plus", "rate_limit": ["primary_window": ["used_percent": 8, "limit_window_seconds": 18000], "secondary_window": ["used_percent": 31, "limit_window_seconds": 604800]]], [:])
            default: throw URLError(.badURL)
            }
        }
        defer { CodexOAuthFixtureProtocol.handler = nil }
        let service = service(), attempt = try await service.startDevice()
        let pending = try await service.pollDevice(attempt)
        XCTAssertNil(pending)
        let approved = try await service.pollDevice(attempt)
        let credential = try XCTUnwrap(approved)
        let capture = try await service.read(credential: credential)
        XCTAssertEqual(capture.identity.id, "user")
        XCTAssertEqual(capture.usage?.weekly.usedPercent, 31)
        XCTAssertEqual(polls, 2)
        do { _ = try await service.pollDevice(attempt, now: attempt.expiresAt.addingTimeInterval(1)); XCTFail("Expired code polled") }
        catch { XCTAssertTrue(error is CodexAuthorizationError) }
    }

    @MainActor
    func testRateLimitsAreNotTreatedAsPendingAndDisabledDeviceLoginIsActionable() async throws {
        CodexOAuthFixtureProtocol.handler = { _ in (429, [:], ["Retry-After": "120"]) }
        defer { CodexOAuthFixtureProtocol.handler = nil }
        do { _ = try await service().startDevice(); XCTFail("Expected rate limit") }
        catch { XCTAssertEqual(error as? ProviderSyncError, .rateLimited(120)) }
        CodexOAuthFixtureProtocol.handler = { _ in (404, [:], [:]) }
        do { _ = try await service().startDevice(); XCTFail("Expected unavailable") }
        catch { XCTAssertTrue(error is CodexAuthorizationError) }
    }

    @MainActor
    func testRefreshRotatesOnlyOwnKeychainAndUsesExpectedWorkspace() async throws {
        let access = try token(), service = service(), first = UUID(), second = UUID()
        let old = CodexCredential(accessToken: "expired", refreshToken: "old-refresh", expiresAt: .distantPast, userID: "user", accountID: "workspace")
        let other = CodexCredential(accessToken: "other-access", refreshToken: "other-refresh", expiresAt: .now.addingTimeInterval(3600), userID: "other", accountID: "other-workspace")
        try service.vault.save(old, for: first); try service.vault.save(other, for: second)
        defer { service.vault.remove(first); service.vault.remove(second); CodexOAuthFixtureProtocol.handler = nil }
        CodexOAuthFixtureProtocol.handler = { request in
            if request.url?.path == "/oauth/token" {
                guard request.value(forHTTPHeaderField: "Content-Type") == "application/json" else { throw URLError(.badURL) }
                return (200, ["access_token": access, "refresh_token": "new-refresh", "expires_in": 3600], [:])
            }
            guard request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "workspace" else { throw URLError(.badURL) }
            return (200, ["rate_limit": ["secondary_window": ["used_percent": 15, "limit_window_seconds": 604800]]], [:])
        }
        let capture = try await service.read(accountID: first)
        XCTAssertEqual(capture.usage?.weekly.usedPercent, 15)
        XCTAssertEqual(try service.vault.load(first)?.refreshToken, "new-refresh")
        XCTAssertEqual(try service.vault.load(second), other)
    }

    @MainActor
    func testRemovedAccountCannotBeResurrectedByFinishingRefresh() async throws {
        let service = service(), id = UUID(), access = try token()
        try service.vault.save(.init(accessToken: "expired", refreshToken: "refresh", expiresAt: .distantPast, userID: "user", accountID: "workspace"), for: id)
        CodexOAuthFixtureProtocol.handler = { _ in
            CodexCredentialVault().remove(id)
            return (200, ["access_token": access, "refresh_token": "rotated", "expires_in": 3600], [:])
        }
        defer { CodexOAuthFixtureProtocol.handler = nil; service.vault.remove(id) }
        do { _ = try await service.read(accountID: id); XCTFail("Removed account read") }
        catch { XCTAssertEqual(error as? ProviderSyncError, .cancelled) }
        XCTAssertNil(try service.vault.load(id))
    }

    @MainActor
    func testConnectStoresMetadataOnlyAndDeleteRemovesOwnCredential() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "HeadroomCodexOAuth.\(UUID())")), store = UsageStore(defaults: defaults), id = UUID()
        let credential = try CodexOAuthService.credential(["access_token": token(), "refresh_token": "secret-refresh"], previous: nil)
        let usage = try ProviderUsageParser.codex(["rate_limit": ["primary_window": ["used_percent": 6, "limit_window_seconds": 18000]]], observedAt: .now)
        let workspace = ProviderWorkspace(id: "workspace", name: "Personal")
        let capture = ProviderCapture(identity: .init(id: "user", email: "user@example.test"), workspaces: [workspace], workspace: workspace, usage: usage)
        try store.connect(profileID: id, provider: .chatGPT, alias: "Personal", capture: capture, codexCredential: credential)
        defer { store.delete(id) }
        XCTAssertEqual(store.account(id)?.connectionMethod, .codexOAuth)
        let saved = String(decoding: try XCTUnwrap(defaults.data(forKey: "headroom.accounts.v1")), as: UTF8.self)
        XCTAssertFalse(saved.contains("secret-refresh")); XCTAssertFalse(saved.contains(credential.accessToken))
        XCTAssertThrowsError(try store.connect(profileID: UUID(), provider: .claude, alias: "Wrong", capture: capture, codexCredential: credential))
        store.delete(id)
        XCTAssertNil(try store.codexOAuth.vault.load(id))
    }
}

private final class CodexOAuthFixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: Any], [String: String]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badURL) }
            let (status, body, headers) = try handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open(); defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 8192)
        let count = stream.read(&buffer, maxLength: buffer.count)
        return count > 0 ? String(decoding: buffer.prefix(count), as: UTF8.self) : ""
    }
}
