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
                Text("v\(HeadroomVersion.display)").font(.system(size: 8)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityIdentifier("widget-version-label")
            }
        }.unredacted()
    }

    private func message(title: String, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Headroom", systemImage: symbol).font(.caption.weight(.semibold))
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct WidgetRefreshButton: View {
    let accountIDs: [UUID]
    var body: some View {
        Button(intent: RefreshUsageIntent(accountIDs: accountIDs)) {
            Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(HeadroomStyle.teal)
            .accessibilityLabel("Refresh usage").accessibilityIdentifier("widget-refresh-button")
    }
}

enum HeadroomStyle {
    static let teal = Color(red: 0.08, green: 0.42, blue: 0.35)
    static let warning = Color.orange
}

struct QuotaBar: View {
    let value: Double?
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill((value ?? 0) >= 80 ? .orange : HeadroomStyle.teal)
                    .frame(width: geometry.size.width * (min(100, max(0, value ?? 0)) / 100))
            }
        }
        .frame(height: 5)
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
    private var stale: Bool { accounts.contains { date.timeIntervalSince($0.lastSyncedAt ?? .distantPast) > 900 } }
    private var statusTitle: String {
        if let refreshStatus, refreshStatus.outcome != .updated,
           refreshStatus.completedAt >= (accounts.compactMap(\.lastSyncedAt).min() ?? .distantPast) { return refreshStatus.title }
        return stale ? "Needs refresh" : "Updated"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: detailed ? 7 : 5) {
            HStack {
                Label("Headroom", systemImage: "waveform.path").font(.caption.weight(.semibold))
                Spacer()
                Text(statusTitle).font(.system(size: 9)).foregroundStyle(stale ? Color.orange : Color.secondary)
                if interactive && accounts.contains(where: \.supportsBackgroundRefresh) {
                    WidgetRefreshButton(accountIDs: accounts.map(\.id))
                }
            }
            ForEach(Array(accounts.prefix(4))) { account in
                let displayedPeriod = account.displayPeriod(preferred: period)
                let reading = account.reading(for: displayedPeriod)
                let value = reading.widgetPercent(at: date)
                if detailed {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(account.title).font(.caption.weight(.semibold))
                            Spacer()
                        }
                        HStack(spacing: 16) {
                            ForEach(account.reportedQuotaPeriods) { window in
                                let item = account.reading(for: window)
                                let number = item.widgetPercent(at: date)
                                VStack(spacing: 3) {
                                    HStack {
                                        Text(account.windowName(for: window)).foregroundStyle(.secondary)
                                        Spacer()
                                        Text(number.map { "\(Int($0))%" } ?? "—").monospacedDigit()
                                    }.font(.caption2)
                                    QuotaBar(value: number)
                                    ReadingAge(reading: item, date: date).font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if account.id != accounts.prefix(4).last?.id { Divider() }
                } else {
                    HStack(spacing: 7) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.title).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.8)
                            Text(account.windowName(for: displayedPeriod)).font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 2)
                        Text(value.map { "\(Int($0))%" } ?? "—").font(.system(size: 15, weight: .semibold)).monospacedDigit()
                        ReadingAge(reading: reading, date: date).font(.system(size: 9)).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.75).frame(width: 64, alignment: .trailing)
                    }
                }
            }
            if accounts.isEmpty { Text("Open Headroom to add accounts.").font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            Text(accounts.count > 4 ? "+\(accounts.count - 4) more · open Headroom" : "Last captured readings · \(detailed ? "age per window" : "age per account")").font(.system(size: 9)).foregroundStyle(.secondary)
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
            Text("Reset expected · awaiting update").foregroundStyle(.orange)
        } else if let resets = reading.resetsAt {
            HStack(spacing: 3) {
                Text("Resets")
                Text(resets, style: .relative).monospacedDigit()
            }.foregroundStyle(.secondary)
        } else { Text("Reset not provided").foregroundStyle(.secondary) }
    }
}
