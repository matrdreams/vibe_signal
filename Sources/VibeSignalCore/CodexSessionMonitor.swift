import Foundation

public final class CodexSessionMonitor {
    public struct Configuration: Sendable {
        public var codexHomeURL: URL
        public var pollInterval: TimeInterval
        public var discoveryInterval: TimeInterval
        public var fullDiscoveryInterval: TimeInterval
        public var coldFilePollInterval: TimeInterval
        public var recentFileWindow: TimeInterval
        public var maxTrackedFiles: Int
        public var workingTTL: Int
        public var idleTTL: Int
        public var refreshInterval: TimeInterval
        public var staleAfter: TimeInterval
        public var maxIncrementalBytes: UInt64
        public var maxBufferedLineBytes: Int
        public var blockedEmitDelay: TimeInterval

        public init(
            codexHomeURL: URL = CodexSessionMonitor.defaultCodexHomeURL(),
            pollInterval: TimeInterval = 1,
            discoveryInterval: TimeInterval = 3,
            fullDiscoveryInterval: TimeInterval = 60,
            coldFilePollInterval: TimeInterval = 15,
            recentFileWindow: TimeInterval = 24 * 60 * 60,
            maxTrackedFiles: Int = 100,
            workingTTL: Int = 300_000,
            idleTTL: Int = 900_000,
            refreshInterval: TimeInterval = 30,
            staleAfter: TimeInterval = 30 * 60,
            maxIncrementalBytes: UInt64 = 4_000_000,
            maxBufferedLineBytes: Int = 1_000_000,
            blockedEmitDelay: TimeInterval = 2
        ) {
            self.codexHomeURL = codexHomeURL
            self.pollInterval = pollInterval
            self.discoveryInterval = discoveryInterval
            self.fullDiscoveryInterval = fullDiscoveryInterval
            self.coldFilePollInterval = coldFilePollInterval
            self.recentFileWindow = recentFileWindow
            self.maxTrackedFiles = maxTrackedFiles
            self.workingTTL = workingTTL
            self.idleTTL = idleTTL
            self.refreshInterval = refreshInterval
            self.staleAfter = staleAfter
            self.maxIncrementalBytes = maxIncrementalBytes
            self.maxBufferedLineBytes = maxBufferedLineBytes
            self.blockedEmitDelay = blockedEmitDelay
        }
    }

    private enum EmitPolicy {
        case seed
        case live
    }

    private struct TrackedFile {
        var url: URL
        var offset: UInt64
        var sessionID: String?
        var seeded: Bool
        var pendingText: String
        var knownSize: UInt64?
        var knownModificationDate: Date?
        var hasUnprocessedChanges: Bool
        var lastPolledAt: Date?
    }

    private struct TrackedSession {
        var id: String
        var workspace: String?
        var activeTurnIDs: Set<String> = []
        var state: SignalState = .idle
        var reason: String = SignalReason.done
        var message: String = "Idle"
        var startedAt: Date?
        var updatedAt: Date = Date()
        var lastEmittedAt: Date?
        var blockedObservedAt: Date?
        var lastFileModificationDate: Date?
        var sessionFile: String?

        var isActive: Bool {
            state.isActive && !activeTurnIDs.isEmpty
        }
    }

    private struct FileCandidate {
        var url: URL
        var modifiedAt: Date
        var size: UInt64
    }

    private struct FileAttributes {
        var size: UInt64
        var modifiedAt: Date?
    }

    private struct SeedActivity {
        var state: SignalState
        var reason: String
        var message: String
        var timestamp: Date?
    }

    private struct SeedSummary {
        var state: SignalState
        var reason: String
        var message: String
        var turnID: String?
        var startedAt: Date?
        var updatedAt: Date?
    }

    private let configuration: Configuration
    private let emit: (SignalEvent) -> Void
    private let queue = DispatchQueue(label: "VibeSignal.CodexSessionMonitor")
    private let queueKey = DispatchSpecificKey<Void>()
    private let fileManager: FileManager
    private let parser = CodexSessionLineParser()

    private var timer: DispatchSourceTimer?
    private var files: [String: TrackedFile] = [:]
    private var sessions: [String: TrackedSession] = [:]
    private var lastDiscoveryAt: Date?
    private var lastFullDiscoveryAt: Date?

