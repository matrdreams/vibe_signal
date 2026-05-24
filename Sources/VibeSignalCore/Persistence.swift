import Darwin
import Foundation

public final class SnapshotPersistence {
    public let url: URL
    private let maxSessions: Int

    public init(url: URL = VibeSignalPaths().snapshotURL, maxSessions: Int = 500) {
        self.url = url
        self.maxSessions = maxSessions
    }

    public func load() throws -> SignalSnapshot {
        try loadUnlocked()
    }

    public func save(_ snapshot: SignalSnapshot) throws {
        try withExclusiveLock {
            try saveUnlocked(snapshot)
        }
    }

    public func applyOffline(_ event: SignalEvent, now: Date = Date()) throws -> SignalSnapshot {
        try withExclusiveLock {
            var eventsByKey: [String: SignalEvent] = [:]
            if let existing = try? loadUnlocked() {
                for session in existing.sessions {
                    eventsByKey[session.sessionKey] = session
                }
            }

            eventsByKey[event.sessionKey] = event
            let snapshot = SignalSnapshot.make(
                from: Array(eventsByKey.values),
                now: now,
                maxSessions: maxSessions
            )
            try saveUnlocked(snapshot)
            return snapshot
        }
    }

    private func loadUnlocked() throws -> SignalSnapshot {
        let data = try Data(contentsOf: url)
        return try SignalJSON.decode(SignalSnapshot.self, from: data)
    }

    private func saveUnlocked(_ snapshot: SignalSnapshot) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try SignalJSON.encode(snapshot, prettyPrinted: true)
        try data.write(to: url, options: .atomic)
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let lockURL = directory.appendingPathComponent(".state.lock")
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw VibeSignalError.posix("open lock", errno)
        }
        defer { Darwin.close(fd) }

        guard Darwin.lockf(fd, F_LOCK, 0) == 0 else {
            throw VibeSignalError.posix("lock snapshot", errno)
        }
        defer { Darwin.lockf(fd, F_ULOCK, 0) }

        return try body()
    }
}
