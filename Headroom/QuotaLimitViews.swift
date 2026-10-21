import SwiftUI

struct QuotaStatusView: View {
    let title: String
    let reading: QuotaReading
    var count: QuotaCount? = nil
    var date: Date = .now
    var compact = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var value: Double? { reading.widgetPercent(at: date) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.apricot(.caption, weight: .medium)).layoutPriority(1)
                if reading.observedAt != nil, reading.source != .provider {
                    Text(reading.source == .sample ? "Demo" : reading.source == .manual ? "Manual" : "Provider")
                        .font(.apricot(.caption2)).foregroundStyle(HeadroomStyle.secondaryText)
                }
                Spacer(minLength: 8)
                Text(value.map { "\(Int($0))% used" } ?? (reading.state(at: date) == .awaitingReset ? "Awaiting update" : "Not available"))
                    .font(.apricot(compact ? .caption : .headline, weight: .semibold)).monospacedDigit()
            }
            QuotaBar(value: value, height: compact ? 4 : 7)
            if let label = count?.label {
                Text(reading.state(at: date) == .awaitingReset ? "Last recorded: \(label)" : label)
                    .font(.apricot(.caption)).foregroundStyle(HeadroomStyle.secondaryText)
            }
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 3) {
                    ResetLabel(reading: reading, date: date)
                    ReadingAge(reading: reading, date: date)
                }.font(.apricot(.caption2)).foregroundStyle(HeadroomStyle.secondaryText)
            } else {
                HStack(alignment: .top) {
                    ResetLabel(reading: reading, date: date)
                    Spacer(minLength: 8)
                    ReadingAge(reading: reading, date: date).lineLimit(1).minimumScaleFactor(0.8)
                }.font(.apricot(.caption2)).foregroundStyle(HeadroomStyle.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ModelLimitStatusView: View {
    let limit: ModelQuotaLimit
    var body: some View {
        QuotaStatusView(title: limit.title, reading: limit.quotaReading, count: limit.count, compact: true)
            .accessibilityIdentifier("model-limit-\(limit.id)")
    }
}
