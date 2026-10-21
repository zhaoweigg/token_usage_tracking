import SwiftUI
import WidgetKit

enum WidgetSchedule {
    static func dates(accounts: [UsageAccount], now: Date) -> [Date] {
        var changes: [Date] = []
        let cutoff = now.addingTimeInterval(86400)
        for account in accounts {
            for reading in account.allReadings {
                if let observed = reading.observedAt { changes.append(observed.addingTimeInterval(901)) }
                if let reset = reading.resetsAt { changes.append(reset.addingTimeInterval(1)) }
            }
        }
        changes = changes.filter { $0 > now && $0 < cutoff }.sorted()
        var dates = [now]
        for change in changes where change.timeIntervalSince(dates.last!) >= 300 { dates.append(change) }
        return dates
    }
}

struct LiveOverviewEntry: TimelineEntry {
    var date: Date
    var accounts: [UsageAccount]
    var state: WidgetDataState
    var refreshStatus: WidgetRefreshStatus?
}

struct LiveOverviewProvider: TimelineProvider {
    // This widget always covers all accounts, so its synchronous placeholder can
    // safely use the same saved snapshot without resolving account entities.
    func placeholder(in context: Context) -> LiveOverviewEntry { entry(phase: "Placeholder") }
    func getSnapshot(in context: Context, completion: @escaping (LiveOverviewEntry) -> Void) { completion(entry(phase: "Snapshot")) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LiveOverviewEntry>) -> Void) {
        Task { @MainActor in
            await WidgetUsageRefresh().refresh(automatic: true)
            let current = entry(phase: "Timeline")
            let entries = WidgetSchedule.dates(accounts: current.accounts, now: current.date).map { date in
                var entry = current; entry.date = date; return entry
            }
            completion(Timeline(entries: entries, policy: .after(current.date.addingTimeInterval(5 * 60))))
        }
    }
    private func entry(phase: String) -> LiveOverviewEntry {
        let result = WidgetSnapshotStore.loadResult()
        WidgetDiagnostics.record(kind: "HeadroomLiveOverview", phase: phase, state: result.state, accountCount: result.snapshot.accounts.count)
        return .init(date: .now, accounts: result.snapshot.accounts, state: result.state, refreshStatus: WidgetRefreshStatus.load())
    }
}

struct LiveOverviewWidget: Widget {
    let kind = "HeadroomLiveOverview"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LiveOverviewProvider()) { entry in
            LiveOverviewEntryView(entry: entry)
                .containerBackground(HeadroomStyle.surface, for: .widget)
                .widgetURL(URL(string: "headroom://overview"))
        }
        .configurationDisplayName("Live overview")
        .description("Show all saved accounts immediately, without account configuration. Includes the widget version.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

private struct LiveOverviewEntryView: View {
    let entry: LiveOverviewEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        WidgetDataContent(state: entry.state) {
            OverviewWidgetContent(accounts: entry.accounts, period: .weekly, date: entry.date, detailed: family == .systemLarge, interactive: true, refreshStatus: entry.refreshStatus)
        }
    }
}

@main
struct HeadroomWidgetBundle: WidgetBundle {
    var body: some Widget {
        LiveOverviewWidget()
    }
}
