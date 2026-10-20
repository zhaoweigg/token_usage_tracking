import Foundation
#if canImport(Headroom)
@testable import Headroom
#endif

enum UsageFixtures {
    static func accounts(now: Date = .now) -> [UsageAccount] {
        let rows: [(AIProvider, String, String, Double?, Double?, TimeInterval)] = [
            (.claude, "Personal", "Max 5x", 84, 52, 12 * 60),
            (.chatGPT, "Personal", "Plus", 31, 24, 2 * 60),
            (.claude, "Work", "Pro", 48, 73, 4 * 60 * 60),
            (.chatGPT, "Research", "Plus", nil, nil, 0)
        ]
        return rows.enumerated().map { index, row in
            let observed: Date? = row.3 == nil ? nil : now.addingTimeInterval(-row.5)
            let sessionReset: Date? = row.3 == nil ? nil : now.addingTimeInterval(index == 2 ? -60 : (index == 0 ? 6000 : 11400))
            let session = QuotaReading(usedPercent: row.3, observedAt: observed, resetsAt: sessionReset, source: .sample)
            let weekly = QuotaReading(usedPercent: row.4, observedAt: observed, resetsAt: row.4 == nil ? nil : now.addingTimeInterval(Double(3 + index) * 86400), source: .sample)
            let values = index == 0 ? [12.0, 29, 47, 68, 84] : [4.0, 8, 14, 22, 31]
            let history: [QuotaObservation] = index < 2 ? values.enumerated().map { position, value in
                .init(date: observed!.addingTimeInterval(Double(position - 4) * 1200), period: .session, usedPercent: value, source: .sample)
            } : []
            // Illustrative demo buckets, not claims about current plan entitlements.
            let models: [ModelQuotaLimit]
            if index == 0 {
                models = [
                    .init(id: "demo-sonnet-weekly", modelName: "Sonnet", windowLabel: "Weekly", reading: .init(usedPercent: 76, observedAt: observed, resetsAt: weekly.resetsAt, source: .sample)),
                    .init(id: "demo-opus-weekly", modelName: "Opus", windowLabel: "Weekly", reading: .init(usedPercent: 39, observedAt: observed, resetsAt: weekly.resetsAt, source: .sample))
                ]
            } else if index == 1 {
                models = [.init(id: "demo-reasoning-daily", modelName: "Reasoning model", windowLabel: "Daily", reading: .init(usedPercent: nil, observedAt: observed, resetsAt: now.addingTimeInterval(8 * 3600), source: .sample), count: .init(used: 18, limit: 50, unit: .messages))]
            } else { models = [] }
            return UsageAccount(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!, provider: row.0, alias: row.1, plan: row.2, session: session, weekly: weekly, history: history, modelLimits: models)
        }
    }
}