    public init(
        configuration: Configuration = Configuration(),
        fileManager: FileManager = .default,
        emit: @escaping (SignalEvent) -> Void
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        self.emit = emit
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        stop()
    }

    public func start() {
        queue.async {
            guard self.timer == nil else {
                return
            }

            self.poll(now: Date(), forceDiscovery: true)

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(
                deadline: .now() + self.configuration.pollInterval,
                repeating: self.configuration.pollInterval
            )
            timer.setEventHandler { [weak self] in
                self?.poll(now: Date(), forceDiscovery: false)
            }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopOnQueue()
        } else {
            queue.sync {
                self.stopOnQueue()
            }
        }
    }

    func scanOnceForTesting(now: Date = Date()) {
        queue.sync {
            self.poll(now: now, forceDiscovery: true)
        }
    }

    private func stopOnQueue() {
        timer?.cancel()
        timer = nil
    }

    private func poll(now: Date, forceDiscovery: Bool) {
        if forceDiscovery || shouldDiscover(now: now) {
            discoverFiles(now: now)
        }

        for key in Array(files.keys) {
            guard shouldProcessTrackedFile(key: key, now: now) else {
                continue
            }
            processTrackedFile(key: key, now: now)
        }

        refreshActiveSessions(now: now)
    }

    private func shouldDiscover(now: Date) -> Bool {
        guard let lastDiscoveryAt else {
            return true
        }
        return now.timeIntervalSince(lastDiscoveryAt) >= configuration.discoveryInterval
    }

    private func discoverFiles(now: Date) {
        lastDiscoveryAt = now
        let needsFullDiscovery = shouldRunFullDiscovery(now: now)
        if needsFullDiscovery {
            lastFullDiscoveryAt = now
        }

        let sessionsURL = configuration.codexHomeURL.appendingPathComponent("sessions", isDirectory: true)
        var candidates: [FileCandidate] = []
        for rootURL in discoveryRoots(sessionsURL: sessionsURL, now: now, includeFullTree: needsFullDiscovery) {
            guard let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl" else {
                    continue
                }

                guard let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
                ),
                      values.isRegularFile == true else {
                    continue
                }

                let modifiedAt = values.contentModificationDate ?? .distantPast
                let isRecent = now.timeIntervalSince(modifiedAt) <= configuration.recentFileWindow
                guard isRecent || files[url.path] != nil else {
                    continue
                }

