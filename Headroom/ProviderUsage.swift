import Foundation
import CoreFoundation

struct ProviderWorkspace: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var plan: String?
}

struct ProviderIdentity: Codable, Equatable, Sendable {
    var id: String
    var email: String?
}

struct ProviderCapture: Sendable {
    var identity: ProviderIdentity
    var workspaces: [ProviderWorkspace]
    var workspace: ProviderWorkspace?
    var usage: ProviderUsage?
}

struct ProviderUsage: Sendable {
    var session: QuotaReading
    var weekly: QuotaReading
    var limits: [ModelQuotaLimit]
    var plan: String?
    var observedAt: Date
}

enum ProviderSyncError: Error, LocalizedError, Equatable {
    case signInRequired, challenge, forbidden, invalidResponse, unavailable, wrongAccount, busy, cancelled, timedOut
    case rateLimited(TimeInterval)
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .signInRequired: return "Sign in to this account to sync usage. Your saved readings are unchanged."
        case .challenge: return "The provider needs a browser check. Open the connection and complete it, then check usage again."
        case .forbidden: return "This account cannot access that usage page. Check the account and workspace in the connection."
        case .invalidResponse: return "The provider returned an unrecognized usage format. Saved readings are unchanged."
        case .unavailable: return "Usage is not available for this account or workspace yet."
        case .wrongAccount: return "The signed-in account or workspace changed. Add it as a separate account to keep readings isolated."
        case .busy: return "This account is already syncing."
        case .cancelled: return "The connection was closed."
        case .timedOut: return "The provider took too long to respond. Try again when the connection is ready."
        case .rateLimited: return "The provider asked Headroom to wait. Try again in a few minutes."
        case .server(let status): return "The provider could not return usage (HTTP \(status)). Try again later."
        }
    }
    var requiresInteraction: Bool { self == .signInRequired || self == .challenge || self == .forbidden || self == .wrongAccount }
}

enum ProviderUsageParser {
    typealias Object = [String: Any]

    static func capture(data: Data, provider: AIProvider, observedAt: Date = .now) throws -> ProviderCapture {
        guard let object = try JSONSerialization.jsonObject(with: data) as? Object else { throw ProviderSyncError.invalidResponse }
        if let error = object["error"] as? String {
            switch error {
            case "signInRequired": throw ProviderSyncError.signInRequired
            case "challenge": throw ProviderSyncError.challenge
            case "forbidden": throw ProviderSyncError.forbidden
            case "wrongAccount": throw ProviderSyncError.wrongAccount
            case "timeout": throw ProviderSyncError.timedOut
            case "unavailable": throw ProviderSyncError.unavailable
            case "rateLimited": throw ProviderSyncError.rateLimited(number(object["retryAfter"]) ?? 300)
            case "http":
                let status = number(object["status"]) ?? 500
                throw ProviderSyncError.server((100...599).contains(status) ? Int(status) : 500)
            case "network": throw URLError(.notConnectedToInternet)
            default: throw ProviderSyncError.invalidResponse
            }
        }
        guard let identityObject = object["identity"] as? Object, let id = string(identityObject["id"]),
              let rawWorkspaces = object["workspaces"] as? [Object] else { throw ProviderSyncError.invalidResponse }
        let workspaces = rawWorkspaces.compactMap { item -> ProviderWorkspace? in
            guard let id = string(item["id"]) else { return nil }
            return .init(id: id, name: string(item["name"]) ?? "Workspace", plan: string(item["plan"]))
        }
        guard !workspaces.isEmpty, Set(workspaces.map(\.id)).count == workspaces.count else { throw ProviderSyncError.unavailable }
        let selectedID = string(object["workspaceID"])
        let selected = workspaces.first { $0.id == selectedID }
        var usage: ProviderUsage?
        if let raw = object["usage"] as? Object {
            guard selected != nil else { throw ProviderSyncError.wrongAccount }
            usage = try provider == .claude ? claude(raw, observedAt: observedAt) : codex(raw, observedAt: observedAt)
        }
        return .init(identity: .init(id: id, email: string(identityObject["email"])), workspaces: workspaces, workspace: selected, usage: usage)
    }

