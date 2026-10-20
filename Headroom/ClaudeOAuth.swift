import Foundation
import CryptoKit
import Security

// Protocol details checked against f-is-h/Usage4Claude's ClaudeOAuth adapter.
// This is a third-party integration using Claude Code's public PKCE client;
// that fact is also shown before the user opens the authorization page.
struct ClaudeAuthorizationAttempt {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    let verifier: String
    let state: String
    let createdAt: Date

    init() throws {
        verifier = try Self.random(64)
        state = try Self.random(32)
        createdAt = .now
    }

    var url: URL {
        var components = URLComponents(string: "https://claude.ai/oauth/authorize")!
        components.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: Self.clientID),
            .init(name: "redirect_uri", value: Self.redirectURI), .init(name: "scope", value: "user:profile"),
            .init(name: "code_challenge", value: Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "state", value: state)
        ]
        return components.url!
    }

    func code(from pasted: String, now: Date = .now) throws -> String {
        guard now.timeIntervalSince(createdAt) >= 0, now.timeIntervalSince(createdAt) < 600 else { throw ClaudeAuthorizationError.expired }
        let input = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.count < 8192 else { throw ClaudeAuthorizationError.invalidCode }
        var code: String?
        var returnedState: String?
        if let url = URLComponents(string: input), url.scheme != nil {
            guard url.scheme == "https", url.host == "console.anthropic.com", url.path == "/oauth/code/callback",
                  url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { throw ClaudeAuthorizationError.invalidCode }
            let items = url.queryItems ?? []
            guard items.filter({ $0.name == "code" }).count == 1, items.filter({ $0.name == "state" }).count == 1,
                  !items.contains(where: { $0.name == "error" }) else { throw ClaudeAuthorizationError.invalidCode }
            code = items.first { $0.name == "code" }?.value
            returnedState = items.first { $0.name == "state" }?.value
        } else {
            let parts = input.split(separator: "#", omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw ClaudeAuthorizationError.invalidCode }
            code = String(parts[0]); returnedState = String(parts[1])
        }
        guard returnedState == state, let code, !code.isEmpty, code.count < 4096,
              !code.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw ClaudeAuthorizationError.invalidCode }
        return code
    }

    private static func random(_ count: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw ClaudeAuthorizationError.secureStorage }
        return base64URL(Data(bytes))
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

enum ClaudeAuthorizationError: LocalizedError {
    case invalidCode, expired, secureStorage, browserUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidCode: return "Paste the complete code from this browser sign-in, including the part after #. If it belongs to another sign-in, start again."
        case .expired: return "This sign-in attempt expired. Open the browser again to get a new code."
        case .secureStorage: return "The iPhone could not securely save this connection. Unlock your phone and try again."
        case .browserUnavailable: return "The browser could not open. Try opening the sign-in again."
        }
    }
}

struct ClaudeCredential: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

struct ClaudeCredentialVault {
    private let service = "com.example.headroom.claude-oauth"
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }
    func load(_ id: UUID) throws -> ClaudeCredential? {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let value = try? JSONDecoder().decode(ClaudeCredential.self, from: data) else { throw ClaudeAuthorizationError.secureStorage }
        return value
    }
    func save(_ value: ClaudeCredential, for id: UUID) throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(value), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query(id).merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw ClaudeAuthorizationError.secureStorage }
        } else if status != errSecSuccess { throw ClaudeAuthorizationError.secureStorage }
    }
    func remove(_ id: UUID) { SecItemDelete(query(id) as CFDictionary) }
}