                candidates.append(FileCandidate(
                    url: url,
                    modifiedAt: modifiedAt,
                    size: UInt64(values.fileSize ?? 0)
                ))
            }
        }

        let selected = candidates
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(configuration.maxTrackedFiles)
        let selectedPaths = Set(selected.map { $0.url.path })

        for candidate in selected {
            let path = candidate.url.path
            if var tracked = files[path] {
                if tracked.knownSize != candidate.size || tracked.knownModificationDate != candidate.modifiedAt {
                    tracked.knownSize = candidate.size
                    tracked.knownModificationDate = candidate.modifiedAt
                    tracked.hasUnprocessedChanges = true
                    files[path] = tracked
                }
            } else {
                files[path] = TrackedFile(
                    url: candidate.url,
                    offset: 0,
                    sessionID: sessionID(from: candidate.url),
                    seeded: false,
                    pendingText: "",
                    knownSize: candidate.size,
                    knownModificationDate: candidate.modifiedAt,
                    hasUnprocessedChanges: true,
                    lastPolledAt: nil
                )
            }
        }

        for key in Array(files.keys) where !selectedPaths.contains(key) && !isTrackedFileActive(files[key]) {
            files.removeValue(forKey: key)
        }

        pruneUntrackedIdleSessions(now: now)
    }

    private func shouldRunFullDiscovery(now: Date) -> Bool {
        guard let lastFullDiscoveryAt else {
            return true
        }
        return now.timeIntervalSince(lastFullDiscoveryAt) >= configuration.fullDiscoveryInterval
    }

    private func discoveryRoots(sessionsURL: URL, now: Date, includeFullTree: Bool) -> [URL] {
        guard !includeFullTree else {
            return [sessionsURL]
        }

        var roots: [URL] = []
        var seen = Set<String>()
        let calendar = Calendar(identifier: .gregorian)
        let start = now.addingTimeInterval(-configuration.recentFileWindow)
        var day = calendar.startOfDay(for: start)
        let end = calendar.startOfDay(for: now)

        while day <= end {
            let components = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = components.year,
                  let month = components.month,
                  let dayOfMonth = components.day else {
                break
            }

            let root = sessionsURL
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", dayOfMonth), isDirectory: true)
            if fileManager.fileExists(atPath: root.path),
               seen.insert(root.path).inserted {
                roots.append(root)
            }

            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else {
                break
            }
            day = nextDay
        }

        return roots
    }

    private func shouldProcessTrackedFile(key: String, now: Date) -> Bool {
        guard let tracked = files[key] else {
            return false
        }

        if !tracked.seeded || tracked.hasUnprocessedChanges || isTrackedFileActive(tracked) {
            return true
        }

        guard let lastPolledAt = tracked.lastPolledAt else {
            return true
        }
        return now.timeIntervalSince(lastPolledAt) >= configuration.coldFilePollInterval
    }

    private func processTrackedFile(key: String, now: Date) {
        guard var tracked = files[key] else {
            return
        }

        guard let attributes = knownOrFreshAttributes(for: tracked) else {
            files.removeValue(forKey: key)
            return
        }

        tracked.lastPolledAt = now
        tracked.knownSize = attributes.size
        tracked.knownModificationDate = attributes.modifiedAt

        if let sessionID = tracked.sessionID {
            updateSession(sessionID) { session in
                session.lastFileModificationDate = attributes.modifiedAt
                session.sessionFile = tracked.url.path
            }
        }

        if attributes.size < tracked.offset {
            tracked.offset = 0
            tracked.pendingText = ""
            tracked.seeded = false
        }

        if !tracked.seeded {
            guard seedFile(&tracked, size: attributes.size, now: now) else {
                files.removeValue(forKey: key)
                return
            }
            tracked.offset = attributes.size
            tracked.seeded = true
            tracked.hasUnprocessedChanges = false
            emitSeededActiveSession(from: tracked, modifiedAt: attributes.modifiedAt, now: now)
            files[key] = tracked
            return
        }

        guard attributes.size > tracked.offset else {
            tracked.hasUnprocessedChanges = false
            files[key] = tracked
            return
        }

        let remaining = attributes.size - tracked.offset
        let bytesToRead = min(remaining, configuration.maxIncrementalBytes)
        let readOffset = attributes.size - bytesToRead
        let skippedBytes = readOffset > tracked.offset

        guard let data = readData(from: tracked.url, offset: readOffset, length: bytesToRead) else {
            files[key] = tracked
            return
        }

        tracked.offset = attributes.size
        tracked.hasUnprocessedChanges = false
        if skippedBytes {
            tracked.pendingText = ""
        }

        processIncrementalData(
            data,
            tracked: &tracked,
            now: now,
            skipLeadingPartialLine: skippedBytes
        )

        files[key] = tracked
    }

    private func seedFile(_ tracked: inout TrackedFile, size: UInt64, now: Date) -> Bool {
        if seedFileFromEdges(&tracked, size: size, now: now) {
            return true
        }

        return processStreamData(
            from: tracked.url,
            offset: 0,
            length: size,
            tracked: &tracked,
            now: now,
            emitPolicy: .seed
        )
    }

    private func seedFileFromEdges(_ tracked: inout TrackedFile, size: UInt64, now: Date) -> Bool {
        guard size > 0 else {
            return true
        }

        seedMetadataFromHead(&tracked, size: size, now: now)
        guard let summary = finalSeedSummaryByScanningBackward(from: tracked.url, size: size) else {
            return false
        }

        let sessionID = currentSessionID(for: tracked)
        updateSession(sessionID) { session in
            switch summary.state {
            case .working:
                session.activeTurnIDs = [summary.turnID ?? "unknown"]
                session.state = .working
                session.reason = summary.reason
                session.message = summary.message
                session.startedAt = summary.startedAt ?? summary.updatedAt ?? now
                session.updatedAt = summary.updatedAt ?? summary.startedAt ?? now
                session.blockedObservedAt = nil
            case .idle:
                session.activeTurnIDs.removeAll()
                session.state = .idle
                session.reason = summary.reason
                session.message = summary.message
                session.startedAt = nil
                session.updatedAt = summary.updatedAt ?? now
                session.blockedObservedAt = nil
            case .blocked:
                session.activeTurnIDs = [summary.turnID ?? "unknown"]
                session.state = .blocked
                session.reason = summary.reason
                session.message = summary.message
                session.startedAt = summary.startedAt ?? summary.updatedAt ?? now
                session.updatedAt = summary.updatedAt ?? summary.startedAt ?? now
                session.blockedObservedAt = now
            default:
                break
            }
            session.sessionFile = tracked.url.path
        }

        return true
    }

    private func seedMetadataFromHead(_ tracked: inout TrackedFile, size: UInt64, now: Date) {
        let length = min(size, 65_536)
        guard let data = readData(from: tracked.url, offset: 0, length: length) else {
            return
        }

        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for lineSubsequence in lines {
            let line = String(lineSubsequence).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  let record = parser.parse(line) else {
                continue
            }

            switch record.kind {
            case .sessionMeta(let id, let workspace):
                tracked.sessionID = id
                updateSession(id) { session in
                    session.workspace = workspace ?? session.workspace
                    session.updatedAt = record.timestamp ?? now
                    session.sessionFile = tracked.url.path
                }
            case .turnContext(_, let workspace):
                let sessionID = currentSessionID(for: tracked)
                updateSession(sessionID) { session in
                    session.workspace = workspace ?? session.workspace
                    session.updatedAt = record.timestamp ?? now
                    session.sessionFile = tracked.url.path
                }
            default:
                continue
            }
        }
    }

    private func finalSeedSummaryByScanningBackward(from url: URL, size: UInt64) -> SeedSummary? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer {
            try? handle.close()
        }

        let chunkSize: UInt64 = 262_144
        var offset = size
        var leadingPartialLine = ""
        var lastActivity: SeedActivity?

        while offset > 0 {
            let chunkStart = offset > chunkSize ? offset - chunkSize : 0
            let length = offset - chunkStart

            do {
                try handle.seek(toOffset: chunkStart)
            } catch {
                return nil
            }

            let data = handle.readData(ofLength: Int(length))
            guard !data.isEmpty else {
                break
            }

            let text = String(decoding: data, as: UTF8.self) + leadingPartialLine
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if chunkStart > 0 {
                leadingPartialLine = boundedPendingText(lines.isEmpty ? text : lines.removeFirst())
            } else {
                leadingPartialLine = ""
            }

            if let summary = summarizeSeedLinesInReverse(lines, lastActivity: &lastActivity) {
                return summary
            }

            offset = chunkStart
        }

        if !leadingPartialLine.isEmpty {
            return summarizeSeedLinesInReverse([leadingPartialLine], lastActivity: &lastActivity)
        }

        return nil
    }

    private func summarizeSeedLinesInReverse(
        _ lines: [String],
        lastActivity: inout SeedActivity?
    ) -> SeedSummary? {
        for line in lines.reversed() {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty,
                  let record = parser.parse(trimmedLine) else {
                continue
            }

            switch record.kind {
            case .taskEnded(_, let reason, let message):
                return SeedSummary(
                    state: .idle,
                    reason: reason,
                    message: message,
                    turnID: nil,
                    startedAt: nil,
                    updatedAt: record.timestamp
                )
            case .taskStarted(let turnID):
                return SeedSummary(
                    state: lastActivity?.state ?? .working,
                    reason: lastActivity?.reason ?? SignalReason.thinking,
                    message: lastActivity?.message ?? "Codex is working",
                    turnID: turnID,
                    startedAt: record.timestamp,
                    updatedAt: lastActivity?.timestamp ?? record.timestamp
                )
            case .blocked(let reason, let message):
                if lastActivity == nil {
                    lastActivity = SeedActivity(
                        state: .blocked,
                        reason: reason,
                        message: message,
                        timestamp: record.timestamp
                    )
                }
            case .activity(let reason, let message):
                if lastActivity == nil {
                    lastActivity = SeedActivity(
                        state: .working,
                        reason: reason,
                        message: message,
                        timestamp: record.timestamp
                    )
                }
            default:
                continue
            }
        }

        return nil
    }

    private func processStreamData(
        from url: URL,
        offset: UInt64,
        length: UInt64,
        tracked: inout TrackedFile,
        now: Date,
        emitPolicy: EmitPolicy
    ) -> Bool {
        guard length > 0,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return length == 0
        }
        defer {
            try? handle.close()
        }

        do {
            try handle.seek(toOffset: offset)
            var remaining = length
            var pendingText = ""

            while remaining > 0 {
                let chunkLength = Int(min(262_144, remaining))
                let data = handle.readData(ofLength: chunkLength)
                guard !data.isEmpty else {
                    break
                }

                remaining -= UInt64(data.count)
                let text = pendingText + String(decoding: data, as: UTF8.self)
                let hasCompleteFinalLine = text.hasSuffix("\n")
                var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

                if hasCompleteFinalLine {
                    pendingText = ""
                } else {
                    pendingText = boundedPendingText(lines.popLast() ?? "")
                }

                for line in lines {
                    processLine(line, tracked: &tracked, now: now, emitPolicy: emitPolicy)
                }
            }

            if !pendingText.isEmpty {
                processLine(pendingText, tracked: &tracked, now: now, emitPolicy: emitPolicy)
            }
            return true
        } catch {
            return false
        }
    }

    private func processIncrementalData(
        _ data: Data,
        tracked: inout TrackedFile,
        now: Date,
        skipLeadingPartialLine: Bool
    ) {
        var text = String(decoding: data, as: UTF8.self)
        if skipLeadingPartialLine {
            guard let newlineIndex = text.firstIndex(of: "\n") else {
                return
            }
            text = String(text[text.index(after: newlineIndex)...])
        }

        text = tracked.pendingText + text
        let hasCompleteFinalLine = text.hasSuffix("\n")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        if hasCompleteFinalLine {
            tracked.pendingText = ""
        } else {
            tracked.pendingText = boundedPendingText(lines.popLast() ?? "")
        }

        for line in lines {
            processLine(line, tracked: &tracked, now: now, emitPolicy: .live)
        }
    }

    private func processLine(
        _ line: String,
        tracked: inout TrackedFile,
        now: Date,
        emitPolicy: EmitPolicy
    ) {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty,
              let record = parser.parse(trimmedLine) else {
            return
        }

        switch record.kind {
        case .sessionMeta(let id, let workspace):
            tracked.sessionID = id
            updateSession(id) { session in
                session.workspace = workspace ?? session.workspace
                session.updatedAt = record.timestamp ?? now
                session.sessionFile = tracked.url.path
            }

        case .turnContext(_, let workspace):
            let sessionID = currentSessionID(for: tracked)
            updateSession(sessionID) { session in
                session.workspace = workspace ?? session.workspace
                session.updatedAt = record.timestamp ?? now
                session.sessionFile = tracked.url.path
            }

        case .taskStarted(let turnID):
            let sessionID = currentSessionID(for: tracked)
            let normalizedTurnID = turnID ?? "unknown"
            var shouldEmit = false
            updateSession(sessionID) { session in
                session.activeTurnIDs.insert(normalizedTurnID)
                session.state = .working
                session.reason = SignalReason.thinking
                session.message = "Codex is working"
                session.startedAt = session.startedAt ?? (record.timestamp ?? now)
                session.updatedAt = record.timestamp ?? now
                session.blockedObservedAt = nil
                session.sessionFile = tracked.url.path
                shouldEmit = true
            }
            if emitPolicy == .live, shouldEmit {
                emitSession(sessionID, now: now)
            }

        case .blocked(let reason, let message):
            let sessionID = currentSessionID(for: tracked)
            guard sessions[sessionID]?.isActive == true else {
                return
            }

            updateSession(sessionID) { session in
                session.state = .blocked
                session.reason = reason
                session.message = message
                session.updatedAt = record.timestamp ?? now
                session.blockedObservedAt = session.blockedObservedAt ?? now
                session.sessionFile = tracked.url.path
            }

        case .activity(let reason, let message):
            let sessionID = currentSessionID(for: tracked)
            guard sessions[sessionID]?.isActive == true else {
                return
            }

            updateSession(sessionID) { session in
                session.state = .working
                session.reason = reason
                session.message = message
                session.updatedAt = record.timestamp ?? now
                session.blockedObservedAt = nil
                session.sessionFile = tracked.url.path
            }
            if emitPolicy == .live {
                emitSession(sessionID, now: now)
            }

        case .taskEnded(let turnID, let reason, let message):
            let sessionID = currentSessionID(for: tracked)
            updateSession(sessionID) { session in
                if let turnID {
                    session.activeTurnIDs.remove(turnID)
                } else {
                    session.activeTurnIDs.removeAll()
                }

                if session.activeTurnIDs.isEmpty {
                    session.state = .idle
                    session.reason = reason
                    session.message = message
                    session.startedAt = nil
                    session.blockedObservedAt = nil
                }

                session.updatedAt = record.timestamp ?? now
                session.sessionFile = tracked.url.path
            }
            if emitPolicy == .live {
                emitSession(sessionID, now: now)
            }

        case .ignored:
            return
        }
    }

    private func boundedPendingText(_ text: String) -> String {
        text.utf8.count <= configuration.maxBufferedLineBytes ? text : ""
    }

    private func emitSeededActiveSession(from tracked: TrackedFile, modifiedAt: Date?, now: Date) {
        let sessionID = currentSessionID(for: tracked)
        guard var session = sessions[sessionID],
              session.isActive else {
            return
        }

        if let modifiedAt {
            session.lastFileModificationDate = modifiedAt
        }
        session.sessionFile = tracked.url.path
        sessions[sessionID] = session

        if !isStale(session, now: now),
           session.state != .blocked || canEmitBlockedSession(session, now: now) {
            emitSession(sessionID, now: now, force: true)
        }
    }

    private func refreshActiveSessions(now: Date) {
        for sessionID in Array(sessions.keys) {
            guard let session = sessions[sessionID],
                  session.isActive else {
                continue
            }

            if isStale(session, now: now) {
                updateSession(sessionID) { session in
                    session.activeTurnIDs.removeAll()
                    session.state = .idle
                    session.reason = SignalReason.stale
                    session.message = "Codex activity went stale"
                    session.startedAt = nil
                    session.blockedObservedAt = nil
                    session.updatedAt = now
                }
                emitSession(sessionID, now: now, force: true)
                continue
            }

            if session.state == .blocked {
                guard canEmitBlockedSession(session, now: now) else {
                    continue
                }

                if let lastEmittedAt = session.lastEmittedAt,
                   let blockedObservedAt = session.blockedObservedAt,
                   lastEmittedAt >= blockedObservedAt,
                   now.timeIntervalSince(lastEmittedAt) < configuration.refreshInterval {
                    continue
                }

                emitSession(sessionID, now: now, force: true)
                continue
            }

            if let lastEmittedAt = session.lastEmittedAt,
               now.timeIntervalSince(lastEmittedAt) < configuration.refreshInterval {
                continue
            }

            emitSession(sessionID, now: now, force: true)
        }
    }

    private func emitSession(_ sessionID: String, now: Date, force: Bool = false) {
        guard var session = sessions[sessionID] else {
            return
        }

        session.lastEmittedAt = now
        sessions[sessionID] = session

        emit(makeSignalEvent(from: session, now: now))
    }

    private func makeSignalEvent(from session: TrackedSession, now: Date) -> SignalEvent {
        var metadata: [String: JSONValue] = [:]
        if let turnID = session.activeTurnIDs.sorted().last {
            metadata["turn_id"] = .string(turnID)
        }
        if let sessionFile = session.sessionFile {
            metadata["session_file"] = .string(sessionFile)
        }

        return SignalEvent(
            source: "codex",
            adapter: "codex-session-monitor",
            sessionId: session.id,
            workspace: session.workspace,
            state: session.state,
            reason: session.reason,
            message: session.message,
            startedAt: session.startedAt,
            updatedAt: now,
            ttlMs: ttl(for: session.state),
            metadata: metadata.isEmpty ? nil : metadata
        )
    }

    private func ttl(for state: SignalState) -> Int {
        switch state {
        case .working, .blocked, .error:
            return configuration.workingTTL
        case .idle:
            return configuration.idleTTL
        case .unknown:
            return 60_000
        }
    }

    private func isStale(_ session: TrackedSession, now: Date) -> Bool {
        guard let lastFileModificationDate = session.lastFileModificationDate else {
            return false
        }
        return now.timeIntervalSince(lastFileModificationDate) > configuration.staleAfter
    }

    private func canEmitBlockedSession(_ session: TrackedSession, now: Date) -> Bool {
        guard session.state == .blocked else {
            return true
        }
        guard let blockedObservedAt = session.blockedObservedAt else {
            return configuration.blockedEmitDelay <= 0
        }
        return now.timeIntervalSince(blockedObservedAt) >= configuration.blockedEmitDelay
    }

    private func updateSession(_ sessionID: String, update: (inout TrackedSession) -> Void) {
        var session = sessions[sessionID] ?? TrackedSession(id: sessionID)
        update(&session)
        sessions[sessionID] = session
    }

    private func isTrackedFileActive(_ tracked: TrackedFile?) -> Bool {
        guard let tracked else {
            return false
        }
        let sessionID = currentSessionID(for: tracked)
        return sessions[sessionID]?.isActive == true
    }

    private func pruneUntrackedIdleSessions(now: Date) {
        let trackedSessionIDs = Set(files.values.map { currentSessionID(for: $0) })
        let idleRetention = Double(configuration.idleTTL) / 1000.0

        for sessionID in Array(sessions.keys) {
            guard !trackedSessionIDs.contains(sessionID),
                  let session = sessions[sessionID],
                  !session.isActive,
                  now.timeIntervalSince(session.updatedAt) > idleRetention else {
                continue
            }
            sessions.removeValue(forKey: sessionID)
        }
    }

    private func currentSessionID(for tracked: TrackedFile) -> String {
        tracked.sessionID ?? sessionID(from: tracked.url) ?? tracked.url.deletingPathExtension().lastPathComponent
    }

    private func knownOrFreshAttributes(for tracked: TrackedFile) -> FileAttributes? {
        if tracked.hasUnprocessedChanges,
           let size = tracked.knownSize {
            return FileAttributes(size: size, modifiedAt: tracked.knownModificationDate)
        }

        return fileAttributes(for: tracked.url)
    }

    private func fileAttributes(for url: URL) -> FileAttributes? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let sizeValue = attributes[.size] as? NSNumber else {
            return nil
        }
        return FileAttributes(size: sizeValue.uint64Value, modifiedAt: attributes[.modificationDate] as? Date)
    }

    private func readData(from url: URL, offset: UInt64, length: UInt64) -> Data? {
        guard length > 0,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer {
            try? handle.close()
        }

        do {
            try handle.seek(toOffset: offset)
            return handle.readData(ofLength: Int(length))
        } catch {
            return nil
        }
    }

    private func sessionID(from url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.count >= 36 else {
            return nil
        }

        let suffix = String(name.suffix(36))
        let groups = suffix.split(separator: "-")
        guard groups.count == 5,
              groups.map(\.count) == [8, 4, 4, 4, 12],
              suffix.allSatisfy({ $0.isHexDigit || $0 == "-" }) else {
            return nil
        }

        return suffix
    }

    public static func defaultCodexHomeURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["VIBE_SIGNAL_CODEX_HOME"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }
}

