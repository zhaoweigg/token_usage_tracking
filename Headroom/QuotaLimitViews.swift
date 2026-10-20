import SwiftUI

struct QuotaStatusView: View {
    let title: String
    let reading: QuotaReading
    var count: QuotaCount? = nil
    var date: Date = .now

    private var value: Double? { reading.widgetPercent(at: date) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.caption.weight(.medium))
                if reading.observedAt != nil {
                    Text(reading.source == .sample ? "Demo" : reading.source == .manual ? "Manual" : "Provider")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(value.map { "\(Int($0))% used" } ?? (reading.state(at: date) == .awaitingReset ? "Awaiting update" : "Not available"))
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            QuotaBar(value: value)
            if let label = count?.label {
                Text(reading.state(at: date) == .awaitingReset ? "Last recorded: \(label)" : label)
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top) {
                ResetLabel(reading: reading, date: date)
                Spacer(minLength: 8)
                ReadingAge(reading: reading, date: date).lineLimit(1).minimumScaleFactor(0.8)
            }.font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ModelLimitStatusView: View {
    let limit: ModelQuotaLimit
    var body: some View {
        QuotaStatusView(title: limit.title, reading: limit.quotaReading, count: limit.count)
            .accessibilityIdentifier("model-limit-\(limit.id)")
    }
}
