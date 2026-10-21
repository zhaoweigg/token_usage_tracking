import SwiftUI
import WidgetKit
import AppIntents

struct WidgetDataContent<Content: View>: View {
    var state: WidgetDataState = .ready
    @ViewBuilder var content: () -> Content
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if state != .ready {
                message(title: state.title, detail: state.detail, symbol: "arrow.triangle.2.circlepath")
            } else {
                // Host redaction describes presentation, not snapshot readiness.
                // The owner explicitly requested no masking of widget readings.
                content()
            }
            if [.systemSmall, .systemMedium, .systemLarge].contains(family) {
                Text("v\(HeadroomVersion.display)").font(.apricot(size: 9)).foregroundStyle(HeadroomStyle.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityIdentifier("widget-version-label")
            }
        }.font(.apricot(.caption)).foregroundStyle(HeadroomStyle.primaryText).unredacted()
    }

    private func message(title: String, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Headroom", systemImage: symbol).font(.apricot(.caption, weight: .semibold))
            Text(title).font(.apricot(.headline))
            Text(detail).font(.apricot(.caption)).foregroundStyle(HeadroomStyle.secondaryText)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct WidgetRefreshButton: View {
    let accountIDs: [UUID]
    var body: some View {
        Button(intent: RefreshUsageIntent(accountIDs: accountIDs)) {
            Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(HeadroomStyle.accent)
            .accessibilityLabel("Refresh usage").accessibilityIdentifier("widget-refresh-button")
    }
}

struct QuotaBar: View {
    let value: Double?
    var height: CGFloat = 5
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(HeadroomStyle.track)
                Capsule().fill((value ?? 0) >= 80 ? HeadroomStyle.warning : HeadroomStyle.accent)
                    .frame(width: geometry.size.width * (min(100, max(0, value ?? 0)) / 100))
            }
        }
        .frame(height: height)
        .accessibilityLabel(value.map { "\(Int($0)) percent used" } ?? "Usage unavailable")
    }
}

struct OverviewWidgetContent: View {
    let accounts: [UsageAccount]
    let period: QuotaPeriod
    let date: Date
    var detailed = false
    var interactive = false
    var refreshStatus: WidgetRefreshStatus? = nil
    private var dense: Bool { accounts.count >= 4 }
    private var stale: Bool { accounts.contains { date.timeIntervalSince($0.lastSyncedAt ?? .distantPast) > 900 } }
    private var statusTitle: String {
        if let refreshStatus, refreshStatus.outcome != .updated,
           refreshStatus.completedAt >= (accounts.compactMap(\.lastSyncedAt).min() ?? .distantPast) { return refreshStatus.title }
        return stale ? "Needs refresh" : "Updated"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: dense ? (detailed ? 4 : 2) : (detailed ? 7 : 5)) {
            HStack {
                Label(accounts.count > 4 ? "Headroom · +\(accounts.count - 4) more" : "Headroom", systemImage: "waveform.path")
                    .font(.apricot(.caption, weight: .semibold)).lineLimit(1)
                Spacer()
                Text(statusTitle).font(.apricot(size: 10)).foregroundStyle(stale ? HeadroomStyle.warning : HeadroomStyle.secondaryText)
                if interactive && accounts.contains(where: \.supportsBackgroundRefresh) {
                    WidgetRefreshButton(accountIDs: accounts.map(\.id))
                }
            }
            ForEach(Array(accounts.prefix(4))) { account in
                let displayedPeriod = account.displayPeriod(preferred: period)
                let reading = account.reading(for: displayedPeriod)
                let value = reading.widgetPercent(at: date)
                if detailed {
                    VStack(alignment: .leading, spacing: dense ? 4 : 5) {
                        HStack {
                            Text(account.title).font(.apricot(.caption, weight: .semibold))
                                .lineLimit(1).truncationMode(.middle).minimumScaleFactor(0.85)
                            Spacer()
                        }
                        HStack(spacing: 16) {
                            ForEach(account.reportedQuotaPeriods) { window in
                                let item = account.reading(for: window)
                                let number = item.widgetPercent(at: date)
                                VStack(spacing: dense ? 2 : 3) {
                                    HStack {
                                        Text(account.windowName(for: window)).foregroundStyle(HeadroomStyle.secondaryText)
                                        Spacer()
                                        Text(number.map { "\(Int($0))%" } ?? "—").monospacedDigit()
                                    }.font(.apricot(.caption2))
                                    QuotaBar(value: number, height: dense ? 4 : 5)
                                    ReadingAge(reading: item, date: date).font(.apricot(size: 10)).foregroundStyle(HeadroomStyle.secondaryText)
                                }
                            }
                        }
                    }
                    if account.id != accounts.prefix(4).last?.id { Rectangle().fill(HeadroomStyle.separator).frame(height: 1) }
                } else {
                    VStack(spacing: dense ? 2 : 4) {
                        HStack(spacing: 6) {
                            Text(account.title).font(.apricot(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 2)
                            Text(account.windowName(for: displayedPeriod)).font(.apricot(size: 9)).foregroundStyle(HeadroomStyle.secondaryText)
                            Text(value.map { "\(Int($0))%" } ?? "—").font(.apricot(size: dense ? 12 : 13, weight: .semibold)).monospacedDigit()
                            ReadingAge(reading: reading, date: date).font(.apricot(size: 9)).foregroundStyle(HeadroomStyle.secondaryText)
                                .lineLimit(1).minimumScaleFactor(0.75).frame(width: 52, alignment: .trailing)
                        }
                        QuotaBar(value: value, height: dense ? 2 : 3)
                    }
                }
            }
            if accounts.isEmpty { Text("Open Headroom to add accounts.").font(.apricot(.caption)).foregroundStyle(HeadroomStyle.secondaryText) }
            Spacer(minLength: 0)
            if !dense {
                Text("Last captured readings · \(detailed ? "age per window" : "age per account")")
                    .font(.apricot(size: 9)).foregroundStyle(HeadroomStyle.secondaryText)
            }
        }
    }
}

struct ReadingAge: View {
    let reading: QuotaReading
    let date: Date
    var body: some View {
        if let observed = reading.observedAt {
            // WidgetKit can advance this text between timeline deliveries.
            Text(observed, style: .relative).monospacedDigit()
        } else { Text("Never") }
    }
}

struct ResetLabel: View {
    let reading: QuotaReading
    let date: Date
    var body: some View {
        if reading.state(at: date) == .awaitingReset {
            Text("Reset expected · awaiting update").foregroundStyle(HeadroomStyle.warning)
        } else if let resets = reading.resetsAt {
            HStack(spacing: 3) {
                Text("Resets")
                Text(resets, style: .relative).monospacedDigit()
            }.foregroundStyle(HeadroomStyle.secondaryText)
        } else { Text("Reset not provided").foregroundStyle(HeadroomStyle.secondaryText) }
    }
}
