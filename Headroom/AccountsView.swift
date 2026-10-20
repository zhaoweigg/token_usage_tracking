import SwiftUI

struct AccountsView: View {
    @EnvironmentObject private var store: UsageStore
    @State private var showAdd = false
    @State private var pendingDeletion: UUID?
    var body: some View {
        NavigationStack {
            List {
                ForEach(AIProvider.allCases) { provider in
                    Section(provider.name) {
                        ForEach(store.accounts.filter { $0.provider == provider }) { account in
                            NavigationLink(value: account.id) {
                                Label {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(account.alias)
                                        Text("\(account.plan) · \(account.connectionLabel)").font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: { Image(systemName: provider.symbol).foregroundStyle(HeadroomStyle.teal) }
                            }
                        }.onDelete { offsets in
                            if let offset = offsets.first { pendingDeletion = store.accounts.filter { $0.provider == provider }[offset].id }
                        }
                    }
                }
                Section { Button("Add account", systemImage: "plus") { showAdd = true }.accessibilityIdentifier("add-account-button") }
            }
            .overlay { if store.accounts.isEmpty { ContentUnavailableView("Connect your accounts", systemImage: "person.crop.circle.badge.plus", description: Text("Add Claude and ChatGPT accounts to start tracking their usage.")) .allowsHitTesting(false) } }
            .navigationTitle("Accounts")
            .navigationDestination(for: UUID.self) { AccountDetailView(accountID: $0) }
            .sheet(isPresented: $showAdd) { NavigationStack { AddAccountView() } }
            .confirmationDialog("Remove this account and its local history?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
                Button("Remove account", role: .destructive) {
                    if let id = pendingDeletion { store.delete(id) }
                    pendingDeletion = nil
                }
            }
        }
    }
}

struct AddAccountView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.dismiss) private var dismiss
    @State private var provider = AIProvider.claude
    @State private var alias = ""
    @State private var browser: ProviderBrowser?
    @State private var showConnection = false

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $provider) { ForEach(AIProvider.allCases) { Text($0.name).tag($0) } }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("provider-picker")
                TextField("Account label (optional)", text: $alias).accessibilityIdentifier("account-alias-field")
            }
            Section {
                Button("Sign in on \(provider.name)", systemImage: "person.crop.circle.badge.checkmark") {
                    browser = store.browsers.browser(id: UUID(), provider: provider)
                    store.visibleBrowserID = browser?.id
                    showConnection = true
                }.accessibilityIdentifier("sign-in-provider-button")
            } footer: {
                Text("Sign in with your iPhone’s browser, then return to verify and connect your reported usage. Each account stays separate.")
            }
        }
        .navigationTitle("Connect account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .navigationDestination(isPresented: $showConnection) {
            if let browser { ProviderConnectionView(browser: browser, alias: alias, onConnected: { dismiss() }) }
        }
    }
}

struct ManualReadingView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.dismiss) private var dismiss
    let accountID: UUID
    @State private var period = QuotaPeriod.session
    @State private var percent = ""
    @State private var observedAt = Date()
    @State private var hasReset = false
    @State private var resetsAt = Date().addingTimeInterval(3600)
    private var validPercent: Double? {
        guard let value = Double(percent), value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }
    var body: some View {
        Form {
            Section {
                Picker("Quota window", selection: $period) { ForEach(QuotaPeriod.allCases) { Text($0.name).tag($0) } }
                TextField("Percentage used (0–100)", text: $percent).keyboardType(.decimalPad).accessibilityIdentifier("percentage-field")
                DatePicker("Observed", selection: $observedAt, in: ...Date())
                Toggle("Include reset time", isOn: $hasReset)
                if hasReset { DatePicker("Next reset", selection: $resetsAt) }
            }
            Section("Preview") {
                Text(validPercent.map { "\(Int($0))% used · \(100 - Int($0))% left" } ?? "Enter a percentage between 0 and 100.")
                Text("Only this window is updated. Other readings keep their original observation times.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Record reading").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if let value = validPercent { store.record(accountID: accountID, period: period, percent: value, reset: hasReset ? resetsAt : nil, observedAt: observedAt); dismiss() }
                }.disabled(validPercent == nil)
            }
        }
    }
}
