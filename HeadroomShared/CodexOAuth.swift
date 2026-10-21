import Foundation
import CryptoKit
import Security

struct CodexAuthorizationAttempt {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let redirectURI = "http://localhost:1455/auth/callback"
    let id = UUID()
    let verifier: String
    let state: String
    let createdAt = Date()

    init() throws {
        func random(_ count: Int) throws -> String {
            var bytes = [UInt8](repeating: 0, count: count)
            guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw ClaudeAuthorizationError.secureStorage }
            return Self.base64URL(Data(bytes))
        }
        verifier = try random(64); state = try random(32)
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    var url: URL {
        var url = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
        url.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: Self.clientID),
            .init(name: "redirect_uri", value: Self.redirectURI), .init(name: "scope", value: "openid profile email offline_access"),
            .init(name: "code_challenge", value: Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "state", value: state),
            .init(name: "id_token_add_organizations", value: "true"), .init(name: "codex_cli_simplified_flow", value: "true"),
            .init(name: "originator", value: "headroom_ios")
        ]
        return url.url!
    }
    func code(from input: String, now: Date = .now) throws -> String {
        guard now.timeIntervalSince(createdAt) >= 0, now.timeIntervalSince(createdAt) < 600 else { throw CodexAuthorizationError.expired }
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.count < 8192, let url = URLComponents(string: input), url.scheme == "http", url.host == "localhost", url.port == 1455,
              url.path == "/auth/callback", url.user == nil, url.password == nil, url.fragment == nil else { throw CodexAuthorizationError.invalidCallback }
        let items = url.queryItems ?? []
        guard !items.contains(where: { $0.name == "error" }), items.filter({ $0.name == "code" }).count == 1,
              items.filter({ $0.name == "state" }).count == 1, items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty, code.count < 4096,
              !code.contains(where: { $0.isWhitespace }) else { throw CodexAuthorizationError.invalidCallback }
        return code
    }
}

struct CodexDeviceAttempt: Identifiable {
    let id = UUID()
    let deviceAuthID: String
    let userCode: String
    let interval: TimeInterval
    let createdAt = Date()
    var expiresAt: Date { createdAt.addingTimeInterval(900) }
    static let verificationURL = URL(string: "https://auth.openai.com/codex/device")!

    static func parse(_ raw: [String: Any]) throws -> Self {
        guard let device = CodexOAuthService.text(raw["device_auth_id"]),
              let code = CodexOAuthService.text(raw["user_code"] ?? raw["usercode"]), code.count <= 64 else { throw ProviderSyncError.invalidResponse }
        let interval = (raw["interval"] as? String).flatMap(Double.init) ?? raw["interval"] as? Double ?? 5
        guard interval.isFinite, interval >= 0, interval <= 300 else { throw ProviderSyncError.invalidResponse }
        return .init(deviceAuthID: device, userCode: code, interval: max(5, interval))
    }
}

enum CodexAuthorizationError: LocalizedError {
    case expired, invalidCallback, deviceUnavailable
    var errorDescription: String? {
        switch self {
        case .expired: return "This sign-in code expired. Start a new sign-in."
        case .invalidCallback: return "Paste the complete localhost return link from this browser sign-in. Its code and state must belong to this attempt."
        case .deviceUnavailable: return "Device-code sign-in is unavailable. Enable it in ChatGPT Settings → Security, or use the browser return-link option below."
        }
    }
}

struct CodexCredential: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var userID: String
    var accountID: String
    var email: String?
    var plan: String?
}

struct CodexCredentialVault {
    private let service = "com.example.headroom.codex-oauth"
    func load(_ id: UUID) throws -> CodexCredential? {
        guard let data = try SharedCredentialStore.load(service: service, id: id) else { return nil }
        guard let value = try? JSONDecoder().decode(CodexCredential.self, from: data) else { throw ClaudeAuthorizationError.secureStorage }
        return value
    }
    func save(_ value: CodexCredential, for id: UUID) throws {
        try SharedCredentialStore.save(JSONEncoder().encode(value), service: service, id: id)
    }
    func remove(_ id: UUID) { SharedCredentialStore.remove(service: service, id: id) }
}

