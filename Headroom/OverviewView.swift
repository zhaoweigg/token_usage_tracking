import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var store: UsageStore
    @State private var filter: AIProvider?
    @State private var showAdd = false
    let showWidgets: () -> Void
    let showSettings: () -> Void
    private var visible: [UsageAccount] { store.accounts.filter { filter == nil || $0.provider == filter } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("USAGE, ON YOUR IPHONE").font(.caption2.weight(.semibold)).tracking(1.5).foregroundStyle(HeadroomStyle.teal)
                    Picker("Provider", selection: $filter) {
                        Text("All").tag(AIProvider?.none)
                        ForEach(AIProvider.allCases) { Text($0.name).tag(Optional($0)) }
                    }.pickerStyle(.segmented)
                    HStack {
                        Text("\(visible.count) accounts")
                        Spacer()
                        Text("Subscription allowance")
                    }.font(.caption).foregroundStyle(.secondary)
                    ForEach(visible) { account in
                        NavigationLink(value: account.id) { AccountCard(account: account) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("account-\(account.id.uuidString)")
                    }
                    if visible.isEmpty {
                        ContentUnavailableView {
                            Label("Your usage starts here", systemImage: "chart.bar.xaxis")
                        } description: {
                            Text("Connect your Claude and ChatGPT accounts to see their subscription limits.")
                        } actions: {
                            Button("Connect account", systemImage: "plus") { showAdd = true }
                                .buttonStyle(.borderedProminent).accessibilityIdentifier("overview-connect-button")
                        }
                    }
                    Text("Headroom \(HeadroomVersion.display)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityIdentifier("app-version-label")
                }.padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Overview")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if store.isRefreshing { ProgressView().accessibilityLabel("Syncing usage") }
                    Button("Refresh", systemImage: "arrow.clockwise") { store.refresh() }.disabled(store.isRefreshing || store.accounts.isEmpty)
                    Button("Widgets", systemImage: "square.stack.3d.up") { showWidgets() }.accessibilityIdentifier("widgets-button")
                    Button("Settings", systemImage: "slider.horizontal.3") { showSettings() }
                }
            }
            .navigationDestination(for: UUID.self) { AccountDetailView(accountID: $0) }
            .sheet(isPresented: $showAdd) { NavigationStack { AddAccountView() } }
            .refreshable { await store.refreshAndWait() }
        }
    }
}

struct AccountCard: View {
    let account: UsageAccount
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: account.provider.symbol).font(.title3).foregroundStyle(HeadroomStyle.teal)
                    .frame(width: 34, height: 34).background(HeadroomStyle.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.title).font(.subheadline.weight(.semibold))
                    Text("\(account.plan) · \(account.coverage)").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(account.reportedQuotaPeriods) { period in
                QuotaStatusView(title: account.windowName(for: period), reading: account.reading(for: period))
                    .accessibilityIdentifier("account-limit-\(period.rawValue)")
            }
            if !account.modelLimits.isEmpty {
                Divider()
                Text("Model limits").font(.caption.weight(.semibold)).foregroundStyle(HeadroomStyle.teal)
                ForEach(account.modelLimits) { ModelLimitStatusView(limit: $0) }
            }
            Text("Last captured readings · separate limits may share an allowance")
                .font(.caption2).foregroundStyle(.secondary)
            if let error = account.syncError { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}

struct AccountDetailView: View {
    @EnvironmentObject private var store: UsageStore
    let accountID: UUID
    @State private var showManual = false
    @State private var showConnection = false
    @State private var showModelManual = false
    @State private var connectionBrowser: ProviderBrowser?

    init(accountID: UUID) {
        self.accountID = accountID
        #if DEBUG
        _showModelManual = State(initialValue: ProcessInfo.processInfo.arguments.contains("--preview-model-reading"))
        #endif
    }

    var body: some View {
        Group {
            if let account = store.account(accountID) {
                List {
                    Section("Connection") {
                        Label(account.connectionLabel, systemImage: account.needsSignIn ? "exclamationmark.shield" : account.isConnected ? "checkmark.shield" : "person.crop.circle.badge.questionmark")
                        if let email = account.email { LabeledContent("Account", value: email) }
                        if let workspace = account.workspaceName { LabeledContent("Workspace", value: workspace) }
                        if let date = account.lastSyncedAt { HStack { Text("Last synced"); Spacer(); Text(date, style: .relative).foregroundStyle(.secondary) } }
                        if let error = account.syncError { Text(error).font(.caption).foregroundStyle(.orange) }
                        Button("Refresh usage", systemImage: "arrow.clockwise") { store.refresh(accountID: accountID) }
                            .disabled(!account.isConnected || store.refreshingIDs.contains(accountID))
                        Button(account.isConnected ? "Open sign-in / reconnect" : "Sign in to provider", systemImage: "globe") {
                            store.visibleBrowserID = accountID
                            connectionBrowser = store.browsers.browser(id: accountID, provider: account.provider)
                            showConnection = true
                        }
                    }
                    Section("Subscription allowance") {
                        ForEach(account.reportedQuotaPeriods) { period in
                            QuotaStatusView(title: account.windowName(for: period), reading: account.reading(for: period)).padding(.vertical, 5)
                        }
                    }
                    if !account.modelLimits.isEmpty {
                        Section {
                            ForEach(account.modelLimits) { ModelLimitStatusView(limit: $0).padding(.vertical, 5) }
                        } header: { Text("Model limits") }
                        footer: { Text("Each limit has its own window and may overlap the account allowance.") }
                    }
                    Section("Coverage") {
                        Text(account.coverage)
                        Text(account.provider == .claude ? "The shared Claude allowance can include chat and Claude Code. Only limits returned by the provider are shown." : "These readings cover the reported Codex allowance. Separate ChatGPT chat limits may not be exposed by this usage page.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Token activity") {
                        Label("Token counts unavailable", systemImage: "number")
                        Text("Quota percentages cannot be converted into exact tokens.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Manual fallback") {
                        Button("Record a reading manually", systemImage: "square.and.pencil") { showManual = true }
                        Button("Record a model limit", systemImage: "slider.horizontal.3") { showModelManual = true }
                    }
                }
                .navigationTitle(account.alias)
                .navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $showManual) { NavigationStack { ManualReadingView(accountID: accountID) } }
                .sheet(isPresented: $showModelManual) { NavigationStack { ManualModelLimitView(accountID: accountID) } }
                .sheet(isPresented: $showConnection) {
                    NavigationStack {
                        if let browser = connectionBrowser { ProviderConnectionView(browser: browser, alias: account.alias, onConnected: { showConnection = false }) }
                    }.toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showConnection = false } } }
                }
            } else { ContentUnavailableView("Account removed", systemImage: "person.crop.circle.badge.xmark") }
        }
    }
}