private final class ClaudeNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class ClaudeOAuthService {
    let vault = ClaudeCredentialVault()
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 25
        self.session = URLSession(configuration: configuration, delegate: ClaudeNoRedirects(), delegateQueue: nil)
    }

    func exchange(attempt: ClaudeAuthorizationAttempt, pastedCode: String) async throws -> ClaudeCredential {
        let code = try attempt.code(from: pastedCode)
        let raw = try await tokenRequest([
            "grant_type": "authorization_code", "code": code, "state": attempt.state,
            "redirect_uri": ClaudeAuthorizationAttempt.redirectURI,
            "client_id": ClaudeAuthorizationAttempt.clientID, "code_verifier": attempt.verifier
        ])
        return try Self.credential(raw, previousRefresh: nil)
    }

    func read(accountID: UUID) async throws -> ProviderCapture {
        guard var credential = try vault.load(accountID) else { throw ProviderSyncError.signInRequired }
        let refreshed = credential.expiresAt.timeIntervalSinceNow < 60
        if refreshed { credential = try await refresh(credential, accountID: accountID) }
        do { return try await read(credential: credential) }
        catch ProviderSyncError.signInRequired {
            guard !refreshed else { throw ProviderSyncError.signInRequired }
            // Refresh a rejected access token once, retaining any rotated refresh
            // credential for this account only before fetching usage again.
            credential = try await refresh(credential, accountID: accountID)
            return try await read(credential: credential)
        }
    }

    private func refresh(_ old: ClaudeCredential, accountID: UUID) async throws -> ClaudeCredential {
        let raw = try await tokenRequest(["grant_type": "refresh_token", "refresh_token": old.refreshToken, "client_id": ClaudeAuthorizationAttempt.clientID])
        let updated = try Self.credential(raw, previousRefresh: old.refreshToken)
        // A deletion/reconnection during the request must not resurrect credentials.
        guard try vault.load(accountID) == old else { throw ProviderSyncError.cancelled }
        try vault.save(updated, for: accountID)
        try Task.checkCancellation()
        return updated
    }

    func read(credential: ClaudeCredential) async throws -> ProviderCapture {
        let profile = try await request(url: "https://api.anthropic.com/api/oauth/profile", token: credential.accessToken)
        let usage = try await request(url: "https://api.anthropic.com/api/oauth/usage", token: credential.accessToken)
        return try Self.capture(profile: profile, usage: usage)
    }

    static func capture(profile: [String: Any], usage: [String: Any]) throws -> ProviderCapture {
        guard let account = profile["account"] as? [String: Any], let organization = profile["organization"] as? [String: Any] else { throw ProviderSyncError.invalidResponse }
        func text(_ value: Any?) -> String? {
            guard let string = value as? String, !string.isEmpty, string.count <= 256 else { return nil }
            return string
        }
        let email = text(account["email"]) ?? text(account["email_address"])
        guard let userID = text(account["uuid"]) ?? text(account["id"]) ?? email.map({ "claude-email:\($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())" }),
              userID.count <= 256, let orgID = text(organization["uuid"]) ?? text(organization["id"]) else { throw ProviderSyncError.invalidResponse }
        let workspace = ProviderWorkspace(id: orgID, name: text(organization["name"]) ?? "Claude workspace", plan: text(organization["rate_limit_tier"]) ?? text(organization["organization_type"]))
        return .init(identity: .init(id: userID, email: email), workspaces: [workspace], workspace: workspace,
                     usage: try ProviderUsageParser.claude(usage, observedAt: .now))
    }

    static func credential(_ raw: [String: Any], previousRefresh: String?) throws -> ClaudeCredential {
        guard let access = raw["access_token"] as? String, !access.isEmpty, access.count < 32768,
              let refresh = (raw["refresh_token"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) ?? previousRefresh,
              !refresh.isEmpty, refresh.count < 32768 else { throw ProviderSyncError.invalidResponse }
        if let scope = raw["scope"] as? String, !scope.split(separator: " ").contains("user:profile") { throw ProviderSyncError.forbidden }
        let expiry = raw["expires_in"] as? Double ?? 1800
        guard expiry.isFinite, expiry > 0, expiry <= 2_592_000 else { throw ProviderSyncError.invalidResponse }
        return .init(accessToken: access, refreshToken: refresh, expiresAt: .now.addingTimeInterval(expiry))
    }

    private func tokenRequest(_ body: [String: String]) async throws -> [String: Any] {
        try await request(url: "https://console.anthropic.com/v1/oauth/token", body: body)
    }

    private func request(url: String, token: String? = nil, body: [String: String]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, data.count < 2_000_000 else { throw ProviderSyncError.invalidResponse }
        if response.statusCode == 429 {
            throw ProviderSyncError.rateLimited(TimeInterval(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 300)
        }
        if response.statusCode == 401 { throw ProviderSyncError.signInRequired }
        if response.statusCode == 403 { throw ProviderSyncError.forbidden }
        let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if response.statusCode == 400,
           raw?["error"] as? String == "invalid_grant" || (raw?["error"] as? [String: Any])?["type"] as? String == "invalid_grant" { throw ProviderSyncError.signInRequired }
        guard (200...299).contains(response.statusCode) else { throw ProviderSyncError.server(response.statusCode) }
        guard let raw else { throw ProviderSyncError.invalidResponse }
        return raw
    }
}
