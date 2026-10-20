import Foundation

enum AIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, chatGPT
    var id: String { rawValue }
    var name: String { self == .claude ? "Claude" : "ChatGPT" }
    var symbol: String { self == .claude ? "sparkles" : "circle.hexagongrid" }
}

enum QuotaPeriod: String, Codable, CaseIterable, Identifiable, Sendable {
    case session, weekly
    var id: String { rawValue }
    var name: String { self == .session ? "Session" : "Weekly" }
}

enum ReadingSource: String, Codable, Sendable {
    case sample, manual, provider
    var name: String {
        switch self {
        case .sample: return "Sample reading"
        case .manual: return "Manual reading"
        case .provider: return "Provider reading"
        }
    }
}

enum ReadingState: Equatable, Sendable {
    case unavailable, current, stale, awaitingReset
}

struct QuotaReading: Codable, Equatable, Sendable {
    var usedPercent: Double?
    var observedAt: Date?
    var resetsAt: Date?
    var source: ReadingSource
    var windowDurationMinutes: Int? = nil

    func windowName(fallback: String) -> String {
        guard let minutes = windowDurationMinutes, minutes > 0 else { return fallback }
        if minutes == 10080 { return "Weekly" }
        if minutes == 1440 { return "Daily" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)-day" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }

    var displayPercent: Double? {
        guard let value = usedPercent, value.isFinite else { return nil }
        return min(100, max(0, value))
    }

    func state(at date: Date) -> ReadingState {
        guard displayPercent != nil, let observedAt else { return .unavailable }
        if let resetsAt, resetsAt <= date { return .awaitingReset }
        if date.timeIntervalSince(observedAt) > 15 * 60 { return .stale }
        return .current
    }

    func widgetPercent(at date: Date) -> Double? {
        state(at: date) == .awaitingReset ? nil : displayPercent
    }

    static let unavailable = QuotaReading(usedPercent: nil, observedAt: nil, resetsAt: nil, source: .manual)
}

struct QuotaObservation: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var date: Date
    var period: QuotaPeriod?
    var usedPercent: Double
    var source: ReadingSource
    var modelLimitID: String? = nil
    var windowLabel: String? = nil
    var title: String { windowLabel ?? period?.name ?? "Quota" }
}

enum QuotaUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case messages, tokens, requests
    var id: String { rawValue }
}

struct QuotaCount: Codable, Equatable, Sendable {
    var used: Double
    var limit: Double
    var unit: QuotaUnit
    var isValid: Bool { used.isFinite && limit.isFinite && used >= 0 && limit > 0 }
    var percent: Double? { isValid ? min(100, (used / limit) * 100) : nil }
    var label: String? {
        guard isValid else { return nil }
        return "\(used.formatted(.number.precision(.fractionLength(0...2)))) / \(limit.formatted(.number.precision(.fractionLength(0...2)))) \(unit.rawValue) used"
    }
}

struct ModelQuotaLimit: Codable, Identifiable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var modelName: String
    var windowLabel: String
    var reading: QuotaReading
    var count: QuotaCount? = nil

    // Provider percentages take precedence. Counts fill a missing percentage,
    // but never manufacture a token count from an allowance percentage.
    var quotaReading: QuotaReading {
        var result = reading
        if result.displayPercent == nil { result.usedPercent = count?.percent }
        return result
    }
    var title: String { "\(modelName) · \(windowLabel)" }
    func scopedID(accountID: UUID) -> String { "\(accountID.uuidString)|\(id)" }
}

enum ProviderConnectionMethod: String, Codable, Sendable { case web, claudeOAuth, codexOAuth }