    static func claude(_ raw: Object, observedAt: Date) throws -> ProviderUsage {
        guard ["five_hour", "seven_day", "limits", "extra_usage", "spend"].contains(where: { raw.keys.contains($0) }) else { throw ProviderSyncError.invalidResponse }
        var session = reading(raw["five_hour"] as? Object, at: observedAt, minutes: 300)
        var weekly = reading(raw["seven_day"] as? Object, at: observedAt, minutes: 10080)
        var limits: [ModelQuotaLimit] = []
        // Keep provider-discovered model pools, including ones unknown to this version.
        for key in raw.keys.sorted() where key.hasPrefix("seven_day_") || key.hasPrefix("five_hour_") {
            guard let value = raw[key] as? Object else { continue }
            let duration = key.hasPrefix("seven_day_") ? 10080 : 300
            let prefix = duration == 10080 ? "seven_day_" : "five_hour_"
            let label = string(value["display_name"]) ?? humanize(String(key.dropFirst(prefix.count)))
            if let limit = model(id: "claude-\(key)", name: label, value: value, at: observedAt, minutes: duration) { limits.append(limit) }
        }
        for (index, value) in (raw["limits"] as? [Object] ?? []).enumerated() {
            let kind = string(value["kind"]) ?? "limit_\(index)"
            if kind == "session" || kind == "five_hour" { session = reading(value, at: observedAt, minutes: 300) }
            else if kind == "weekly_all" || kind == "seven_day" { weekly = reading(value, at: observedAt, minutes: 10080) }
            else {
                let scopeObject = value["scope"] as? Object
                let scopedModel = scopeObject?["model"] as? Object
                let scope = string(scopedModel?["id"]) ?? string(value["scope"]) ?? string(value["model"]) ?? string(value["model_name"]) ?? string(value["model_group"])
                let name = string(scopedModel?["display_name"]) ?? string(value["display_name"]) ?? string(value["name"]) ?? scope.map(humanize) ?? humanize(kind)
                let surface = string(scopeObject?["surface"])
                let id = string(value["id"]) ?? "\(kind)-\(scope ?? name)-\(surface ?? "all")"
                let minutes = integer(value["window_duration_minutes"]) ?? (kind.contains("weekly") ? 10080 : nil)
                if let limit = model(id: "claude-\(id)", name: name, value: value, at: observedAt, minutes: minutes) { limits.append(limit) }
            }
        }
        guard session.displayPercent != nil || weekly.displayPercent != nil || !limits.isEmpty else { throw ProviderSyncError.unavailable }
        return .init(session: session, weekly: weekly, limits: unique(limits), plan: string(raw["plan_type"]), observedAt: observedAt)
    }

    static func codex(_ raw: Object, observedAt: Date) throws -> ProviderUsage {
        guard ["rate_limit", "rateLimits", "rate_limits_by_limit_id", "rateLimitsByLimitId", "additional_rate_limits"].contains(where: { raw.keys.contains($0) }) else { throw ProviderSyncError.invalidResponse }
        let buckets = raw["rateLimitsByLimitId"] as? Object ?? raw["rate_limits_by_limit_id"] as? Object ?? [:]
        let base = raw["rate_limit"] as? Object ?? buckets["codex"] as? Object ?? raw["rateLimits"] as? Object ?? [:]
        var session = QuotaReading(usedPercent: nil, observedAt: nil, resetsAt: nil, source: .provider)
        var weekly = session
        var limits: [ModelQuotaLimit] = []
        for (suffix, value) in windows(base) {
            let item = reading(value, at: observedAt, minutes: nil)
            if item.windowDurationMinutes == 10080 { weekly = item }
            else if suffix == "primary", item.windowDurationMinutes.map({ $0 < 1440 }) == true { session = item }
            else if item.displayPercent != nil {
                limits.append(.init(id: "codex-main-\(suffix)", modelName: "Codex", windowLabel: item.windowName(fallback: "Allowance"), reading: item, count: count(value)))
            }
        }
        var extra = (raw["additional_rate_limits"] as? [Object] ?? []).enumerated().map { index, item in
            (string(item["limit_id"]) ?? string(item["limitId"]) ?? string(item["metered_feature"]) ?? string(item["limit_name"]) ?? "additional-\(index)", item)
        }
        extra += buckets.keys.sorted().filter { $0 != "codex" }.compactMap { id in (buckets[id] as? Object).map { (id, $0) } }
        if let reviews = raw["code_review_rate_limit"] as? Object { extra.append(("code-review", ["limit_name": "Code review", "rate_limit": reviews])) }
        for (id, item) in extra {
            let name = string(item["limit_name"]) ?? string(item["limitName"]) ?? string(item["model"]) ?? string(item["metered_feature"]) ?? humanize(id)
            let windowObject = item["rate_limit"] as? Object ?? item
            for (suffix, value) in windows(windowObject) {
                if let limit = model(id: "codex-\(id)-\(suffix)", name: name, value: value, at: observedAt, minutes: nil) { limits.append(limit) }
            }
        }
        return .init(session: session, weekly: weekly, limits: unique(limits), plan: string(raw["plan_type"]) ?? string(base["planType"]), observedAt: observedAt)
    }

