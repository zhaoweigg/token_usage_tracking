import Foundation
import Darwin

enum SharedFileLock {
    static var directory: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetSnapshotStore.groupID) }

    private static func openFile(_ name: String) throws -> Int32 {
        guard let directory else { throw ProviderSyncError.unavailable }
        let url = directory.appendingPathComponent(name)
        let descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ProviderSyncError.unavailable }
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        return descriptor
    }

    static func withSnapshot<T>(_ operation: () throws -> T) throws -> T {
        let descriptor = try openFile("snapshot.lock")
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        let deadline = Date().addingTimeInterval(0.25)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else { throw ProviderSyncError.busy }
            usleep(5_000)
        }
        return try operation()
    }

    @MainActor
    static func withAccount<T>(_ id: UUID, operation: () async throws -> T) async throws -> T {
        let descriptor = try openFile("sync-\(id.uuidString).lock")
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        let deadline = Date().addingTimeInterval(20)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            try Task.checkCancellation()
            guard Date() < deadline else { throw ProviderSyncError.busy }
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation()
        return try await operation()
    }
}
