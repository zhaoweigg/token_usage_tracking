import SwiftUI
import WidgetKit

private enum PreviewSize: String, CaseIterable, Identifiable {
    case medium = "Medium", large = "Large"
    var id: String { rawValue }
    var height: CGFloat { self == .large ? 340 : 160 }
}

struct WidgetGalleryView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.dismiss) private var dismiss
    @State private var size = PreviewSize.medium

    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "--preview-widget-size"), arguments.indices.contains(flag + 1),
           let requestedSize = PreviewSize.allCases.first(where: { String(describing: $0) == arguments[flag + 1] }) {
            _size = State(initialValue: requestedSize)
        }
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("YOUR USAGE, AT A GLANCE").font(.caption2.weight(.semibold)).tracking(1.3).foregroundStyle(HeadroomStyle.teal)
                Text("Live overview").font(.title2.weight(.semibold))
                Picker("Size", selection: $size) {
                    ForEach(PreviewSize.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("widget-size-picker")
                preview
                VStack(alignment: .leading, spacing: 10) {
                    Text("Add Live overview").font(.headline)
                    Text("Touch and hold your Home Screen, open the widget gallery, and choose Headroom → Live overview. Pick Medium or Large. Your saved accounts appear automatically.")
                    Text("Medium shows weekly usage. Large shows all reported account windows. The widget includes its version and a Refresh button for connected accounts.")
                    Text("Widgets show the latest saved readings and their age. Successful background refresh also updates the widget.").foregroundStyle(.secondary)
                }.font(.subheadline)
                if let warning = store.widgetWarning { Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            }.padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Widgets")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    private var preview: some View {
        VStack(spacing: 12) {
            WidgetDataContent(state: store.accounts.isEmpty ? .empty : .ready) {
                OverviewWidgetContent(accounts: store.accounts, period: .weekly, date: .now, detailed: size == .large)
            }
            .modifier(WidgetPreviewTestEnvironment())
            .padding(14)
            .frame(width: 320, height: size.height)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
            .accessibilityIdentifier("native-widget-preview")
            .accessibilityElement(children: .contain)
            Text("Home Screen preview").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(HeadroomStyle.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 24))
    }
}

private struct WidgetPreviewTestEnvironment: ViewModifier {
    func body(content: Content) -> some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-widget-privacy") {
            // Regression coverage: host styling must not replace saved content.
            content.redacted(reason: [.privacy, .placeholder])
        } else { content }
        #else
        content
        #endif
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var background: BackgroundRefreshController
    @State private var widgetRead: WidgetReadDiagnostic?
    @State private var widgetRefresh: WidgetRefreshStatus?
    var body: some View {
        List {
            Section {
                NavigationLink { WidgetGalleryView() } label: { Label("Home Screen widgets", systemImage: "square.grid.2x2") }
            }
            Section("Sync") {
                LabeledContent("Storage", value: "On this iPhone")
                LabeledContent("Provider sessions", value: "Separate per account")
                Text("Usage refreshes when Headroom opens and every minute while it stays open. Pull to refresh whenever needed. Provider cooldowns still apply.")
                Text("Widgets show the latest saved readings and their age. Successful background sync also updates their saved data.")
            }
            Section {
                Toggle("Background refresh", isOn: $background.enabled).accessibilityIdentifier("background-refresh-toggle")
                LabeledContent("Status", value: background.statusText)
                if let date = background.lastCompletedAt {
                    HStack { Text("Last background check"); Spacer(); Text(date, style: .relative).foregroundStyle(.secondary) }
                }
                else { LabeledContent("Last background check", value: "Not run yet") }
                if let outcome = background.lastOutcome { Text(outcome.title).font(.caption).foregroundStyle(.secondary) }
                if background.systemStatus != .available {
                    Button("Open iPhone Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            } header: { Text("While Headroom is closed") } footer: {
                Text("Headroom requests the next available background opportunity, with no added delay. iOS chooses when it runs and may wait much longer. Low Power Mode, Background App Refresh settings, or force-quitting can prevent updates. Tap Refresh on a Home Screen widget for an on-demand check without opening the app. Provider requests are limited to once per minute per account, or longer during cooldowns. Embedded website sign-ins still require opening the app.")
            }
            Section("Coverage") {
                Text("Claude shows shared subscription limits, including model pools when reported. ChatGPT shows its reported Codex allowance. Exact token totals and separate chat limits may be unavailable.")
                Text("Provider website interfaces may change. If a session expires, open the account and sign in again.")
            }.font(.subheadline)
            Section("Widget refresh") {
                if let widgetRefresh {
                    LabeledContent("Result", value: widgetRefresh.title)
                    HStack { Text("Last check"); Spacer(); Text(widgetRefresh.completedAt, style: .relative).foregroundStyle(.secondary) }
                    LabeledContent("Accounts updated", value: "\(widgetRefresh.updated)")
                } else { Text("No widget check recorded yet").foregroundStyle(.secondary) }
                Text("The widget checks providers directly during its scheduled updates and when you tap Refresh. Automatic timing is controlled by iOS.").font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Version", value: HeadroomVersion.display)
                    .accessibilityIdentifier("settings-version-label")
                if let widgetRead {
                    LabeledContent("Widget version", value: widgetRead.version)
                    HStack { Text("Last widget load"); Spacer(); Text(widgetRead.date, style: .relative).foregroundStyle(.secondary) }
                    LabeledContent("Accounts read by widget", value: "\(widgetRead.accountCount)")
                }
            }
        }
        .navigationTitle("Settings")
        .onAppear { background.updateAvailability(); widgetRead = WidgetDiagnostics.latest(); widgetRefresh = WidgetRefreshStatus.load() }
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}
