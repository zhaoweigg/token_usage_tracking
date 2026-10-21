import BackgroundTasks
import UIKit
import OSLog
import Combine

@MainActor
final class BackgroundRefreshController: ObservableObject {
    static let identifier = "com.example.headroom.refresh"
    private let store: UsageStore
    private let defaults: UserDefaults
    private let submit: (Date?) throws -> Void
    private let cancel: () -> Void
    private let availability: () -> UIBackgroundRefreshStatus
    private let budget: TimeInterval
    private let logger = Logger(subsystem: "com.example.headroom", category: "BackgroundRefresh")
    private var hasPendingRequest = false
    private var activeID: UUID?
    private var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var completion: ((Bool) -> Void)?
    private(set) var registered = false
    private var registrationAttempted = false

    enum Outcome: String {
        case updated, partial, unchanged, failed, expired, disabled
        var title: String {
            switch self {
            case .updated: return "Usage updated"
            case .partial: return "Some accounts updated"
            case .unchanged: return "No accounts due"
            case .failed: return "Could not update"
            case .expired: return "iOS ended the refresh"
            case .disabled: return "Background refresh turned off"
            }
        }
    }
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "headroom.background.enabled")
            UserDefaults(suiteName: WidgetSnapshotStore.groupID)?.set(enabled, forKey: "headroom.automaticRefreshEnabled")
            if !enabled { expireActive(outcome: .disabled) }
            schedule()
        }
    }
    @Published private(set) var systemStatus: UIBackgroundRefreshStatus
    @Published private(set) var lowPowerMode: Bool
    @Published private(set) var lastStartedAt: Date?
    @Published private(set) var lastCompletedAt: Date?
    @Published private(set) var lastOutcome: Outcome?
    @Published private(set) var schedulingFailed = false

    init(store: UsageStore, defaults: UserDefaults = .standard, budget: TimeInterval = 22,
         availability: @escaping () -> UIBackgroundRefreshStatus = { UIApplication.shared.backgroundRefreshStatus },
         submit: @escaping (Date?) throws -> Void = { date in
             let request = BGAppRefreshTaskRequest(identifier: BackgroundRefreshController.identifier)
             request.earliestBeginDate = date
             try BGTaskScheduler.shared.submit(request)
         }, cancel: @escaping () -> Void = { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundRefreshController.identifier) }) {
        self.store = store; self.defaults = defaults; self.budget = budget
        self.availability = availability; self.submit = submit; self.cancel = cancel
        enabled = defaults.object(forKey: "headroom.background.enabled") as? Bool ?? true
        systemStatus = availability(); lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        lastStartedAt = defaults.object(forKey: "headroom.background.lastStartedAt") as? Date
        lastCompletedAt = defaults.object(forKey: "headroom.background.lastCompletedAt") as? Date
        lastOutcome = (defaults.string(forKey: "headroom.background.lastOutcome")).flatMap(Outcome.init(rawValue:))
        UserDefaults(suiteName: WidgetSnapshotStore.groupID)?.set(enabled, forKey: "headroom.automaticRefreshEnabled")
    }

    var statusText: String {
        if !enabled { return "Off" }
        if lowPowerMode { return "Paused by Low Power Mode" }
        if systemStatus == .denied { return "Off in iPhone Settings" }
        if systemStatus == .restricted { return "Restricted by iOS" }
        if store.backgroundEligibleAccounts.isEmpty { return "No eligible accounts" }
        if schedulingFailed { return "Could not schedule" }
        return "Scheduled by iOS"
    }

    func register() {
        guard !registered else { return }
        registrationAttempted = true
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { [weak self] task in
            Task { @MainActor in
                guard let self, let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
                self.hasPendingRequest = false
                self.schedule()
                let id = self.beginRun { success in
                    refresh.expirationHandler = nil
                    refresh.setTaskCompleted(success: success)
                }
                if let id {
                    refresh.expirationHandler = { [weak self] in Task { @MainActor in self?.expireActive(expectedID: id) } }
                }
            }
        }
        defaults.set(registered, forKey: "headroom.background.registered")
        if !registered { schedulingFailed = true }
    }

    func updateAvailability() {
        systemStatus = availability(); lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        defaults.set(systemStatus.rawValue, forKey: "headroom.background.systemStatus")
        defaults.set(lowPowerMode, forKey: "headroom.background.lowPowerMode")
        schedule()
    }

    func schedule() {
        guard enabled, systemStatus == .available, !store.backgroundEligibleAccounts.isEmpty else {
            cancel(); hasPendingRequest = false; schedulingFailed = false
            return
        }
        guard !(registrationAttempted && !registered) else { schedulingFailed = true; return }
        guard !hasPendingRequest else { return }
        do {
            // nil explicitly asks for the next opportunity, with no app-imposed delay.
            try submit(nil)
            defaults.set(Date(), forKey: "headroom.background.requestedAt")
            hasPendingRequest = true; schedulingFailed = false
        } catch {
            // Never export an arbitrary system error's userInfo or description.
            schedulingFailed = true
        }
    }

    // Shared by the registered OS handler and deterministic expiration tests.
    @discardableResult
    func beginRun(completion: @escaping (Bool) -> Void) -> UUID? {
        guard activeID == nil else { completion(false); return nil }
        guard enabled else { completion(true); return nil }
        let id = UUID()
        activeID = id; self.completion = completion
        lastStartedAt = .now
        defaults.set(lastStartedAt, forKey: "headroom.background.lastStartedAt")
        logger.notice("Background usage refresh started")
        deadline = Task { [weak self, budget] in
            do { try await Task.sleep(for: .seconds(budget)) } catch { return }
            guard self?.activeID == id else { return }
            self?.expireActive()
        }
        work = Task { [weak self] in
            guard let self else { return }
            let report = await self.store.refreshInBackground()
            guard self.activeID == id else { return }
            let outcome: Outcome = report.cancelled ? .expired : report.failed > 0 ? (report.updated > 0 ? .partial : .failed) : report.updated > 0 ? .updated : .unchanged
            self.finish(id: id, outcome: outcome, success: report.succeeded)
        }
        return id
    }

    func expireActive(outcome: Outcome = .expired, expectedID: UUID? = nil) {
        guard let id = activeID, expectedID == nil || expectedID == id else { return }
        store.cancelBackgroundRefreshes()
        work?.cancel()
        finish(id: id, outcome: outcome, success: false)
    }

    private func finish(id: UUID, outcome: Outcome, success: Bool) {
        guard activeID == id else { return }
        activeID = nil; deadline?.cancel(); deadline = nil; work = nil
        lastCompletedAt = .now; lastOutcome = outcome
        defaults.set(lastCompletedAt, forKey: "headroom.background.lastCompletedAt")
        defaults.set(outcome.rawValue, forKey: "headroom.background.lastOutcome")
        logger.notice("Background usage refresh completed: \(outcome.rawValue, privacy: .public)")
        let complete = completion; completion = nil
        complete?(success)
        schedule()
    }
}

