import Foundation

public final class StatusStore {
    public struct Configuration: Sendable {
        public var maxSessions: Int

        public init(maxSessions: Int = 500) {
            self.maxSessions = maxSessions
        }
    }

    private let queue = DispatchQueue(label: "VibeSignal.StatusStore")
    private let configuration: Configuration
    private var eventsByKey: [String: SignalEvent]
    private let persistence: SnapshotPersistence?
    private var lastPublishedSnapshot: SignalSnapshot?

    public var onSnapshotChanged: ((SignalSnapshot) -> Void)?

    public init(configuration: Configuration = Configuration(), persistence: SnapshotPersistence? = nil) {
        self.configuration = configuration
        self.persistence = persistence
        if let snapshot = try? persistence?.load() {
            let boundedSnapshot = SignalSnapshot.make(
                from: snapshot.sessions,
                maxSessions: configuration.maxSessions
            )
            self.eventsByKey = Dictionary(uniqueKeysWithValues: boundedSnapshot.sessions.map { ($0.sessionKey, $0) })
            self.lastPublishedSnapshot = boundedSnapshot
        } else {
            self.eventsByKey = [:]
            self.lastPublishedSnapshot = nil
        }
    }

    public func apply(_ event: SignalEvent, now: Date = Date()) {
        let publishedSnapshot: SignalSnapshot? = queue.sync {
            eventsByKey[event.sessionKey] = event
            let snapshot = makeSnapshot(now: now)
            eventsByKey = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.sessionKey, $0) })
            return publishIfChanged(snapshot)
        }
        if let publishedSnapshot {
            onSnapshotChanged?(publishedSnapshot)
        }
    }

    public func pruneExpired(now: Date = Date()) {
        let publishedSnapshot: SignalSnapshot? = queue.sync {
            let previousCount = eventsByKey.count
            eventsByKey = eventsByKey.filter { !$0.value.isExpired(now: now) }
            guard eventsByKey.count != previousCount else {
                return nil
            }
            let snapshot = makeSnapshot(now: now)
            eventsByKey = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.sessionKey, $0) })
            return publishIfChanged(snapshot)
        }
        if let publishedSnapshot {
            onSnapshotChanged?(publishedSnapshot)
        }
    }

    public func removeEvents(source: String, adapter: String? = nil, now: Date = Date()) {
        let publishedSnapshot: SignalSnapshot? = queue.sync {
            let previousCount = eventsByKey.count
            eventsByKey = eventsByKey.filter { _, event in
                guard event.source == source else {
                    return true
                }

                if let adapter {
                    return event.adapter != adapter
                }

                return false
            }

            guard eventsByKey.count != previousCount else {
                return nil
            }

            let snapshot = makeSnapshot(now: now)
            eventsByKey = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.sessionKey, $0) })
            return publishIfChanged(snapshot)
        }
        if let publishedSnapshot {
            onSnapshotChanged?(publishedSnapshot)
        }
    }

    public func snapshot(now: Date = Date()) -> SignalSnapshot {
        queue.sync {
            makeSnapshot(now: now)
        }
    }

    private func makeSnapshot(now: Date) -> SignalSnapshot {
        SignalSnapshot.make(
            from: Array(eventsByKey.values),
            now: now,
            maxSessions: configuration.maxSessions
        )
    }

    private func publishIfChanged(_ snapshot: SignalSnapshot) -> SignalSnapshot? {
        if let lastPublishedSnapshot,
           lastPublishedSnapshot.globalState == snapshot.globalState,
           lastPublishedSnapshot.sessions == snapshot.sessions {
            return nil
        }

        try? persistence?.save(snapshot)
        lastPublishedSnapshot = snapshot
        return snapshot
    }
}
