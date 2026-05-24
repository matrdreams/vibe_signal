import XCTest
import Darwin
@testable import VibeSignalCore

final class VibeSignalCoreTests: XCTestCase {
    func testEmptySessionsAreIdle() {
        let snapshot = SignalSnapshot.make(from: [])
        XCTAssertEqual(snapshot.globalState, .idle)
    }

    func testGlobalStatePriority() {
        let now = Date()
        let events = [
            SignalEvent(
                source: "codex",
                adapter: "test",
                sessionId: "a",
                state: .working,
                reason: SignalReason.thinking,
                updatedAt: now
            ),
            SignalEvent(
                source: "codex",
                adapter: "test",
                sessionId: "b",
                state: .blocked,
                reason: SignalReason.approval,
                updatedAt: now
            )
        ]

        let snapshot = SignalSnapshot.make(from: events, now: now)
        XCTAssertEqual(snapshot.globalState, .blocked)
        XCTAssertEqual(snapshot.sessions.map(\.sessionId), ["b", "a"])
    }

    func testExpiredSessionsAreIgnored() {
        let now = Date()
        let stale = SignalEvent(
            source: "codex",
            adapter: "test",
            sessionId: "stale",
            state: .blocked,
            reason: SignalReason.approval,
            updatedAt: now.addingTimeInterval(-10),
            ttlMs: 1
        )
        let idle = SignalEvent(
            source: "codex",
            adapter: "test",
            sessionId: "idle",
            state: .idle,
            reason: SignalReason.done,
            updatedAt: now
        )

        let snapshot = SignalSnapshot.make(from: [stale, idle], now: now)
        XCTAssertEqual(snapshot.globalState, .idle)
        XCTAssertEqual(snapshot.sessions.map(\.sessionId), ["idle"])
    }

    func testSnapshotMaxSessionsKeepsActiveAndRecentSessions() {
        let now = Date()
        let snapshot = SignalSnapshot.make(
            from: [
                SignalEvent(
                    source: "test",
                    adapter: "unit",
                    sessionId: "old",
                    state: .idle,
                    reason: SignalReason.done,
                    updatedAt: now.addingTimeInterval(-30)
                ),
                SignalEvent(
                    source: "test",
                    adapter: "unit",
                    sessionId: "new",
                    state: .idle,
                    reason: SignalReason.done,
                    updatedAt: now
                ),
                SignalEvent(
                    source: "test",
                    adapter: "unit",
                    sessionId: "active",
                    state: .working,
                    reason: SignalReason.thinking,
                    updatedAt: now.addingTimeInterval(-60)
                )
            ],
            now: now,
            maxSessions: 2
        )

        XCTAssertEqual(snapshot.sessions.map(\.sessionId), ["active", "new"])
    }

    func testEventJSONRoundTrip() throws {
        let event = SignalEvent(
            source: "codex",
            adapter: "codex-hooks",
            sessionId: "session-abc",
            workspace: "/tmp/project",
            state: .working,
            reason: SignalReason.tool,
            message: "Running tests",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            ttlMs: 300_000,
            metadata: ["toolName": .string("Bash")]
        )

        let data = try SignalJSON.encode(event)
        let decoded = try SignalJSON.decode(SignalEvent.self, from: data)
        XCTAssertEqual(decoded, event)
    }

    func testSocketOwnershipConflictsIncludeBindAddressInUse() {
        XCTAssertTrue(VibeSignalError.socketAlreadyRunning("/tmp/vibe-signal.sock").isSocketOwnershipConflict)
        XCTAssertTrue(VibeSignalError.posix("bind", EADDRINUSE).isSocketOwnershipConflict)
        XCTAssertFalse(VibeSignalError.posix("listen", EADDRINUSE).isSocketOwnershipConflict)
    }

    func testStatusStoreCallbackRunsOutsideInternalQueue() {
        let store = StatusStore()
        let now = Date()
        store.onSnapshotChanged = { _ in
            _ = store.snapshot(now: now)
        }

        store.apply(SignalEvent(
            source: "callback",
            adapter: "test",
            sessionId: "reentrant",
            state: .working,
            reason: SignalReason.thinking,
            updatedAt: now
        ))

        XCTAssertEqual(store.snapshot(now: now).globalState, .working)
    }

