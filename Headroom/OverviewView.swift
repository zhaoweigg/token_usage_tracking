import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var store: UsageStore
    @State private var filter: AIProvider?
    @State private var showAdd = false
    let showWidgets: () -> Void
    let showSettings: () -> Void
    private var visible: [UsageAccount] { store.accounts.filter { filter == nil || $0.provider == filter } }
    private var oldestSync: Date? { visible.compactMap(\.lastSyncedAt).min() }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let oldestSync {
                        HStack(spacing: 6) {
                            Circle().fill(HeadroomStyle.accent).frame(width: 5, height: 5)
                            Text("Updated")
                            Text(oldestSync, style: .relative)
                        }.font(.apricot(.caption2)).foregroundStyle(HeadroomStyle.secondaryText)
                    }
                    ProviderFilter(selection: $filter)
                    HStack {
                        Text("\(visible.count) \(visible.count == 1 ? "account" : "accounts")")
                        Spacer()
                        Text("Subscription limits")
                    }.font(.apricot(.caption2)).foregroundStyle(HeadroomStyle.secondaryText)
                    ForEach(visible) { account in
                        NavigationLink(value: account.id) { AccountCard(account: account) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("account-\(account.id.uuidString)")
                    }
                    if visible.isEmpty {
                        VStack(spacing: 15) {
                            Image(systemName: "chart.bar.xaxis").font(.system(size: 36, weight: .light))
                                .foregroundStyle(HeadroomStyle.accent)
                            Text("Your usage starts here").font(.apricot(.title3, weight: .semibold))
                            Text("Connect your Claude and ChatGPT accounts to see their subscription limits.")
                                .font(.apricot(.subheadline)).foregroundStyle(HeadroomStyle.secondaryText)
                                .multilineTextAlignment(.center)
                            Button("Connect account", systemImage: "plus") { showAdd = true }
                                .font(.apricot(.subheadline, weight: .semibold))
                                .buttonStyle(.borderedProminent).foregroundStyle(HeadroomStyle.onAccent)
                                .controlSize(.large).accessibilityIdentifier("overview-connect-button")
                        }.frame(maxWidth: .infinity, minHeight: 330).padding(.horizontal, 15)
                    } else {
                        Text("Some limits may share an allowance.")
                            .font(.apricot(.caption2)).foregroundStyle(HeadroomStyle.secondaryText)
                    }
                    Text("Headroom \(HeadroomVersion.display)")
                        .font(.apricot(.caption2)).foregroundStyle(HeadroomStyle.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityIdentifier("app-version-label")
                }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 20)
            }
            .background(HeadroomStyle.background)
            .apricotScreen()
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

private struct ProviderFilter: View {
    @Binding var selection: AIProvider?
    var body: some View {
        HStack(spacing: 4) {
            option("All", provider: nil)
            ForEach(AIProvider.allCases) { option($0.name, provider: $0) }
        }
        .padding(4)
        .background(HeadroomStyle.tint, in: RoundedRectangle(cornerRadius: 13))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter providers")
    }
    private func option(_ label: String, provider: AIProvider?) -> some View {
        Button { selection = provider } label: {
            Text(label).font(.apricot(.caption, weight: selection == provider ? .semibold : .regular))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(selection == provider ? HeadroomStyle.primaryText : HeadroomStyle.secondaryText)
                .background(selection == provider ? HeadroomStyle.surface : .clear, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityAddTraits(selection == provider ? .isSelected : [])
            .accessibilityIdentifier("provider-filter-\(provider?.rawValue ?? "all")")
    }
}

struct AccountCard: View {
    let account: UsageAccount
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: account.provider.symbol).font(.system(size: 20)).foregroundStyle(HeadroomStyle.accent)
                    .frame(width: 36, height: 36).background(HeadroomStyle.tint, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.provider.name).font(.apricot(.subheadline, weight: .bold))
                    Text("\(account.alias) · \(account.plan)").font(.apricot(.caption2))
                        .foregroundStyle(HeadroomStyle.secondaryText).multilineTextAlignment(.leading)
                        .lineLimit(2).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.apricot(.caption)).foregroundStyle(HeadroomStyle.secondaryText)
            }
            ForEach(account.reportedQuotaPeriods) { period in
                QuotaStatusView(title: account.windowName(for: period), reading: account.reading(for: period))
                    .accessibilityIdentifier("account-limit-\(period.rawValue)")
            }
            if !account.modelLimits.isEmpty {
                Rectangle().fill(HeadroomStyle.separator).frame(height: 1)
                Text("Model limits").font(.apricot(.caption2, weight: .medium)).foregroundStyle(HeadroomStyle.secondaryText)
                ForEach(account.modelLimits) { ModelLimitStatusView(limit: $0) }
            }
            Text(account.coverage)
                .font(.apricot(.caption2)).foregroundStyle(HeadroomStyle.secondaryText)
            if let error = account.syncError { Label(error, systemImage: "exclamationmark.triangle").font(.apricot(.caption)).foregroundStyle(HeadroomStyle.warning) }
        }
        .padding(18)
        .foregroundStyle(HeadroomStyle.primaryText)
        .background(HeadroomStyle.surface, in: RoundedRectangle(cornerRadius: 22))
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
                    Group {
                        Section("Connection") {
                            Label(account.connectionLabel, systemImage: account.needsSignIn ? "exclamationmark.shield" : account.isConnected ? "checkmark.shield" : "person.crop.circle.badge.questionmark")
                            if let email = account.email { LabeledContent("Account", value: email) }
                            if let workspace = account.workspaceName { LabeledContent("Workspace", value: workspace) }
                            if let date = account.lastSyncedAt { HStack { Text("Last synced"); Spacer(); Text(date, style: .relative).foregroundStyle(HeadroomStyle.secondaryText) } }
                            if let error = account.syncError { Text(error).font(.apricot(.caption)).foregroundStyle(HeadroomStyle.warning) }
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
                                .font(.apricot(.caption)).foregroundStyle(HeadroomStyle.secondaryText)
                        }
                        Section("Token activity") {
                            Label("Token counts unavailable", systemImage: "number")
                            Text("Quota percentages cannot be converted into exact tokens.").font(.apricot(.caption)).foregroundStyle(HeadroomStyle.secondaryText)
                        }
                        Section("Manual fallback") {
                            Button("Record a reading manually", systemImage: "square.and.pencil") { showManual = true }
                            Button("Record a model limit", systemImage: "slider.horizontal.3") { showModelManual = true }
                        }
                    }.listRowBackground(HeadroomStyle.surface)
                }
                .apricotScreen()
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