private struct CodexSessionRecord {
    enum Kind {
        case sessionMeta(id: String, workspace: String?)
        case turnContext(turnID: String?, workspace: String?)
        case taskStarted(turnID: String?)
        case blocked(reason: String, message: String)
        case activity(reason: String, message: String)
        case taskEnded(turnID: String?, reason: String, message: String)
        case ignored
    }

    var timestamp: Date?
    var kind: Kind
}

private final class CodexSessionLineParser {
    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func parse(_ line: String) -> CodexSessionRecord? {
        guard mightContainRelevantRecord(line) else {
            return nil
        }

        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recordType = object["type"] as? String else {
            return nil
        }

        let timestamp = (object["timestamp"] as? String).flatMap { dateFormatter.date(from: $0) }
        let payload = object["payload"] as? [String: Any]

        switch recordType {
        case "session_meta":
            guard let payload,
                  let id = payload["id"] as? String else {
                return CodexSessionRecord(timestamp: timestamp, kind: .ignored)
            }
            return CodexSessionRecord(
                timestamp: timestamp,
                kind: .sessionMeta(id: id, workspace: payload["cwd"] as? String)
            )

        case "turn_context":
            return CodexSessionRecord(
                timestamp: timestamp,
                kind: .turnContext(
                    turnID: payload?["turn_id"] as? String,
                    workspace: payload?["cwd"] as? String
                )
            )

        case "event_msg":
            return parseEventMessage(payload: payload, timestamp: timestamp)

        case "response_item":
            return parseResponseItem(payload: payload, timestamp: timestamp)

        default:
            return CodexSessionRecord(timestamp: timestamp, kind: .ignored)
        }
    }

