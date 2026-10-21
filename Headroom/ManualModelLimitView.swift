import SwiftUI

struct ManualModelLimitView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.dismiss) private var dismiss
    let accountID: UUID
    @State private var selectedID: String?
    @State private var modelName = ""
    @State private var windowLabel = ""
    @State private var useCount = false
    @State private var percent = ""
    @State private var used = ""
    @State private var total = ""
    @State private var unit = QuotaUnit.messages
    @State private var observedAt = Date()
    @State private var hasReset = false
    @State private var resetsAt = Date().addingTimeInterval(3600)

    private var count: QuotaCount? {
        guard useCount, let used = Double(used), let total = Double(total) else { return nil }
        let result = QuotaCount(used: used, limit: total, unit: unit)
        return result.isValid ? result : nil
    }
    private var validPercent: Double? {
        if useCount { return count?.percent }
        guard let value = Double(percent), value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }
    private var canSave: Bool {
        !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !windowLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && validPercent != nil
    }

    var body: some View {
        Form {
            Group {
                Section("Limit") {
                    Picker("Record", selection: $selectedID) {
                        Text("New model limit").tag(String?.none)
                        ForEach(store.account(accountID)?.modelLimits ?? []) { Text($0.title).tag(Optional($0.id)) }
                    }
                    TextField("Model or model group", text: $modelName).accessibilityIdentifier("model-name-field")
                    TextField("Window (e.g. Daily, Weekly)", text: $windowLabel).accessibilityIdentifier("model-window-field")
                }
                Section("Usage") {
                    Picker("Measurement", selection: $useCount) {
                        Text("Percentage").tag(false)
                        Text("Count").tag(true)
                    }.pickerStyle(.segmented)
                    if useCount {
                        TextField("Used", text: $used).keyboardType(.decimalPad)
                        TextField("Limit", text: $total).keyboardType(.decimalPad)
                        Picker("Unit", selection: $unit) { ForEach(QuotaUnit.allCases) { Text($0.rawValue.capitalized).tag($0) } }
                    } else {
                        TextField("Percentage used (0–100)", text: $percent).keyboardType(.decimalPad)
                    }
                    DatePicker("Observed", selection: $observedAt, in: ...Date())
                    Toggle("Include reset time", isOn: $hasReset)
                    if hasReset { DatePicker("Next reset", selection: $resetsAt) }
                }
                Section("Preview") {
                    if let value = validPercent {
                        QuotaStatusView(title: "\(modelName.isEmpty ? "Model" : modelName) · \(windowLabel.isEmpty ? "Window" : windowLabel)", reading: .init(usedPercent: value, observedAt: observedAt, resetsAt: hasReset ? resetsAt : nil, source: .manual), count: count)
                    } else { Text("Enter a percentage from 0 to 100, or valid used and limit counts.").foregroundStyle(HeadroomStyle.secondaryText) }
                    Text("This records a separate model limit. Account-wide and other model readings keep their original values and observation times.")
                        .font(.apricot(.caption)).foregroundStyle(HeadroomStyle.secondaryText)
                }
            }.listRowBackground(HeadroomStyle.surface)
        }
        .apricotScreen()
        .navigationTitle("Record model limit").navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedID) { _, id in load(id) }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if let value = validPercent {
                        store.recordModelLimit(accountID: accountID, id: selectedID, modelName: modelName, windowLabel: windowLabel, percent: value, count: count, reset: hasReset ? resetsAt : nil, observedAt: observedAt)
                        dismiss()
                    }
                }.disabled(!canSave).accessibilityIdentifier("save-model-limit-button")
            }
        }
    }

    private func load(_ id: String?) {
        let limit = store.account(accountID)?.modelLimits.first { $0.id == id }
        modelName = limit?.modelName ?? ""
        windowLabel = limit?.windowLabel ?? ""
        useCount = limit?.count != nil
        percent = limit?.quotaReading.displayPercent.map { String($0) } ?? ""
        used = limit?.count.map { String($0.used) } ?? ""
        total = limit?.count.map { String($0.limit) } ?? ""
        unit = limit?.count?.unit ?? .messages
        observedAt = limit?.reading.observedAt ?? .now
        hasReset = limit?.reading.resetsAt != nil
        resetsAt = limit?.reading.resetsAt ?? Date().addingTimeInterval(3600)
    }
}
