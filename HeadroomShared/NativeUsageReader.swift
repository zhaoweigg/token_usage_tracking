import Foundation

private struct NativeRetryPolicy: Codable {
    var until: Date
    var failures: Int
    var generation: UUID?
}

@MainActor
final class NativeUsageReader {
    let claude: ClaudeOAuthService
    let codex: CodexOAuthService
    var usesTestTransport: Bool { readOverride != nil }
    private let readOverride: ((UsageAccount) async throws -> ProviderCapture)?

    init(claude: ClaudeOAuthService? = nil, codex: CodexOAuthService? = nil,
         readOverride: ((UsageAccount) async throws -> ProviderCapture)? = nil) {
        self.claude = claude ?? ClaudeOAuthService(); self.codex = codex ?? CodexOAuthService()
        self.readOverride = readOverride
    }

    func read(_ account: UsageAccount, publish: Bool = false) async throws -> ProviderCapture {
        try await SharedFileLock.withAccount(account.id) {
            guard let current = WidgetSnapshotStore.load().accounts.first(where: { $0.hasSameConnection(as: account) }) else { throw ProviderSyncError.cancelled }
            if let date = current.lastSyncedAt, Date().timeIntervalSince(date) < 60, let cached = current.cachedCapture { return cached }
            let policy = self.loadPolicy(account.id, generation: account.connectionGeneration)
            if let until = policy?.until, until > Date() { throw ProviderSyncError.rateLimited(until.timeIntervalSinceNow) }
            self.savePolicy(account.id, generation: account.connectionGeneration, until: Date().addingTimeInterval(60), failures: policy?.failures ?? 0)
            do {
                let capture: ProviderCapture
                if let readOverride = self.readOverride { capture = try await readOverride(current) }
                else if account.connectionMethod == .claudeOAuth { capture = try await self.claude.read(accountID: account.id) }
                else if account.connectionMethod == .codexOAuth { capture = try await self.codex.read(accountID: account.id) }
                else { throw ProviderSyncError.unavailable }
                try Task.checkCancellation()
                guard capture.identity.id == account.providerUserID, capture.workspace?.id == account.workspaceID, capture.usage != nil else { throw ProviderSyncError.wrongAccount }
                if publish, try !WidgetSnapshotStore.update(account.id, expected: account, capture: capture) { throw ProviderSyncError.cancelled }
                self.savePolicy(account.id, generation: account.connectionGeneration, until: Date().addingTimeInterval(60), failures: 0)
                return capture
            } catch {
                let failures = min(10, (policy?.failures ?? 0) + 1)
                let seconds: TimeInterval
                if case let ProviderSyncError.rateLimited(delay) = error { seconds = delay.isFinite ? min(3600, max(60, delay)) : 300 }
                else { seconds = min(1800, 60 * pow(2, Double(min(5, failures - 1)))) }
                self.savePolicy(account.id, generation: account.connectionGeneration, until: Date().addingTimeInterval(seconds), failures: failures)
                throw error
            }
        }
    }

    private func policyURL(_ id: UUID) -> URL? { SharedFileLock.directory?.appendingPathComponent("retry-\(id.uuidString).json") }
    private func loadPolicy(_ id: UUID, generation: UUID?) -> NativeRetryPolicy? {
        guard let url = policyURL(id), let data = try? Data(contentsOf: url) else { return nil }
        guard let policy = try? JSONDecoder().decode(NativeRetryPolicy.self, from: data), policy.generation == generation else { return nil }
        return policy
    }
    private func savePolicy(_ id: UUID, generation: UUID?, until: Date, failures: Int) {
        guard let url = policyURL(id), let data = try? JSONEncoder().encode(NativeRetryPolicy(until: until, failures: failures, generation: generation)) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    }
}