    private func mightContainRelevantRecord(_ line: String) -> Bool {
        line.contains(#""type":"session_meta""#)
            || line.contains(#""type":"turn_context""#)
            || line.contains(#""type":"task_started""#)
            || line.contains(#""type":"task_complete""#)
            || line.contains(#""type":"turn_aborted""#)
            || line.contains(#""type":"web_search_end""#)
            || line.contains(#""type":"web_search_call""#)
            || line.contains(#""type":"function_call""#)
            || line.contains(#""type":"function_call_output""#)
            || line.contains(#""sandbox_permissions":"require_escalated""#)
            || line.contains(#""name":"request_user_input""#)
    }

    private func parseEventMessage(payload: [String: Any]?, timestamp: Date?) -> CodexSessionRecord {
        guard let payload,
              let payloadType = payload["type"] as? String else {
            return CodexSessionRecord(timestamp: timestamp, kind: .ignored)
        }

        switch payloadType {
        case "task_started":
            return CodexSessionRecord(
                timestamp: timestamp,
                kind: .taskStarted(turnID: payload["turn_id"] as? String)
            )

        case "task_complete":
            return CodexSessionRecord(
                timestamp: timestamp,
                kind: .taskEnded(
                    turnID: payload["turn_id"] as? String,
                    reason: SignalReason.done,
                    message: "Turn finished"
                )
            )

        case "turn_aborted":
            return CodexSessionRecord(
                timestamp: timestamp,
                kind: .taskEnded(
                    turnID: payload["turn_id"] as? String,
                    reason: SignalReason.done,
                    message: "Turn interrupted"
                )
            )

        case "web_search_end":
            return CodexSessionRecord(
                timestamp: timestamp,
                kind: .activity(reason: SignalReason.tool, message: "Searching the web")
            )

        default:
            return CodexSessionRecord(timestamp: timestamp, kind: .ignored)
        }
    }

    private func parseResponseItem(payload: [String: Any]?, timestamp: Date?) -> CodexSessionRecord {
        guard let payload,
              let payloadType = payload["type"] as? String else {
            return CodexSessionRecord(timestamp: timestamp, kind: .ignored)
        }

        switch payloadType {
        case "web_search_call":
            return CodexSessionRecord(
                timestamp: timestamp,
                kind: .activity(reason: SignalReason.tool, message: "Searching the web")
            )

        case "function_call":
            let name = payload["name"] as? String
            if name == "request_user_input" {
                return CodexSessionRecord(
                    timestamp: timestamp,
                    kind: .blocked(reason: SignalReason.question, message: "Waiting for user response")
                )
            }
            if name == "exec_command" {
                if requiresEscalatedApproval(payload: payload) {
                    return CodexSessionRecord(
                        timestamp: timestamp,
                        kind: .blocked(reason: SignalReason.approval, message: "Waiting for command approval")
                    )
                }
                return CodexSessionRecord(
                    timestamp: timestamp,
                    kind: .activity(reason: SignalReason.command, message: "Running command")
                )
            }
            return CodexSessionRecord(
                timestamp: timestamp,
                kind: .activity(reason: SignalReason.tool, message: "Running tool")
            )

        case "function_call_output":
            return CodexSessionRecord(
                timestamp: timestamp,
                kind: .activity(reason: SignalReason.tool, message: "Processing tool result")
            )

        default:
            return CodexSessionRecord(timestamp: timestamp, kind: .ignored)
        }
    }

    private func requiresEscalatedApproval(payload: [String: Any]) -> Bool {
        guard let arguments = payload["arguments"] as? String else {
            return false
        }

        if arguments.contains(#""sandbox_permissions":"require_escalated""#)
            || arguments.contains(#""sandbox_permissions": "require_escalated""#) {
            return true
        }

        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }

        return object["sandbox_permissions"] as? String == "require_escalated"
    }
}
