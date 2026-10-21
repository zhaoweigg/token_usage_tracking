import AppIntents
import Foundation

struct RefreshUsageIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Headroom usage"
    static var description = IntentDescription("Check the selected accounts and update their widgets without opening Headroom.")
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Account identifiers") var accountIDs: [String]
    init() { accountIDs = [] }
    init(accountIDs: [UUID]) { self.accountIDs = accountIDs.map(\.uuidString) }

    func perform() async throws -> IntentResultContainer<Never, Never, Never, Never> {
        let ids = accountIDs.compactMap(UUID.init(uuidString:))
        guard ids.count == accountIDs.count else { return .result() }
        await WidgetUsageRefresh().refresh(accountIDs: ids.isEmpty ? nil : Set(ids))
        #if HEADROOM_APP
        await HeadroomRuntime.shared.store.reloadSharedReadings()
        #endif
        return .result()
    }
}