    private static func windows(_ value: Object) -> [(String, Object)] {
        [("primary", value["primary_window"] ?? value["primary"]), ("secondary", value["secondary_window"] ?? value["secondary"])].compactMap { key, value in
            (value as? Object).map { (key, $0) }
        }
    }

    private static func reading(_ value: Object?, at date: Date, minutes: Int?) -> QuotaReading {
        guard let value else { return .init(usedPercent: nil, observedAt: nil, resetsAt: nil, source: .provider) }
        let percent = number(value["utilization"]) ?? number(value["used_percent"]) ?? number(value["usedPercent"]) ?? number(value["percent"]) ?? count(value)?.percent
        let valid = percent.flatMap { (0...100).contains($0) ? $0 : nil }
        let seconds = number(value["limit_window_seconds"]) ?? number(value["window_seconds"])
        let duration = integer(value["windowDurationMins"]) ?? integer(value["window_duration_minutes"]) ?? seconds.flatMap { $0 > 0 && $0 < 315360000 ? Int($0 / 60) : nil } ?? minutes
        return .init(usedPercent: valid, observedAt: valid == nil ? nil : date, resetsAt: timestamp(value["resets_at"] ?? value["reset_at"] ?? value["resetsAt"]), source: .provider, windowDurationMinutes: duration)
    }

    private static func model(id: String, name: String, value: Object, at date: Date, minutes: Int?) -> ModelQuotaLimit? {
        let reading = reading(value, at: date, minutes: minutes)
        guard reading.displayPercent != nil else { return nil }
        return .init(id: id, modelName: name, windowLabel: reading.windowName(fallback: string(value["window_label"]) ?? "Allowance"), reading: reading, count: count(value))
    }

    private static func count(_ value: Object) -> QuotaCount? {
        guard let unitName = string(value["unit"]), let unit = QuotaUnit(rawValue: unitName),
              let used = number(value["used_count"] ?? value["used"]), let limit = number(value["limit_count"] ?? value["limit"]) else { return nil }
        let count = QuotaCount(used: used, limit: limit, unit: unit)
        return count.isValid ? count : nil
    }

    static func timestamp(_ value: Any?) -> Date? {
        if let seconds = number(value), seconds > 0 {
            let normalized = seconds > 100_000_000_000 ? seconds / 1000 : seconds
            return normalized < 32_503_680_000 ? Date(timeIntervalSince1970: normalized) : nil
        }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    private static func integer(_ value: Any?) -> Int? { number(value).flatMap { $0 > 0 && $0 < 10_000_000 ? Int($0) : nil } }
    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String, value.count <= 256, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
    private static func humanize(_ value: String) -> String { value.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized }
    private static func unique(_ limits: [ModelQuotaLimit]) -> [ModelQuotaLimit] {
        var seen = Set<String>()
        return limits.filter { seen.insert($0.id).inserted }
    }
}
