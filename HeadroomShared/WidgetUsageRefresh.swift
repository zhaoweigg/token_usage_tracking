import Foundation
import WidgetKit

struct WidgetRefreshStatus: Codable {
    enum Outcome: String, Codable { case updated, partial, failed, waiting, signIn, expired }
    var attemptedAt: Date
    var completedAt: Date
    var updated: Int
    var failed: Int
    var outcome: Outcome
    var title: String {
        switch outcome {
        case .updated: return "Updated"
        case .partial: return "Some accounts need refresh"
        case .failed: return "Refresh failed"
        case .waiting: return "Try again later"
        case .signIn: return "Open app to sign in"
        case .expired: return "Refresh interrupted"
        }
    }
    private static var url: URL? { SharedFileLock.directory?.appendingPathComponent("widget-refresh-status.json") }
    static func load() -> Self? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    func save() {
        guard let url = Self.url, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    }
}

@MainActor
final class WidgetUsageRefresh {
    private let reader: NativeUsageReader
    private let budget: TimeInterval
    init(reader: NativeUsageReader? = nil, budget: TimeInterval = 22) {
        self.reader = reader ?? NativeUsageReader(); self.budget = budget
    }

    @discardableResult
    func refresh(accountIDs: Set<UUID>? = nil, automatic: Bool = false) async -> WidgetRefreshStatus? {
        if automatic, UserDefaults(suiteName: WidgetSnapshotStore.groupID)?.object(forKey: "headroom.automaticRefreshEnabled") as? Bool == false {
            return WidgetRefreshStatus.load()
        }
        let snapshot = WidgetSnapshotStore.load()
        // A widget awakened by test snapshot publication must never send the
        // harness's synthetic accounts/credentials to real provider endpoints.
        guard snapshot.allowsWidgetNetwork != false || reader.usesTestTransport else { return nil }
        let accounts = snapshot.accounts.filter {
            $0.isConnected && $0.supportsBackgroundRefresh && (accountIDs == nil || accountIDs!.contains($0.id))
        }
        let candidates = accounts.filter { !$0.needsSignIn && (!automatic || Date().timeIntervalSince($0.lastSyncedAt ?? .distantPast) >= 300) }
        guard !candidates.isEmpty else {
            if !accounts.isEmpty, accounts.allSatisfy(\.needsSignIn) {
                let status = WidgetRefreshStatus(attemptedAt: .now, completedAt: .now, updated: 0, failed: accounts.count, outcome: .signIn)
                status.save(); return status
            }
            return WidgetRefreshStatus.load()
        }
        let started = Date(), reader = reader
        let work = Task { @MainActor in
            var updated = 0, failed = 0, waiting = false, signIn = false
            for offset in stride(from: 0, to: candidates.count, by: 2) {
                guard !Task.isCancelled else { break }
                let batch = candidates[offset..<min(offset + 2, candidates.count)].map { account in
                    Task { @MainActor () -> Result<ProviderCapture, Error> in
                        do { return .success(try await reader.read(account, publish: true)) }
                        catch { return .failure(error) }
                    }
                }
                await withTaskCancellationHandler {
                    for task in batch {
                        switch await task.value {
                        case .success(let capture):
                            if let observed = capture.usage?.observedAt, observed >= started { updated += 1 } else { waiting = true }
                        case .failure(let error):
                            failed += 1
                            if case ProviderSyncError.rateLimited = error { waiting = true }
                            if let error = error as? ProviderSyncError, error.requiresInteraction { signIn = true }
                        }
                    }
                } onCancel: { for task in batch { task.cancel() } }
            }
            return WidgetRefreshStatus(attemptedAt: started, completedAt: .now, updated: updated, failed: failed,
                                       outcome: Task.isCancelled ? .expired : updated > 0 ? (failed > 0 ? .partial : .updated) : signIn ? .signIn : waiting ? .waiting : .failed)
        }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(budget)) } catch { return }
            work.cancel()
        }
        defer { deadline.cancel() }
        let status = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        status.save()
        if !automatic { WidgetCenter.shared.reloadTimelines(ofKind: "HeadroomLiveOverview") }
        return status
    }
}
