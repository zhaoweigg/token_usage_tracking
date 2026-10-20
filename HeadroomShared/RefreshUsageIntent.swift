import AppIntents
import Foundation

struct RefreshUsageIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Headroom usage"
    static var description = IntentDescription("Check the selected accounts and update their widgets without opening Headroom.")
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "Account identifiers") var accountIDs: [String]
    init() { accountIDs = [] }
    init(accountIDs: [UUID]) { self.accountIDs = accountIDs.map(\.uuidString) }

    func perform() async throws -> IntentResultContainer<Never, Never, Never, Never> {
        #if HEADROOM_APP
        let ids = accountIDs.compactMap(UUID.init(uuidString:))
        guard ids.count == accountIDs.count else { return .result() }
        await HeadroomRuntime.shared.refreshFromWidget(accountIDs: ids)
        return .result()
        #else
        // This declaration provides the widget's intent schema. Execution must
        // be routed to the containing app; credentials never enter the widget.
        throw WidgetRefreshExecutionError.openHeadroom
        #endif
    }
}

private enum WidgetRefreshExecutionError: LocalizedError {
    case openHeadroom
    var errorDescription: String? { "Open Headroom once to enable widget refresh, then try again." }
}

#if HEADROOM_APP
// iOS 17–25 use this marker to execute in the app process while leaving its UI
// closed. iOS 26+ expresses the same execution capability with supportedModes.
extension RefreshUsageIntent: ForegroundContinuableIntent {}
#endif
