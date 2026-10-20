import SwiftUI
import WidgetKit

@main
struct HeadroomApp: App {
    @UIApplicationDelegateAdaptor(HeadroomAppDelegate.self) private var appDelegate
    @StateObject private var store = HeadroomRuntime.shared.store
    @StateObject private var background = HeadroomRuntime.shared.background
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).environmentObject(background).tint(HeadroomStyle.teal)
                .onOpenURL { url in store.openAccount(from: url) }
                .task {
                    background.updateAvailability()
                    while !Task.isCancelled {
                        if scenePhase == .active { store.refresh(force: false) }
                        try? await Task.sleep(for: .seconds(60))
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { background.updateAvailability(); store.refresh(force: false) }
                    else if phase == .background { store.stopForegroundRefreshing(); background.schedule() }
                }
        }
    }
}


struct RootView: View {
    @EnvironmentObject private var store: UsageStore
    @State private var selectedTab = 0
    @State private var sheet: AppSheet?
    @State private var deepLinkedAccount: UUID?

    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        _selectedTab = State(initialValue: arguments.contains("--preview-activity") ? 1 : arguments.contains("--preview-accounts") ? 2 : 0)
        _sheet = State(initialValue: arguments.contains("--preview-widgets") ? .widgets : nil)
        if let flag = arguments.firstIndex(of: "--preview-account"), arguments.indices.contains(flag + 1) {
            _deepLinkedAccount = State(initialValue: UUID(uuidString: arguments[flag + 1]))
        }
        #endif
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            OverviewView(showWidgets: { sheet = .widgets }, showSettings: { sheet = .settings })
                .tabItem { Label("Overview", systemImage: "square.grid.2x2") }.tag(0)
            ActivityView().tabItem { Label("Activity", systemImage: "chart.bar.xaxis") }.tag(1)
            AccountsView().tabItem { Label("Accounts", systemImage: "person.2") }.tag(2)
        }
        .overlay(alignment: .bottomLeading) { ProviderBrowserHosts(registry: store.browsers, visibleID: store.visibleBrowserID) }
        .sheet(item: $sheet) { item in
            NavigationStack {
                if item == .widgets { WidgetGalleryView() } else { SettingsView() }
            }
        }
        .sheet(item: Binding(get: { deepLinkedAccount.map(AccountRoute.init) }, set: { deepLinkedAccount = $0?.id })) { route in
            NavigationStack { AccountDetailView(accountID: route.id).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { deepLinkedAccount = nil } } } }
        }
        .onChange(of: store.requestedAccount) { _, id in
            deepLinkedAccount = id
            store.requestedAccount = nil
        }
        .onChange(of: store.requestedDestination) { _, destination in
            guard let destination else { return }
            sheet = destination == "widgets" ? .widgets : nil
            if destination == "overview" { selectedTab = 0 }
            if destination == "activity" { selectedTab = 1 }
            if destination == "accounts" { selectedTab = 2 }
            store.requestedDestination = nil
        }
        .alert("Headroom", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK", role: .cancel) { store.message = nil }
        } message: { Text(store.message ?? "") }
    }
}

private enum AppSheet: String, Identifiable { case widgets, settings; var id: String { rawValue } }
private struct AccountRoute: Identifiable { let id: UUID }
