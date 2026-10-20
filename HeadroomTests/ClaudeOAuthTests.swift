import XCTest
import CryptoKit
@testable import Headroom

final class ClaudeOAuthTests: XCTestCase {
    func testAuthorizationUsesPKCEAndOnlyProfileScope() throws {
        let first = try ClaudeAuthorizationAttempt(), second = try ClaudeAuthorizationAttempt()
        XCTAssertNotEqual(first.state, second.state)
        XCTAssertNotEqual(first.verifier, second.verifier)
        let items = try XCTUnwrap(URLComponents(url: first.url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ key: String) -> String? { items.first { $0.name == key }?.value }
        XCTAssertEqual(value("scope"), "user:profile")
        XCTAssertEqual(value("redirect_uri"), ClaudeAuthorizationAttempt.redirectURI)
        XCTAssertEqual(value("code_challenge_method"), "S256")
        let challenge = Data(SHA256.hash(data: Data(first.verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(value("code_challenge"), challenge)
        XCTAssertFalse(first.url.absoluteString.contains(first.verifier))
    }

    func testCallbackRejectsMissingWrongDuplicateStateAndExpiredAttempts() throws {
        let attempt = try ClaudeAuthorizationAttempt()
        XCTAssertEqual(try attempt.code(from: "test-code#\(attempt.state)"), "test-code")
        XCTAssertEqual(try attempt.code(from: "\(ClaudeAuthorizationAttempt.redirectURI)?code=test-code&state=\(attempt.state)"), "test-code")
        for input in ["test-code", "test-code#wrong", "https://unrelated.example/callback?code=test-code&state=\(attempt.state)",
                      "\(ClaudeAuthorizationAttempt.redirectURI)?code=test-code&state=\(attempt.state)&state=\(attempt.state)"] {
            XCTAssertThrowsError(try attempt.code(from: input))
        }
        XCTAssertThrowsError(try attempt.code(from: "test-code#\(attempt.state)", now: attempt.createdAt.addingTimeInterval(601)))
    }

    @MainActor
    func testProfileBindsUsageToVerifiedUserAndOrganization() throws {
        let capture = try ClaudeOAuthService.capture(profile: ["account": ["uuid": "user", "email": "user@example.test"], "organization": ["uuid": "workspace", "name": "Personal"]], usage: ["five_hour": ["utilization": 14], "seven_day": ["utilization": 51]])
        XCTAssertEqual(capture.identity.id, "user")
        XCTAssertEqual(capture.workspace?.id, "workspace")
        XCTAssertEqual(capture.usage?.weekly.usedPercent, 51)
        XCTAssertThrowsError(try ClaudeOAuthService.capture(profile: ["account": ["email": "user@example.test"]], usage: ["seven_day": ["utilization": 51]]))
    }

    @MainActor
    func testTokenRotationPreservesUnchangedRefreshAndRejectsMissingCredential() throws {
        let rotated = try ClaudeOAuthService.credential(["access_token": "access-two", "refresh_token": "refresh-two", "expires_in": 3600, "scope": "user:profile"], previousRefresh: "refresh-one")
        XCTAssertEqual(rotated.refreshToken, "refresh-two")
        let preserved = try ClaudeOAuthService.credential(["access_token": "access-two", "expires_in": 3600], previousRefresh: "refresh-one")
        XCTAssertEqual(preserved.refreshToken, "refresh-one")
        XCTAssertThrowsError(try ClaudeOAuthService.credential(["access_token": "access"], previousRefresh: nil))
        XCTAssertThrowsError(try ClaudeOAuthService.credential(["access_token": "access", "refresh_token": "refresh", "scope": "user:inference"], previousRefresh: nil))
    }

    @MainActor
    func testKeychainAccountsStaySeparateAndRemovalDoesNotDeleteAnotherCredential() throws {
        let vault = ClaudeCredentialVault(), first = UUID(), second = UUID()
        defer { vault.remove(first); vault.remove(second) }
        let one = ClaudeCredential(accessToken: "test-access-one", refreshToken: "test-refresh-one", expiresAt: .now.addingTimeInterval(3600))
        let two = ClaudeCredential(accessToken: "test-access-two", refreshToken: "test-refresh-two", expiresAt: .now.addingTimeInterval(3600))
        try vault.save(one, for: first); try vault.save(two, for: second)
        XCTAssertEqual(try vault.load(first), one)
        XCTAssertEqual(try vault.load(second), two)
        vault.remove(first)
        XCTAssertNil(try vault.load(first))
        XCTAssertEqual(try vault.load(second), two)
    }

    @MainActor
    func testOAuthRefreshReadsCorrectEndpointsAndPersistsRotation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeOAuthFixtureProtocol.self]
        let service = ClaudeOAuthService(session: URLSession(configuration: configuration))
        let id = UUID()
        defer { service.vault.remove(id) }
        try service.vault.save(.init(accessToken: "expired", refreshToken: "refresh-one", expiresAt: .distantPast), for: id)
        let capture = try await service.read(accountID: id)
        XCTAssertEqual(capture.identity.id, "fixture-user")
        XCTAssertEqual(capture.usage?.session.usedPercent, 16)
        XCTAssertEqual(try service.vault.load(id)?.refreshToken, "refresh-two")
    }

    @MainActor
    func testConnectingPersistsOnlyMetadataAndDeleteRemovesCredential() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "HeadroomOAuth.\(UUID())"))
        let store = UsageStore(defaults: defaults)
        let id = UUID()
        defer { store.delete(id) }
        let capture = try ClaudeOAuthService.capture(profile: ["account": ["uuid": "user"], "organization": ["uuid": "org"]], usage: ["seven_day": ["utilization": 8]])
        let credential = ClaudeCredential(accessToken: "do-not-persist-access", refreshToken: "do-not-persist-refresh", expiresAt: .now.addingTimeInterval(3600))
        try store.connect(profileID: id, provider: .claude, alias: "Test", capture: capture, claudeCredential: credential)
        XCTAssertEqual(store.account(id)?.connectionMethod, .claudeOAuth)
        let saved = String(decoding: try XCTUnwrap(defaults.data(forKey: "headroom.accounts.v1")), as: UTF8.self)
        XCTAssertFalse(saved.contains("do-not-persist"))
        store.delete(id)
        XCTAssertNil(try store.claudeOAuth.vault.load(id))
    }
}

private final class ClaudeOAuthFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path
        let body: [String: Any]
        switch path {
        case "/v1/oauth/token":
            guard request.httpMethod == "POST" else { fail(); return }
            body = ["access_token": "access-two", "refresh_token": "refresh-two", "expires_in": 3600]
        case "/api/oauth/profile", "/api/oauth/usage":
            guard request.httpMethod == "GET", request.value(forHTTPHeaderField: "Authorization") == "Bearer access-two",
                  request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20" else { fail(); return }
            body = path == "/api/oauth/profile" ? ["account": ["uuid": "fixture-user"], "organization": ["uuid": "fixture-org"]] : ["five_hour": ["utilization": 16]]
        default: fail(); return
        }
        let data = try! JSONSerialization.data(withJSONObject: body)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    private func fail() { client?.urlProtocol(self, didFailWithError: URLError(.badURL)) }
    override func stopLoading() {}
}