private final class CodexNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class CodexOAuthService {
    let vault = CodexCredentialVault()
    private let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false; configuration.timeoutIntervalForRequest = 25
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration, delegate: CodexNoRedirects(), delegateQueue: nil)
    }

    func startDevice() async throws -> CodexDeviceAttempt {
        let (raw, response) = try await send(url: "https://auth.openai.com/api/accounts/deviceauth/usercode", body: ["client_id": CodexAuthorizationAttempt.clientID], allowDevicePending: true)
        guard (200...299).contains(response.statusCode) else { throw CodexAuthorizationError.deviceUnavailable }
        return try CodexDeviceAttempt.parse(raw)
    }

    /// One poll only. The view schedules calls while foregrounded, at the
    /// provider's interval, and enforces this attempt's absolute expiry.
    func pollDevice(_ attempt: CodexDeviceAttempt, now: Date = .now) async throws -> CodexCredential? {
        guard now < attempt.expiresAt else { throw CodexAuthorizationError.expired }
        let (raw, response) = try await send(url: "https://auth.openai.com/api/accounts/deviceauth/token", body: ["device_auth_id": attempt.deviceAuthID, "user_code": attempt.userCode], allowDevicePending: true)
        if response.statusCode == 403 || response.statusCode == 404 { return nil }
        guard let code = Self.text(raw["authorization_code"]), let verifier = Self.text(raw["code_verifier"]),
              let challenge = Self.text(raw["code_challenge"]) else { throw ProviderSyncError.invalidResponse }
        let expected = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        guard challenge == expected else { throw ProviderSyncError.invalidResponse }
        return try await exchange(code: code, verifier: verifier, redirect: "https://auth.openai.com/deviceauth/callback")
    }

    func exchange(attempt: CodexAuthorizationAttempt, pastedLink: String) async throws -> CodexCredential {
        try await exchange(code: attempt.code(from: pastedLink), verifier: attempt.verifier, redirect: CodexAuthorizationAttempt.redirectURI)
    }
    private func exchange(code: String, verifier: String, redirect: String) async throws -> CodexCredential {
        let (raw, _) = try await send(url: "https://auth.openai.com/oauth/token", body: ["grant_type": "authorization_code", "code": code, "client_id": CodexAuthorizationAttempt.clientID, "code_verifier": verifier, "redirect_uri": redirect], form: true)
        return try Self.credential(raw, previous: nil)
    }

    func read(accountID: UUID) async throws -> ProviderCapture {
        guard var credential = try vault.load(accountID) else { throw ProviderSyncError.signInRequired }
        let refreshed = credential.expiresAt.timeIntervalSinceNow < 60
        if refreshed { credential = try await refresh(credential, accountID: accountID) }
        do { return try await read(credential: credential) }
        catch ProviderSyncError.signInRequired {
            guard !refreshed else { throw ProviderSyncError.signInRequired }
            credential = try await refresh(credential, accountID: accountID)
            return try await read(credential: credential)
        }
    }
    private func refresh(_ old: CodexCredential, accountID: UUID) async throws -> CodexCredential {
        let (raw, _) = try await send(url: "https://auth.openai.com/oauth/token", body: ["client_id": CodexAuthorizationAttempt.clientID, "grant_type": "refresh_token", "refresh_token": old.refreshToken])
        let updated = try Self.credential(raw, previous: old)
        guard try vault.load(accountID) == old else { throw ProviderSyncError.cancelled }
        try vault.save(updated, for: accountID)
        try Task.checkCancellation()
        return updated
    }

    func read(credential: CodexCredential) async throws -> ProviderCapture {
        let (usage, _) = try await send(url: "https://chatgpt.com/backend-api/wham/usage", credential: credential)
        if let id = Self.text(usage["account_id"]), id != credential.accountID { throw ProviderSyncError.wrongAccount }
        let workspace = ProviderWorkspace(id: credential.accountID, name: "ChatGPT workspace", plan: Self.text(usage["plan_type"]) ?? credential.plan)
        return .init(identity: .init(id: credential.userID, email: credential.email), workspaces: [workspace], workspace: workspace,
                     usage: try ProviderUsageParser.codex(usage, observedAt: .now))
    }

    static func credential(_ raw: [String: Any], previous: CodexCredential?) throws -> CodexCredential {
        guard let access = raw["access_token"] as? String, !access.isEmpty, access.count < 32768,
              let refresh = (raw["refresh_token"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) ?? previous?.refreshToken,
              !refresh.isEmpty, refresh.count < 32768 else { throw ProviderSyncError.invalidResponse }
        let claims = payload(access) ?? [:], identity = (raw["id_token"] as? String).flatMap(payload) ?? [:]
        let auth = claims["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        let identityAuth = identity["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        guard let account = text(auth["chatgpt_account_id"]) ?? text(identityAuth["chatgpt_account_id"]) ?? previous?.accountID,
              let user = text(auth["chatgpt_user_id"]) ?? text(identityAuth["chatgpt_user_id"]) ?? text(claims["sub"]) ?? text(identity["sub"]) ?? previous?.userID else { throw ProviderSyncError.invalidResponse }
        if let previous, previous.accountID != account || previous.userID != user { throw ProviderSyncError.wrongAccount }
        let seconds = raw["expires_in"] as? Double ?? 1800
        guard seconds.isFinite, seconds > 0, seconds <= 2_592_000 else { throw ProviderSyncError.invalidResponse }
        var expiry = Date().addingTimeInterval(seconds)
        if let exp = claims["exp"] as? Double, exp.isFinite, exp > 0, exp < 32_503_680_000 { expiry = min(expiry, Date(timeIntervalSince1970: exp)) }
        let profile = claims["https://api.openai.com/profile"] as? [String: Any] ?? [:]
        return .init(accessToken: access, refreshToken: refresh, expiresAt: expiry, userID: user, accountID: account,
                     email: text(identity["email"]) ?? text(profile["email"]) ?? previous?.email,
                     plan: text(auth["chatgpt_plan_type"]) ?? text(identityAuth["chatgpt_plan_type"]) ?? previous?.plan)
    }
    private static func payload(_ token: String) -> [String: Any]? {
        guard token.count < 32768 else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    nonisolated static func text(_ value: Any?) -> String? {
        guard let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, string.count <= 256 else { return nil }
        return string
    }

    private func send(url: String, body: [String: String]? = nil, form: Bool = false, credential: CodexCredential? = nil, allowDevicePending: Bool = false) async throws -> ([String: Any], HTTPURLResponse) {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Headroom/0.4 (iOS)", forHTTPHeaderField: "User-Agent")
        if let credential {
            request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        if let body {
            request.httpMethod = "POST"
            if form {
                func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))! }
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = body.sorted { $0.key < $1.key }.map { "\(encode($0.key))=\(encode($0.value))" }.joined(separator: "&").data(using: .utf8)
            } else {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, data.count < 2_000_000 else { throw ProviderSyncError.invalidResponse }
        if response.statusCode == 429 { throw ProviderSyncError.rateLimited(TimeInterval(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 300) }
        let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if allowDevicePending, response.statusCode == 403 || response.statusCode == 404 {
            if raw == nil, let html = String(data: data.prefix(4096), encoding: .utf8), html.localizedCaseInsensitiveContains("<html") { throw ProviderSyncError.challenge }
            return (raw ?? [:], response)
        }
        if response.statusCode == 401 { throw ProviderSyncError.signInRequired }
        if response.statusCode == 403 {
            if raw == nil { throw ProviderSyncError.challenge }
            throw ProviderSyncError.forbidden
        }
        let error = raw?["error"] as? String ?? (raw?["error"] as? [String: Any])?["code"] as? String
        if [400, 401].contains(response.statusCode), let error, ["invalid_grant", "refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated"].contains(error) { throw ProviderSyncError.signInRequired }
        guard (200...299).contains(response.statusCode) else { throw ProviderSyncError.server(response.statusCode) }
        guard let raw else { throw ProviderSyncError.invalidResponse }
        return (raw, response)
    }
}