    func testStatusStoreCapsRetainedSessions() {
        let store = StatusStore(configuration: StatusStore.Configuration(maxSessions: 2))
        let now = Date()
        for index in 0..<4 {
            store.apply(SignalEvent(
                source: "bounded",
                adapter: "test",
                sessionId: "session-\(index)",
                state: .idle,
                reason: SignalReason.done,
                updatedAt: now.addingTimeInterval(Double(index))
            ))
        }

        XCTAssertEqual(store.snapshot(now: now).sessions.count, 2)
    }

    func testCodexSessionMonitorEmitsActiveSeedAndIdleCompletion() throws {
        let codexHome = try makeTemporaryCodexHome()
        let sessionID = "019e5982-0b7c-78e2-a08b-771afa1bc9e4"
        let sessionFile = try writeSessionFile(
            codexHome: codexHome,
            sessionID: sessionID,
            lines: [
                #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e5982-0b7c-78e2-a08b-771afa1bc9e4","cwd":"/tmp/project","originator":"codex-tui"}}"#,
                #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#,
                #"{"timestamp":"2026-05-24T10:23:01.894Z","type":"response_item","payload":{"type":"web_search_call","status":"completed"}}"#
            ]
        )

        var events: [SignalEvent] = []
        let monitor = CodexSessionMonitor(
            configuration: CodexSessionMonitor.Configuration(
                codexHomeURL: codexHome,
                pollInterval: 60,
                refreshInterval: 600,
                blockedEmitDelay: 0
            )
        ) { event in
            events.append(event)
        }

        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.sessionId, sessionID)
        XCTAssertEqual(events.last?.workspace, "/tmp/project")
        XCTAssertEqual(events.last?.state, .working)
        XCTAssertEqual(events.last?.message, "Searching the web")

        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:25.259Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#,
            to: sessionFile
        )

        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.sessionId, sessionID)
        XCTAssertEqual(events.last?.state, .idle)
        XCTAssertEqual(events.last?.message, "Turn finished")
    }

    func testCodexSessionMonitorDoesNotEmitCompletedSeededSession() throws {
        let codexHome = try makeTemporaryCodexHome()
        let sessionID = "019e5960-c9bb-7430-bb20-1ec631a3bf46"
        _ = try writeSessionFile(
            codexHome: codexHome,
            sessionID: sessionID,
            lines: [
                #"{"timestamp":"2026-05-24T09:46:34.819Z","type":"session_meta","payload":{"id":"019e5960-c9bb-7430-bb20-1ec631a3bf46","cwd":"/tmp/project","originator":"codex-tui"}}"#,
                #"{"timestamp":"2026-05-24T09:46:34.823Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#,
                #"{"timestamp":"2026-05-24T09:47:44.640Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#
            ]
        )

        var events: [SignalEvent] = []
        let monitor = CodexSessionMonitor(
            configuration: CodexSessionMonitor.Configuration(
                codexHomeURL: codexHome,
                blockedEmitDelay: 0
            )
        ) { event in
            events.append(event)
        }

        monitor.scanOnceForTesting()
        XCTAssertTrue(events.isEmpty)
    }

    func testCodexSessionMonitorDetectsResumedIdleFileFromDiscovery() throws {
        let codexHome = try makeTemporaryCodexHome()
        let sessionID = "019e5991-047d-7252-a0a6-6be8c94e92b3"
        let sessionFile = try writeSessionFile(
            codexHome: codexHome,
            sessionID: sessionID,
            lines: [
                #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e5991-047d-7252-a0a6-6be8c94e92b3","cwd":"/tmp/resumed","originator":"codex-tui"}}"#,
                #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#,
                #"{"timestamp":"2026-05-24T10:23:25.259Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#
            ]
        )

        var events: [SignalEvent] = []
        let monitor = CodexSessionMonitor(
            configuration: CodexSessionMonitor.Configuration(
                codexHomeURL: codexHome,
                pollInterval: 60,
                coldFilePollInterval: 3_600,
                refreshInterval: 600
            )
        ) { event in
            events.append(event)
        }

        monitor.scanOnceForTesting()
        XCTAssertTrue(events.isEmpty)

        try appendLine(
            #"{"timestamp":"2026-05-24T10:24:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-2"}}"#,
            to: sessionFile
        )

        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.sessionId, sessionID)
        XCTAssertEqual(events.last?.state, .working)
    }

    func testCodexSessionMonitorEscalatedCommandBlocksThenReturnsToWorking() throws {
        let codexHome = try makeTemporaryCodexHome()
        let sessionID = "019e5993-3333-7444-8555-666677778888"
        let sessionFile = try writeSessionFile(
            codexHome: codexHome,
            sessionID: sessionID,
            lines: [
                #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e5993-3333-7444-8555-666677778888","cwd":"/tmp/approval","originator":"codex-tui"}}"#,
                #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-approval"}}"#
            ]
        )

        var events: [SignalEvent] = []
        let monitor = CodexSessionMonitor(
            configuration: CodexSessionMonitor.Configuration(
                codexHomeURL: codexHome,
                pollInterval: 60,
                refreshInterval: 600
            )
        ) { event in
            events.append(event)
        }

        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.state, .working)

        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:00.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"sleep 5\",\"sandbox_permissions\":\"require_escalated\",\"justification\":\"test\"}","call_id":"call-approval"}}"#,
            to: sessionFile
        )
        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.state, .blocked)
        XCTAssertEqual(events.last?.reason, SignalReason.approval)

        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:05.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-approval","output":"done"}}"#,
            to: sessionFile
        )
        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.state, .working)
    }

    func testCodexSessionMonitorRestoresSeededEscalatedCommandAsBlocked() throws {
        let codexHome = try makeTemporaryCodexHome()
        let sessionID = "019e5994-3333-7444-8555-666677778888"
        _ = try writeSessionFile(
            codexHome: codexHome,
            sessionID: sessionID,
            lines: [
                #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e5994-3333-7444-8555-666677778888","cwd":"/tmp/seeded-approval","originator":"codex-tui"}}"#,
                #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-seeded-approval"}}"#,
                #"{"timestamp":"2026-05-24T10:23:00.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"sleep 5\",\"sandbox_permissions\":\"require_escalated\",\"justification\":\"test\"}","call_id":"call-seeded-approval"}}"#
            ]
        )

        var events: [SignalEvent] = []
        let monitor = CodexSessionMonitor(
            configuration: CodexSessionMonitor.Configuration(codexHomeURL: codexHome)
        ) { event in
            events.append(event)
        }

        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.state, .blocked)
        XCTAssertEqual(events.last?.reason, SignalReason.approval)
    }

    func testCodexSessionMonitorDoesNotRestoreCompletedEscalatedCommandAsBlocked() throws {
        let codexHome = try makeTemporaryCodexHome()
        let sessionID = "019e5997-3333-7444-8555-666677778888"
        _ = try writeSessionFile(
            codexHome: codexHome,
            sessionID: sessionID,
            lines: [
                #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e5997-3333-7444-8555-666677778888","cwd":"/tmp/completed-approval","originator":"codex-tui"}}"#,
                #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-completed-approval"}}"#,
                #"{"timestamp":"2026-05-24T10:23:00.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"true\",\"sandbox_permissions\":\"require_escalated\",\"justification\":\"test\"}","call_id":"call-completed-approval"}}"#,
                #"{"timestamp":"2026-05-24T10:23:01.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-completed-approval","output":"done"}}"#
            ]
        )

        var events: [SignalEvent] = []
        let monitor = CodexSessionMonitor(
            configuration: CodexSessionMonitor.Configuration(codexHomeURL: codexHome)
        ) { event in
            events.append(event)
        }

        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.state, .working)
        XCTAssertNotEqual(events.last?.reason, SignalReason.approval)
    }

    func testCodexSessionMonitorDebouncesFastEscalatedCommandOutput() throws {
        let codexHome = try makeTemporaryCodexHome()
        let sessionID = "019e5995-3333-7444-8555-666677778888"
        let sessionFile = try writeSessionFile(
            codexHome: codexHome,
            sessionID: sessionID,
            lines: [
                #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e5995-3333-7444-8555-666677778888","cwd":"/tmp/auto-review","originator":"codex-tui"}}"#,
                #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-auto-review"}}"#
            ]
        )

        var events: [SignalEvent] = []
        let monitor = CodexSessionMonitor(
            configuration: CodexSessionMonitor.Configuration(
                codexHomeURL: codexHome,
                pollInterval: 60,
                refreshInterval: 600,
                blockedEmitDelay: 10
            )
        ) { event in
            events.append(event)
        }

        monitor.scanOnceForTesting(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(events.last?.state, .working)

        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:00.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"true\",\"sandbox_permissions\":\"require_escalated\",\"justification\":\"test\"}","call_id":"call-auto-review"}}"#,
            to: sessionFile
        )
        monitor.scanOnceForTesting(now: Date(timeIntervalSince1970: 101))
        XCTAssertEqual(events.last?.state, .working)
        XCTAssertFalse(events.contains(where: { $0.state == .blocked }))

        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:01.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-auto-review","output":"done"}}"#,
            to: sessionFile
        )
        monitor.scanOnceForTesting(now: Date(timeIntervalSince1970: 102))
        XCTAssertEqual(events.last?.state, .working)
        XCTAssertFalse(events.contains(where: { $0.state == .blocked }))
    }

    func testCodexSessionMonitorEmitsEscalatedCommandAfterDebounceDelay() throws {
        let codexHome = try makeTemporaryCodexHome()
        let sessionID = "019e5996-3333-7444-8555-666677778888"
        let sessionFile = try writeSessionFile(
            codexHome: codexHome,
            sessionID: sessionID,
            lines: [
                #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e5996-3333-7444-8555-666677778888","cwd":"/tmp/manual-approval","originator":"codex-tui"}}"#,
                #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-manual-approval"}}"#
            ]
        )

        var events: [SignalEvent] = []
        let monitor = CodexSessionMonitor(
            configuration: CodexSessionMonitor.Configuration(
                codexHomeURL: codexHome,
                pollInterval: 60,
                refreshInterval: 600,
                blockedEmitDelay: 2
            )
        ) { event in
            events.append(event)
        }

        monitor.scanOnceForTesting(now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(events.last?.state, .working)

        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:00.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"sleep 5\",\"sandbox_permissions\":\"require_escalated\",\"justification\":\"test\"}","call_id":"call-manual-approval"}}"#,
            to: sessionFile
        )
        monitor.scanOnceForTesting(now: Date(timeIntervalSince1970: 201))
        XCTAssertEqual(events.last?.state, .working)

        monitor.scanOnceForTesting(now: Date(timeIntervalSince1970: 204))
        XCTAssertEqual(events.last?.state, .blocked)
        XCTAssertEqual(events.last?.reason, SignalReason.approval)
    }

    func testCodexSessionMonitorSeedFindsCompletionBeforeLargeNoisyTail() throws {
        let codexHome = try makeTemporaryCodexHome()
        let sessionID = "019e5992-3333-7444-8555-666677778888"
        let noisyTail = (0..<1_200).map { index in
            #"{"timestamp":"2026-05-24T10:24:00.000Z","type":"response_item","payload":{"type":"output_text","text":""# +
                String(repeating: "x", count: 320) +
                #"\#(index)"}}"#
        }
        _ = try writeSessionFile(
            codexHome: codexHome,
            sessionID: sessionID,
            lines: [
                #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e5992-3333-7444-8555-666677778888","cwd":"/tmp/noisy","originator":"codex-tui"}}"#,
                #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#,
                #"{"timestamp":"2026-05-24T10:23:25.259Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#
            ] + noisyTail
        )

        var events: [SignalEvent] = []
        let monitor = CodexSessionMonitor(
            configuration: CodexSessionMonitor.Configuration(codexHomeURL: codexHome)
        ) { event in
            events.append(event)
        }

        monitor.scanOnceForTesting()
        XCTAssertTrue(events.isEmpty)
    }

    private func makeTemporaryCodexHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeSignalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func writeSessionFile(codexHome: URL, sessionID: String, lines: [String]) throws -> URL {
        let sessionsDirectory = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("05", isDirectory: true)
            .appendingPathComponent("24", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

        let file = sessionsDirectory
            .appendingPathComponent("rollout-2026-05-24T18-22-35-\(sessionID).jsonl")
        try (lines.joined(separator: "\n") + "\n").data(using: .utf8)?.write(to: file)
        return file
    }

    private func appendLine(_ line: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer {
            try? handle.close()
        }
        try handle.seekToEnd()
        handle.write(Data((line + "\n").utf8))
    }
}
