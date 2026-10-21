import SwiftUI
import WidgetKit

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var accounts: [UsageAccount]
    @Published private(set) var refreshingIDs = Set<UUID>()
    @Published var message: String?
    @Published var widgetWarning: String?
    @Published var requestedAccount: UUID?
    @Published var requestedDestination: String?
    @Published var visibleBrowserID: UUID?
    let browsers = ProviderBrowserRegistry()
    let claudeOAuth = ClaudeOAuthService()
    let codexOAuth = CodexOAuthService()
    private lazy var nativeReader = NativeUsageReader(claude: claudeOAuth, codex: codexOAuth)
    var accountsDidChange: (() -> Void)?
    private let defaults: UserDefaults
    private let now: () -> Date
    private let readOverride: ((UsageAccount) async throws -> ProviderCapture)?
    private let key = "headroom.accounts.v1"
    private struct Request { var id: UUID; var backgroundRun: UUID? }
    private struct RetryState: Codable { var until: Date; var failures: Int }
    private var queue: [Request] = []
    private var requestContexts: [UUID: UUID] = [:]
    private var backgroundRuns: [UUID: BackgroundRefreshReport] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var tokens: [UUID: UUID] = [:]
    private var generations: [UUID: Int] = [:]
    private var nextRefresh: [UUID: Date] = [:]
    private var failures: [UUID: Int] = [:]

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { .now }, readOverride: ((UsageAccount) async throws -> ProviderCapture)? = nil) {
        self.defaults = defaults
        self.now = now
        self.readOverride = readOverride
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--reset-local-data") {
            defaults.removeObject(forKey: key)
        }
        #endif
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([UsageAccount].self, from: data) {
            accounts = saved.compactMap(\.removingDemoData)
        } else { accounts = [] }
        if let data = defaults.data(forKey: "headroom.refreshRetry.v1"), let saved = try? JSONDecoder().decode([String: RetryState].self, from: data) {
            for (key, state) in saved {
                guard let id = UUID(uuidString: key), accounts.contains(where: { $0.id == id }) else { continue }
                nextRefresh[id] = state.until; failures[id] = max(0, min(10, state.failures))
            }
        }
        save()
    }

    var isRefreshing: Bool { !refreshingIDs.isEmpty || !queue.isEmpty }
    func account(_ id: UUID) -> UsageAccount? { accounts.first { $0.id == id } }

    // Retained for existing manual accounts and offline entry; sign-in is the
    // normal add-account flow and creates an account only after a usage read.
    @discardableResult
    func add(provider: AIProvider, alias: String, plan: String) -> UUID {
        let id = UUID()
        accounts.append(.init(id: id, provider: provider, alias: alias, plan: plan.isEmpty ? "Subscription" : plan, session: .unavailable, weekly: .unavailable, history: []))
        save()
        return id
    }

    func connect(profileID: UUID, provider: AIProvider, alias: String, capture: ProviderCapture, claudeCredential: ClaudeCredential? = nil, codexCredential: CodexCredential? = nil) throws {
        guard let workspace = capture.workspace, capture.usage != nil else { throw ProviderSyncError.unavailable }
        if claudeCredential != nil, provider != .claude { throw ProviderSyncError.wrongAccount }
        if let codexCredential {
            guard provider == .chatGPT, claudeCredential == nil,
                  codexCredential.userID == capture.identity.id, codexCredential.accountID == workspace.id else { throw ProviderSyncError.wrongAccount }
        }
        if let existing = account(profileID), existing.provider != provider { throw ProviderSyncError.wrongAccount }
        if accounts.contains(where: { $0.id != profileID && $0.provider == provider && $0.providerUserID == capture.identity.id && $0.workspaceID == workspace.id }) {
            throw ConnectionError.alreadyConnected
        }
        if let existing = account(profileID), existing.isConnected,
           existing.providerUserID != capture.identity.id || existing.workspaceID != workspace.id { throw ProviderSyncError.wrongAccount }
        if let claudeCredential { try claudeOAuth.vault.save(claudeCredential, for: profileID) }
        if let codexCredential { try codexOAuth.vault.save(codexCredential, for: profileID) }
        generations[profileID, default: 0] += 1
        tasks[profileID]?.cancel()
        markBackgroundCancellation(profileID)
        tokens[profileID] = nil
        tasks[profileID] = nil
        refreshingIDs.remove(profileID)
        queue.removeAll { $0.id == profileID }
        if account(profileID) == nil {
            let label = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            accounts.append(.init(id: profileID, provider: provider, alias: label.isEmpty ? capture.identity.email ?? workspace.name : label, plan: "Subscription", session: .unavailable, weekly: .unavailable, history: []))
        }
        if let index = accounts.firstIndex(where: { $0.id == profileID }) {
            accounts[index].connectionMethod = claudeCredential != nil ? .claudeOAuth : codexCredential != nil ? .codexOAuth : .web
            accounts[index].connectionGeneration = UUID()
            if claudeCredential == nil { claudeOAuth.vault.remove(profileID) }
            if codexCredential == nil { codexOAuth.vault.remove(profileID) }
        }
        apply(capture, to: profileID)
        nextRefresh[profileID] = now().addingTimeInterval(60)
        failures[profileID] = 0
        saveRetryPolicy()
        drain()
    }

    func discardConnection(_ id: UUID) {
        if account(id) == nil { browsers.remove(id) }
    }

    func refresh(accountID: UUID? = nil, force: Bool = true) {
        enqueue(accountID: accountID, force: force, backgroundRun: nil)
    }

    var backgroundEligibleAccounts: [UsageAccount] {
        accounts.filter { $0.isConnected && !$0.needsSignIn && $0.supportsBackgroundRefresh }
    }

    private func enqueue(accountID: UUID?, force: Bool, backgroundRun: UUID?, accountIDs: Set<UUID>? = nil) {
        let candidates = accounts.filter { $0.isConnected && (accountID == nil || $0.id == accountID) && (accountIDs == nil || accountIDs!.contains($0.id)) && (backgroundRun == nil || $0.supportsBackgroundRefresh) }
        for account in candidates where tasks[account.id] == nil && !queue.contains(where: { $0.id == account.id }) && account.id != visibleBrowserID {
            if let next = nextRefresh[account.id], next > now() { continue }
            if let last = account.lastSyncedAt, now().timeIntervalSince(last) < 60 { continue }
            if !force, account.needsSignIn { continue }
            queue.append(.init(id: account.id, backgroundRun: backgroundRun))
            if let backgroundRun { backgroundRuns[backgroundRun]?.attempted += 1 }
        }
        drain()
    }

    func stopRefreshing() {
        for id in tasks.keys { markBackgroundCancellation(id) }
        for request in queue { if let run = request.backgroundRun { backgroundRuns[run]?.cancelled = true } }
        queue.removeAll()
        for task in tasks.values { task.cancel() }
        tasks.removeAll(); tokens.removeAll(); refreshingIDs.removeAll(); requestContexts.removeAll()
    }

    func stopForegroundRefreshing() {
        queue.removeAll { $0.backgroundRun == nil }
        for id in Array(tasks.keys) where requestContexts[id] == nil {
            tasks.removeValue(forKey: id)?.cancel(); tokens[id] = nil; refreshingIDs.remove(id)
        }
    }

    func refreshInBackground(force: Bool = false, accountIDs: Set<UUID>? = nil) async -> BackgroundRefreshReport {
        guard !Task.isCancelled else { return .init(cancelled: true) }
        let run = UUID()
        backgroundRuns[run] = .init()
        enqueue(accountID: nil, force: force, backgroundRun: run, accountIDs: accountIDs)
        return await withTaskCancellationHandler {
            while queue.contains(where: { $0.backgroundRun == run }) || requestContexts.values.contains(run) {
                if Task.isCancelled { cancelBackgroundRun(run); break }
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { cancelBackgroundRun(run); break }
            }
            let report = backgroundRuns.removeValue(forKey: run) ?? .init(cancelled: true)
            return report
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelBackgroundRun(run) }
        }
    }

    private func cancelBackgroundRun(_ run: UUID) {
        guard backgroundRuns[run] != nil else { return }
        backgroundRuns[run]?.cancelled = true
        queue.removeAll { $0.backgroundRun == run }
        for id in Array(requestContexts.keys) where requestContexts[id] == run {
            tasks.removeValue(forKey: id)?.cancel(); tokens[id] = nil
            requestContexts[id] = nil; refreshingIDs.remove(id)
        }
        drain()
    }

    func cancelBackgroundRefreshes() {
        for run in Array(backgroundRuns.keys) { cancelBackgroundRun(run) }
    }

    private func markBackgroundCancellation(_ id: UUID) {
        if let run = requestContexts.removeValue(forKey: id) { backgroundRuns[run]?.cancelled = true }
        for request in queue where request.id == id {
            if let run = request.backgroundRun { backgroundRuns[run]?.cancelled = true }
        }
    }

    func refreshAndWait() async {
        refresh()
        while isRefreshing, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(200)) }
    }

    private func drain() {
        while tasks.count < 2, !queue.isEmpty {
            let request = queue.removeFirst()
            let id = request.id
            guard let account = account(id), account.isConnected, id != visibleBrowserID else { continue }
            let browser = account.connectionMethod == .claudeOAuth || account.connectionMethod == .codexOAuth ? nil : browsers.browser(id: id, provider: account.provider)
            let generation = generations[id, default: 0]
            let token = UUID()
            tokens[id] = token
            requestContexts[id] = request.backgroundRun
            refreshingIDs.insert(id)
            tasks[id] = Task { [weak self] in
                guard let self else { return }
                defer {
                    if self.tokens[id] == token {
                        self.tasks[id] = nil; self.tokens[id] = nil
                        self.refreshingIDs.remove(id)
                        self.requestContexts[id] = nil
                        self.drain()
                    }
                }
                do {
                    let capture: ProviderCapture
                    if let readOverride = self.readOverride {
                        capture = try await readOverride(account)
                    } else if account.supportsBackgroundRefresh {
                        capture = try await self.nativeReader.read(account)
                    } else if let browser { capture = try await browser.read(workspaceID: account.workspaceID) }
                    else { throw ProviderSyncError.signInRequired }
                    try Task.checkCancellation()
                    guard self.tokens[id] == token, self.generations[id, default: 0] == generation,
                          let current = self.account(id), current.providerUserID == account.providerUserID,
                          current.workspaceID == account.workspaceID else { return }
                    guard capture.identity.id == account.providerUserID, capture.workspace?.id == account.workspaceID else { throw ProviderSyncError.wrongAccount }
                    guard capture.usage != nil else { throw ProviderSyncError.unavailable }
                    self.apply(capture, to: id)
                    if let run = request.backgroundRun { self.backgroundRuns[run]?.updated += 1 }
                    self.failures[id] = 0
                    self.nextRefresh[id] = self.now().addingTimeInterval(60)
                    self.saveRetryPolicy()
                } catch {
                    guard !Task.isCancelled, self.tokens[id] == token,
                          self.generations[id, default: 0] == generation,
                          let index = self.accounts.firstIndex(where: { $0.id == id }) else { return }
                    self.accounts[index].syncError = Self.syncMessage(error)
                    if let run = request.backgroundRun { self.backgroundRuns[run]?.failed += 1 }
                    self.accounts[index].needsSignIn = (error as? ProviderSyncError)?.requiresInteraction ?? false
                    self.failures[id, default: 0] += 1
                    let backoff: TimeInterval
                    if case let ProviderSyncError.rateLimited(seconds) = error { backoff = seconds.isFinite ? min(3600, max(60, seconds)) : 300 }
                    else { backoff = min(1800, 60 * pow(2, Double(min(self.failures[id, default: 1] - 1, 5)))) }
                    self.nextRefresh[id] = self.now().addingTimeInterval(backoff)
                    self.saveRetryPolicy()
                    self.save()
                }
            }
        }
    }

    private func apply(_ capture: ProviderCapture, to id: UUID) {
        guard let usage = capture.usage, let workspace = capture.workspace,
              let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].apply(capture)
        save()
    }

    static func syncMessage(_ error: Error) -> String {
        if let error = error as? ProviderSyncError { return error.localizedDescription }
        if let error = error as? ClaudeAuthorizationError { return error.localizedDescription }
        if let error = error as? CodexAuthorizationError { return error.localizedDescription }
        return "Could not read usage. Check your internet connection and try again. Saved readings are unchanged."
    }

    func record(accountID: UUID, period: QuotaPeriod, percent: Double, reset: Date?, observedAt: Date) {
        guard percent.isFinite, (0...100).contains(percent), let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[index].record(.init(usedPercent: percent, observedAt: observedAt, resetsAt: reset, source: .manual), for: period)
        save()
    }

    func recordModelLimit(accountID: UUID, id: String?, modelName: String, windowLabel: String, percent: Double, count: QuotaCount?, reset: Date?, observedAt: Date) {
        let name = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let window = windowLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !window.isEmpty, percent.isFinite, (0...100).contains(percent), count == nil || count?.isValid == true,
              let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        if let id, !accounts[index].modelLimits.contains(where: { $0.id == id }) { return }
        let reading = QuotaReading(usedPercent: percent, observedAt: observedAt, resetsAt: reset, source: .manual)
        accounts[index].recordModelLimit(.init(id: id ?? UUID().uuidString, modelName: name, windowLabel: window, reading: reading, count: count))
        save()
    }

    func delete(_ id: UUID) {
        generations[id, default: 0] += 1
        markBackgroundCancellation(id)
        tasks[id]?.cancel(); tasks[id] = nil; tokens[id] = nil
        refreshingIDs.remove(id); queue.removeAll { $0.id == id }
        accounts.removeAll { $0.id == id }
        claudeOAuth.vault.remove(id)
        codexOAuth.vault.remove(id)
        browsers.remove(id)
        nextRefresh[id] = nil; failures[id] = nil
        saveRetryPolicy()
        save(); drain()
    }

    func openAccount(from url: URL) {
        guard url.scheme == "headroom" else { return }
        if let host = url.host, ["overview", "activity", "accounts", "widgets"].contains(host) { requestedDestination = host }
        else if url.host == "account", let id = UUID(uuidString: url.lastPathComponent), account(id) != nil { requestedAccount = id }
    }

    private func save() {
        do {
            accounts = try WidgetSnapshotStore.publish(accounts).accounts
            if let report = WidgetDiagnostics.latest(), let data = try? JSONEncoder().encode(report) {
                // Counts/version/status only, for diagnosing widget execution.
                defaults.set(data, forKey: "headroom.widgetRead.v1")
            }
            if let status = WidgetRefreshStatus.load(), let data = try? JSONEncoder().encode(status) {
                defaults.set(data, forKey: "headroom.widgetRefreshStatus.v1")
            }
            widgetWarning = nil
            WidgetCenter.shared.reloadTimelines(ofKind: "HeadroomLiveOverview")
            let widgetVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            if defaults.string(forKey: "headroom.widgetCacheVersion") != widgetVersion {
                // Invalidate archived views left by earlier builds, including
                // the original demo widgets, after publishing the clean data.
                WidgetCenter.shared.reloadAllTimelines()
                defaults.set(widgetVersion, forKey: "headroom.widgetCacheVersion")
            }
        } catch { widgetWarning = "Widget sharing is unavailable. Check that the app and widget have the same App Group entitlement." }
        if let data = try? JSONEncoder().encode(accounts) { defaults.set(data, forKey: key) }
        accountsDidChange?()
    }

    func reloadSharedReadings() { save() }

    private func saveRetryPolicy() {
        let saved = Dictionary(uniqueKeysWithValues: nextRefresh.map { id, date in (id.uuidString, RetryState(until: date, failures: failures[id, default: 0])) })
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: "headroom.refreshRetry.v1") }
    }
}

struct BackgroundRefreshReport: Equatable, Sendable {
    var attempted = 0
    var updated = 0
    var failed = 0
    var cancelled = false
    var succeeded: Bool { !cancelled && failed == 0 && updated == attempted }
}

enum ConnectionError: LocalizedError {
    case alreadyConnected
    var errorDescription: String? { "This account and workspace are already connected. Refresh the existing account, or sign in to another one." }
}
