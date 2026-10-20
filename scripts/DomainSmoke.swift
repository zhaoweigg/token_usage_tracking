import Foundation

@main
enum DomainSmoke {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var passed: [String] = []
        precondition(QuotaReading.unavailable.displayPercent == nil)
        precondition(QuotaReading.unavailable.widgetPercent(at: now) == nil)
        passed.append("unknown stays unavailable")

        let expired = QuotaReading(usedPercent: 84, observedAt: now.addingTimeInterval(-60), resetsAt: now.addingTimeInterval(-1), source: .manual)
        precondition(expired.state(at: now) == .awaitingReset)
        precondition(expired.widgetPercent(at: now) == nil && expired.displayPercent == 84)
        passed.append("reset passage preserves historical value without inventing capacity")

        let old = QuotaReading(usedPercent: 31, observedAt: now.addingTimeInterval(-3600), resetsAt: now.addingTimeInterval(3600), source: .manual)
        precondition(old.state(at: now) == .stale && old.widgetPercent(at: now) == 31)
        precondition(old.observedAt == now.addingTimeInterval(-3600))
        passed.append("stale value and timestamp preserved")

        var accounts = UsageFixtures.accounts(now: now)
        let original = accounts
        accounts[0].record(.init(usedPercent: 90, observedAt: now, resetsAt: nil, source: .manual), for: .weekly)
        precondition(accounts[0].session == original[0].session)
        precondition(accounts[1] == original[1])
        precondition(accounts[0].weekly.usedPercent == 90)
        passed.append("partial update remains account and window scoped")

        let decoded = try JSONDecoder().decode([UsageAccount].self, from: JSONEncoder().encode(accounts))
        precondition(decoded == accounts)
        passed.append("account identity and history survive persistence round trip")

        let invalid = QuotaReading(usedPercent: .nan, observedAt: now, resetsAt: nil, source: .manual)
        precondition(invalid.displayPercent == nil)
        let bounds = QuotaReading(usedPercent: 120, observedAt: now, resetsAt: nil, source: .manual)
        precondition(bounds.displayPercent == 100)
        passed.append("nonfinite input unavailable and display bounds enforced")

        let modern = UsageFixtures.accounts(now: now)[0]
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(modern)) as! [String: Any]
        legacy.removeValue(forKey: "modelLimits")
        let migrated = try JSONDecoder().decode(UsageAccount.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(migrated.modelLimits.isEmpty && migrated.weekly == modern.weekly && migrated.history == modern.history)
        passed.append("legacy accounts migrate without losing weekly values or history")

        var changed = modern
        var model = modern.modelLimits[0]
        model.reading = .init(usedPercent: 91, observedAt: now, resetsAt: nil, source: .manual)
        changed.recordModelLimit(model)
        precondition(changed.session == modern.session && changed.weekly == modern.weekly)
        precondition(changed.modelLimits[1] == modern.modelLimits[1] && changed.modelLimits.count == modern.modelLimits.count)
        precondition(changed.history.last?.modelLimitID == model.id && changed.history.last?.period == nil)
        let persistedModel = try JSONDecoder().decode(UsageAccount.self, from: JSONEncoder().encode(changed))
        precondition(persistedModel == changed)
        passed.append("model updates and history remain isolated and persist")

        let counted = ModelQuotaLimit(modelName: "Example", windowLabel: "Daily", reading: .init(usedPercent: nil, observedAt: now, resetsAt: nil, source: .manual), count: .init(used: 18, limit: 50, unit: .messages))
        precondition(counted.quotaReading.displayPercent == 36 && counted.count?.unit == .messages)
        precondition(QuotaCount(used: 1, limit: 0, unit: .tokens).percent == nil)
        precondition(QuotaCount(used: .infinity, limit: 100, unit: .tokens).percent == nil)
        precondition(QuotaCount(used: 1, limit: .infinity, unit: .tokens).percent == nil)
        precondition(modern.modelLimits[0].count == nil)
        passed.append("counts normalize to percentages without inventing tokens")

        precondition(model.scopedID(accountID: modern.id) != model.scopedID(accountID: original[1].id))
        model.reading.resetsAt = now.addingTimeInterval(-1)
        precondition(model.quotaReading.widgetPercent(at: now) == nil && modern.weekly.widgetPercent(at: now) == 52)
        passed.append("model identity and reset handling remain account scoped")
        let data = try JSONSerialization.data(withJSONObject: ["passed": passed.count, "checks": passed], options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
