import SwiftUI
import Charts

struct ActivityView: View {
    @EnvironmentObject private var store: UsageStore
    @State private var selectedID: UUID?
    @State private var showTokens = false
    @State private var period = QuotaPeriod.session
    @State private var modelLimitID: String?
    private var selected: UsageAccount? { store.accounts.first { $0.id == selectedID } ?? store.accounts.first }

    var body: some View {
        NavigationStack {
            List {
                if let account = selected {
                    let model = account.modelLimits.first { $0.id == modelLimitID }
                    let observations = account.history.filter { observation in
                        if let model { return observation.modelLimitID == model.id }
                        return observation.modelLimitID == nil && observation.period == period
                    }
                    Section {
                        Picker("Account", selection: Binding(get: { selectedID ?? account.id }, set: { selectedID = $0 })) {
                            ForEach(store.accounts) { Text($0.title).tag($0.id) }
                        }
                        Picker("Measurement", selection: $showTokens) {
                            Text("Quota history").tag(false)
                            Text("Tokens").tag(true)
                        }.pickerStyle(.segmented)
                        if !showTokens {
                            Picker("Limit", selection: $modelLimitID) {
                                Text("Account allowance").tag(String?.none)
                                ForEach(account.modelLimits) { Text($0.title).tag(Optional($0.id)) }
                            }
                            if let model { LabeledContent("Window", value: model.windowLabel) }
                            else { Picker("Quota window", selection: $period) { ForEach(QuotaPeriod.allCases) { Text($0.name).tag($0) } } }
                        }
                    }
                    if showTokens {
                        ContentUnavailableView("Token counts unavailable", systemImage: "number", description: Text("Quota percentages measure allowance. They do not establish exact token counts."))
                    } else if observations.isEmpty {
                        ContentUnavailableView("No quota history yet", systemImage: "chart.bar.xaxis", description: Text("Sync your account to start a local history."))
                    } else {
                        Section("Captured quota observations") {
                            Chart(observations) { observation in
                                BarMark(x: .value("Captured", observation.date), y: .value("Used", observation.usedPercent))
                                    .foregroundStyle(HeadroomStyle.teal)
                            }
                            .chartYScale(domain: 0...100)
                            .chartYAxisLabel("Quota used (%)")
                            .frame(height: 220)
                            .padding(.vertical, 8)
                            Text("\(account.title) · last captured readings").font(.caption).foregroundStyle(.secondary)
                        }
                        Section("Readings") {
                            ForEach(observations.reversed()) { observation in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(model?.modelName ?? observation.title)
                                        Text(observation.date, style: .time).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("\(Int(observation.usedPercent))% used").monospacedDigit()
                                }
                            }
                        }
                    }
                } else { ContentUnavailableView("No accounts", systemImage: "person.crop.circle") }
            }
            .navigationTitle("Activity")
            .onChange(of: selectedID) { _, _ in modelLimitID = nil }
        }
    }
}