struct UsageAccount: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var provider: AIProvider
    var alias: String
    var plan: String
    var session: QuotaReading
    var weekly: QuotaReading
    var history: [QuotaObservation]
    var modelLimits: [ModelQuotaLimit]
    var providerUserID: String? = nil
    var workspaceID: String? = nil
    var workspaceName: String? = nil
    var email: String? = nil
    var lastSyncedAt: Date? = nil
    var syncError: String? = nil
    var needsSignIn: Bool = false
    var connectionMethod: ProviderConnectionMethod? = nil

    init(id: UUID, provider: AIProvider, alias: String, plan: String, session: QuotaReading, weekly: QuotaReading, history: [QuotaObservation], modelLimits: [ModelQuotaLimit] = []) {
        self.id = id; self.provider = provider; self.alias = alias; self.plan = plan
        self.session = session; self.weekly = weekly; self.history = history; self.modelLimits = modelLimits
    }

    private enum CodingKeys: String, CodingKey { case id, provider, alias, plan, session, weekly, history, modelLimits, providerUserID, workspaceID, workspaceName, email, lastSyncedAt, syncError, needsSignIn, connectionMethod }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        provider = try values.decode(AIProvider.self, forKey: .provider)
        alias = try values.decode(String.self, forKey: .alias)
        plan = try values.decode(String.self, forKey: .plan)
        session = try values.decode(QuotaReading.self, forKey: .session)
        weekly = try values.decode(QuotaReading.self, forKey: .weekly)
        history = try values.decode([QuotaObservation].self, forKey: .history)
        modelLimits = try values.decodeIfPresent([ModelQuotaLimit].self, forKey: .modelLimits) ?? []
        providerUserID = try values.decodeIfPresent(String.self, forKey: .providerUserID)
        workspaceID = try values.decodeIfPresent(String.self, forKey: .workspaceID)
        workspaceName = try values.decodeIfPresent(String.self, forKey: .workspaceName)
        email = try values.decodeIfPresent(String.self, forKey: .email)
        lastSyncedAt = try values.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        syncError = try values.decodeIfPresent(String.self, forKey: .syncError)
        needsSignIn = try values.decodeIfPresent(Bool.self, forKey: .needsSignIn) ?? false
        connectionMethod = try values.decodeIfPresent(ProviderConnectionMethod.self, forKey: .connectionMethod)
    }

    var title: String { "\(provider.name) / \(alias)" }
    var isConnected: Bool { providerUserID != nil && workspaceID != nil }
    var supportsBackgroundRefresh: Bool {
        (provider == .claude && connectionMethod == .claudeOAuth) || (provider == .chatGPT && connectionMethod == .codexOAuth)
    }
    var coverage: String { provider == .claude ? "Shared Claude allowance" : "Codex allowance" }
    var connectionLabel: String { needsSignIn ? "Sign in again" : syncError != nil ? "Sync needs attention" : isConnected ? "Connected" : "Not connected" }
    func windowName(for period: QuotaPeriod) -> String { reading(for: period).windowName(fallback: period.name) }
    func reading(for period: QuotaPeriod) -> QuotaReading { period == .session ? session : weekly }
    // Preserve real zero, stale, and reset-awaiting-update readings. Omit only
    // windows for which there is no usable saved allowance reading.
    var reportedQuotaPeriods: [QuotaPeriod] {
        QuotaPeriod.allCases.filter { reading(for: $0).displayPercent != nil }
    }
    func displayPeriod(preferred: QuotaPeriod) -> QuotaPeriod {
        reportedQuotaPeriods.contains(preferred) ? preferred : reportedQuotaPeriods.first ?? preferred
    }

    mutating func record(_ reading: QuotaReading, for period: QuotaPeriod) {
        if period == .session { session = reading } else { weekly = reading }
        if let date = reading.observedAt, let percent = reading.displayPercent {
            history.append(.init(date: date, period: period, usedPercent: percent, source: reading.source))
            history = Array(history.suffix(500))
        }
    }

    mutating func recordModelLimit(_ limit: ModelQuotaLimit) {
        if let index = modelLimits.firstIndex(where: { $0.id == limit.id }) { modelLimits[index] = limit }
        else { modelLimits.append(limit) }
        let reading = limit.quotaReading
        if let date = reading.observedAt, let percent = reading.displayPercent {
            history.append(.init(date: date, period: nil, usedPercent: percent, source: reading.source, modelLimitID: limit.id, windowLabel: limit.windowLabel))
            history = Array(history.suffix(500))
        }
    }

    var allReadings: [QuotaReading] { [session, weekly] + modelLimits.map(\.quotaReading) }

    // Remove only known seeded accounts. Real local/manual accounts survive upgrades.
    var removingDemoData: UsageAccount? {
        let seededIDs = (1...4).map { String(format: "00000000-0000-0000-0000-%012d", $0) }
        if !isConnected && seededIDs.contains(id.uuidString.lowercased()) { return nil }
        var clean = self
        if clean.session.source == .sample { clean.session = .unavailable }
        if clean.weekly.source == .sample { clean.weekly = .unavailable }
        clean.modelLimits.removeAll { $0.reading.source == .sample }
        clean.history.removeAll { $0.source == .sample }
        return clean
    }
}


struct WidgetSnapshot: Codable, Sendable {
    var accounts: [UsageAccount]
    var publishedAt: Date
    static let empty = WidgetSnapshot(accounts: [], publishedAt: .distantPast)
}

enum WidgetDataState: Equatable, Sendable {
    case ready, empty, unavailable
    var title: String {
        switch self {
        case .ready: return "Headroom"
        case .empty: return "Connect an account"
        case .unavailable: return "Saved usage unavailable"
        }
    }
    var detail: String {
        switch self {
        case .ready: return "Your saved provider readings will appear here."
        case .empty: return "Open Headroom to connect Claude or ChatGPT."
        case .unavailable: return "Open Headroom once to share your latest readings."
        }
    }
}

struct WidgetSnapshotResult: Sendable {
    var snapshot: WidgetSnapshot
    var state: WidgetDataState
}

enum WidgetSnapshotStore {
    static let groupID = "group.com.example.headroom"
    private static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?.appendingPathComponent("widget-snapshot.json")
    }

    static func load() -> WidgetSnapshot {
        loadResult().snapshot
    }

    static func loadResult() -> WidgetSnapshotResult { loadResult(from: fileURL) }

    static func loadResult(from url: URL?) -> WidgetSnapshotResult {
        guard let url, let data = try? Data(contentsOf: url), let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else {
            return .init(snapshot: .empty, state: .unavailable)
        }
        let clean = WidgetSnapshot(accounts: snapshot.accounts.compactMap(\.removingDemoData), publishedAt: snapshot.publishedAt)
        return .init(snapshot: clean, state: clean.accounts.isEmpty ? .empty : .ready)
    }

    static func publish(_ accounts: [UsageAccount], at date: Date = .now) throws {
        guard let url = fileURL else { throw CocoaError(.fileNoSuchFile) }
        let snapshot = WidgetSnapshot(accounts: accounts, publishedAt: date)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    }
}