@MainActor
final class HeadroomRuntime {
    static let shared = HeadroomRuntime()
    let store: UsageStore
    let background: BackgroundRefreshController
    private init() {
        let defaults: UserDefaults
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), let testDefaults = UserDefaults(suiteName: "Headroom.UITests") {
            defaults = testDefaults
            if ProcessInfo.processInfo.arguments.contains("--reset-local-data") {
                defaults.removeObject(forKey: "headroom.background.enabled")
                defaults.removeObject(forKey: "headroom.refreshRetry.v1")
            }
        } else { defaults = .standard }
        #else
        defaults = .standard
        #endif
        store = UsageStore(defaults: defaults)
        var ready = 0
        for account in store.backgroundEligibleAccounts {
            if account.connectionMethod == .claudeOAuth, (try? store.claudeOAuth.vault.load(account.id)) != nil { ready += 1 }
            if account.connectionMethod == .codexOAuth, (try? store.codexOAuth.vault.load(account.id)) != nil { ready += 1 }
        }
        defaults.set(ready, forKey: "headroom.widgetCredentials.readyAccountCount")
        background = BackgroundRefreshController(store: store, defaults: defaults)
        store.accountsDidChange = { [weak background] in background?.schedule() }
    }
}

@MainActor
final class HeadroomAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        HeadroomRuntime.shared.background.register()
        return true
    }
}
