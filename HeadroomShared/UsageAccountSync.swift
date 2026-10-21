import Foundation

extension UsageAccount {
    func hasSameConnection(as other: UsageAccount) -> Bool {
        id == other.id && provider == other.provider && providerUserID == other.providerUserID &&
        workspaceID == other.workspaceID && connectionMethod == other.connectionMethod && connectionGeneration == other.connectionGeneration
    }

    mutating func apply(_ capture: ProviderCapture) {
        guard let usage = capture.usage, let workspace = capture.workspace else { return }
        if lastSyncedAt == usage.observedAt, session == usage.session, weekly == usage.weekly,
           modelLimits.filter({ $0.reading.source == .provider }) == usage.limits { return }
        providerUserID = capture.identity.id; email = capture.identity.email
        workspaceID = workspace.id; workspaceName = workspace.name
        if let plan = usage.plan ?? workspace.plan { self.plan = plan.replacingOccurrences(of: "_", with: " ").capitalized }
        record(usage.session, for: .session); record(usage.weekly, for: .weekly)
        modelLimits = modelLimits.filter { $0.reading.source == .manual && !usage.limits.map(\.id).contains($0.id) }
        for limit in usage.limits { recordModelLimit(limit) }
        lastSyncedAt = usage.observedAt; syncError = nil; needsSignIn = false
    }

    func mergingNewerReadings(from other: UsageAccount) -> UsageAccount {
        guard hasSameConnection(as: other) else { return self }
        var merged = self
        let newerCapture = (other.lastSyncedAt ?? .distantPast) > (lastSyncedAt ?? .distantPast)
        for period in QuotaPeriod.allCases {
            let current = reading(for: period), candidate = other.reading(for: period)
            if (candidate.observedAt ?? .distantPast) > (current.observedAt ?? .distantPast) ||
               (newerCapture && candidate.source == .provider && candidate.observedAt == nil && (current.observedAt ?? .distantPast) <= (other.lastSyncedAt ?? .distantPast)) {
                if period == .session { merged.session = candidate } else { merged.weekly = candidate }
            }
        }
        if let date = other.lastSyncedAt, date > (lastSyncedAt ?? .distantPast) {
            merged.lastSyncedAt = date; merged.plan = other.plan
            merged.syncError = other.syncError; merged.needsSignIn = other.needsSignIn
            let manual = modelLimits.filter { $0.reading.source == .manual && !other.modelLimits.map(\.id).contains($0.id) }
            merged.modelLimits = other.modelLimits + manual
        }
        var ids = Set<UUID>()
        merged.history = Array((history + other.history).filter { ids.insert($0.id).inserted }.sorted { $0.date < $1.date }.suffix(500))
        return merged
    }

    var cachedCapture: ProviderCapture? {
        guard let user = providerUserID, let workspaceID, let lastSyncedAt else { return nil }
        let workspace = ProviderWorkspace(id: workspaceID, name: workspaceName ?? "Workspace", plan: plan)
        return .init(identity: .init(id: user, email: email), workspaces: [workspace], workspace: workspace,
                     usage: .init(session: session, weekly: weekly, limits: modelLimits.filter { $0.reading.source == .provider }, plan: plan, observedAt: lastSyncedAt))
    }
}
