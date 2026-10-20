import Foundation

struct WidgetReadDiagnostic: Codable {
    var date: Date
    var kind: String
    var phase: String
    var version: String
    var accountCount: Int
    var state: String
}

enum WidgetDiagnostics {
    static let kinds = ["HeadroomLiveOverview"]
    private static func url(kind: String) -> URL? {
        guard kinds.contains(kind) else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetSnapshotStore.groupID)?
            .appendingPathComponent("widget-read-\(kind).json")
    }
    static func record(kind: String, phase: String, state: WidgetDataState, accountCount: Int) {
        guard let url = url(kind: kind) else { return }
        let report = WidgetReadDiagnostic(date: .now, kind: kind, phase: phase, version: HeadroomVersion.display,
                                          accountCount: accountCount, state: state.title)
        guard let data = try? JSONEncoder().encode(report) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    }
    static func latest() -> WidgetReadDiagnostic? {
        kinds.compactMap { kind -> WidgetReadDiagnostic? in
            guard let url = url(kind: kind), let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(WidgetReadDiagnostic.self, from: data)
        }.max { $0.date < $1.date }
    }
}
