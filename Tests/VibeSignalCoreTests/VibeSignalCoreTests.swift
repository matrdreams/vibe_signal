import XCTest
import Darwin
@testable import VibeSignalCore

final class VibeSignalCoreTests: XCTestCase {
    func testEmptySessionsAreUnknown() {
        let snapshot = SignalSnapshot.make(from: [])
        XCTAssertEqual(snapshot.globalState, .unknown)
    }

    func testKnownActiveSessionOutranksUnknownWhileIdleDoesNot() {
        let now = Date()
        let unknown = SignalEvent(
            source: "codex",
            adapter: "test",
            sessionId: "unknown",
            state: .unknown,
            reason: SignalReason.stale,
            updatedAt: now
        )
        let working = SignalEvent(
            source: "codex",
            adapter: "test",
            sessionId: "working",
            state: .working,
            reason: SignalReason.thinking,
            updatedAt: now
        )

        let idle = SignalEvent(
            source: "codex",
            adapter: "test",
            sessionId: "idle",
            state: .idle,
            reason: SignalReason.done,
            updatedAt: now
        )

        XCTAssertEqual(SignalSnapshot.make(from: [working, unknown], now: now).globalState, .working)
        XCTAssertEqual(SignalSnapshot.make(from: [idle, unknown], now: now).globalState, .unknown)
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
            title: "Run the test suite",
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

    func testCodexHookBridgeForwardsOnlyStatusMetadata() throws {
        let input = Data(#"{"session_id":"thread-hook","turn_id":"turn-hook","cwd":"/tmp/project","hook_event_name":"UserPromptSubmit","prompt":"private prompt"}"#.utf8)
        let event = try XCTUnwrap(CodexHookBridge.makeEvent(
            from: input,
            now: Date(timeIntervalSince1970: 100)
        ))

        XCTAssertEqual(event.state, .working)
        XCTAssertEqual(event.sessionId, "thread-hook")
        XCTAssertEqual(event.workspace, "/tmp/project")
        XCTAssertEqual(event.metadata?["turn_id"], .string("turn-hook"))
        XCTAssertNil(event.metadata?["prompt"])
    }

    func testPermissionHookIsActivityHintRatherThanBlockedClaim() throws {
        let input = Data(#"{"session_id":"thread-hook","turn_id":"turn-hook","cwd":"/tmp/project","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"private"}}"#.utf8)
        let event = try XCTUnwrap(CodexHookBridge.makeEvent(from: input))

        XCTAssertEqual(event.state, .working)
        XCTAssertEqual(event.reason, SignalReason.approval)
        XCTAssertNil(event.metadata?["tool_input"])
    }

    func testCodexHookBridgeIgnoresSubagentSessions() throws {
        let input = Data(#"{"session_id":"thread-child","turn_id":"turn-child","agent_id":"agent-child","agent_type":"guardian","cwd":"/tmp/project","hook_event_name":"UserPromptSubmit","prompt":"private prompt"}"#.utf8)
        XCTAssertNil(try CodexHookBridge.makeEvent(from: input))

        let subagentStart = Data(#"{"session_id":"thread-root","turn_id":"turn-root","agent_id":"agent-child","agent_type":"guardian","cwd":"/tmp/project","hook_event_name":"SubagentStart"}"#.utf8)
        XCTAssertNil(try CodexHookBridge.makeEvent(from: subagentStart))
    }

    func testCodexHookConfigurationPreservesExistingHooks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeSignalHookTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let configurationURL = directory.appendingPathComponent("hooks.json")
        let existing = #"{"hooks":{"SessionStart":[{"matcher":"resume","hooks":[{"type":"command","command":"/usr/bin/true"}]}]}}"#
        try Data(existing.utf8).write(to: configurationURL)

        let manager = CodexHookConfigurationManager(
            configurationURL: configurationURL,
            executableURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        try manager.install()
        XCTAssertTrue(manager.isInstalled())

        try manager.uninstall()
        XCTAssertFalse(manager.isInstalled())
        let saved = try String(contentsOf: configurationURL)
        XCTAssertTrue(saved.contains(#""matcher" : "resume""#))
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

    func testStatusStoreKeepsTitleAndNavigationMetadataAcrossAdapterUpdates() {
        let store = StatusStore()
        let now = Date()
        store.apply(SignalEvent(
            source: "codex",
            adapter: "codex-notify",
            sessionId: "thread-1",
            title: "Fix login",
            workspace: "/tmp/project",
            state: .working,
            reason: SignalReason.thinking,
            updatedAt: now,
            metadata: ["jump_url": .string("codex://threads/thread-1")]
        ), now: now)

        store.apply(SignalEvent(
            source: "codex",
            adapter: "codex-session-monitor",
            sessionId: "thread-1",
            state: .blocked,
            reason: SignalReason.approval,
            updatedAt: now.addingTimeInterval(1)
        ), now: now.addingTimeInterval(1))

        let event = store.snapshot(now: now.addingTimeInterval(1)).sessions.first
        XCTAssertEqual(event?.title, "Fix login")
        XCTAssertEqual(event?.workspace, "/tmp/project")
        XCTAssertEqual(event?.metadata?["jump_url"], .string("codex://threads/thread-1"))
    }

    func testStatusStoreRejectsLateHookAndOlderEvents() {
        let store = StatusStore()
        let now = Date(timeIntervalSince1970: 100)
        store.apply(SignalEvent(
            source: "codex",
            adapter: "codex-session-monitor",
            sessionId: "thread-1",
            state: .idle,
            reason: SignalReason.done,
            updatedAt: now,
            metadata: ["state_certainty": .string("verified")]
        ), now: now)

        store.apply(SignalEvent(
            source: "codex",
            adapter: "codex-hooks",
            sessionId: "thread-1",
            state: .working,
            reason: SignalReason.thinking,
            updatedAt: now.addingTimeInterval(1),
            metadata: ["state_certainty": .string("candidate")]
        ), now: now.addingTimeInterval(1))
        XCTAssertEqual(store.snapshot(now: now.addingTimeInterval(1)).globalState, .idle)

        store.apply(SignalEvent(
            source: "codex",
            adapter: "codex-session-monitor",
            sessionId: "thread-1",
            state: .working,
            reason: SignalReason.thinking,
            updatedAt: now.addingTimeInterval(2)
        ), now: now.addingTimeInterval(2))
        store.apply(SignalEvent(
            source: "codex",
            adapter: "codex-session-monitor",
            sessionId: "thread-1",
            state: .idle,
            reason: SignalReason.done,
            updatedAt: now.addingTimeInterval(1)
        ), now: now.addingTimeInterval(2))
        XCTAssertEqual(store.snapshot(now: now.addingTimeInterval(2)).globalState, .working)

        store.apply(SignalEvent(
            source: "codex",
            adapter: "codex-hooks",
            sessionId: "thread-1",
            state: .unknown,
            reason: SignalReason.sessionEnd,
            updatedAt: now.addingTimeInterval(3),
            metadata: ["hook_event": .string("SessionEnd")]
        ), now: now.addingTimeInterval(3))
        XCTAssertEqual(store.snapshot(now: now.addingTimeInterval(3)).globalState, .unknown)
    }

    func testCodexSessionMonitorEmitsActiveSeedAndIdleCompletion() throws {
        let codexHome = try makeTemporaryCodexHome()
        let sessionID = "019e5982-0b7c-78e2-a08b-771afa1bc9e4"
        let headPadding = String(repeating: "x", count: 70_000)
        let sessionFile = try writeSessionFile(
            codexHome: codexHome,
            sessionID: sessionID,
            lines: [
                #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e5982-0b7c-78e2-a08b-771afa1bc9e4","cwd":"/tmp/project","originator":"codex-tui"}}"#,
                headPadding,
                #"{"timestamp":"2026-05-24T10:22:51.645Z","type":"event_msg","payload":{"type":"user_message","message":"Context notes\n## My request:\nFix login on macOS"}}"#,
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
        XCTAssertEqual(events.last?.title, "Fix login on macOS")
        XCTAssertEqual(events.last?.state, .working)
        XCTAssertEqual(events.last?.message, "Searching the web")
        XCTAssertEqual(
            events.last?.metadata?["jump_url"],
            .string("codex://threads/\(sessionID)")
        )

        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:25.259Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#,
            to: sessionFile
        )

        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.sessionId, sessionID)
        XCTAssertEqual(events.last?.state, .idle)
        XCTAssertEqual(events.last?.message, "Turn finished")
    }

    func testCodexSessionMonitorUsesAndRefreshesCodexSidebarTitle() throws {
        let codexHome = try makeTemporaryCodexHome()
        let sessionID = "019e5982-1111-7222-8333-444455556666"
        _ = try writeSessionFile(
            codexHome: codexHome,
            sessionID: sessionID,
            lines: [
                #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e5982-1111-7222-8333-444455556666","cwd":"/tmp/sidebar","originator":"Codex Desktop","source":"vscode"}}"#,
                #"{"timestamp":"2026-05-24T10:22:51.645Z","type":"event_msg","payload":{"type":"user_message","message":"Raw user prompt that does not match the sidebar"}}"#,
                #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#
            ]
        )

        var events: [SignalEvent] = []
        let monitor = CodexSessionMonitor(
            configuration: CodexSessionMonitor.Configuration(
                codexHomeURL: codexHome,
                refreshInterval: 600
            )
        ) { events.append($0) }

        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.title, "Raw user prompt that does not match the sidebar")

        let indexURL = codexHome.appendingPathComponent("session_index.jsonl")
        let indexLine = #"{"id":"019e5982-1111-7222-8333-444455556666","thread_name":"Canonical Sidebar Title","updated_at":"2026-05-24T10:22:52Z"}"# + "\n"
        try Data(indexLine.utf8).write(to: indexURL)

        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.title, "Canonical Sidebar Title")
        XCTAssertEqual(
            events.last?.metadata?["title_source"],
            .string("codex_session_index")
        )
    }

    func testCodexSessionMonitorDoesNotEmitInternalSubagentAsSidebarSession() throws {
        let codexHome = try makeTemporaryCodexHome()
        let sessionID = "019e5982-7777-7888-8999-000011112222"
        _ = try writeSessionFile(
            codexHome: codexHome,
            sessionID: sessionID,
            lines: [
                #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e5982-7777-7888-8999-000011112222","cwd":"/tmp/sidebar","originator":"Codex Desktop","source":{"subagent":{"other":"guardian"}}}}"#,
                #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-subagent"}}"#
            ]
        )

        var events: [SignalEvent] = []
        let monitor = CodexSessionMonitor(
            configuration: CodexSessionMonitor.Configuration(codexHomeURL: codexHome)
        ) { events.append($0) }

        monitor.scanOnceForTesting()
        XCTAssertTrue(events.isEmpty)
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
                refreshInterval: 600,
                blockedEmitDelay: 0
            )
        ) { event in
            events.append(event)
        }

        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.state, .working)

        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:00.000Z","type":"event_msg","payload":{"type":"exec_approval_request","call_id":"call-approval","turn_id":"turn-approval"}}"#,
            to: sessionFile
        )
        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.state, .blocked)
        XCTAssertEqual(events.last?.reason, SignalReason.approval)

        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:03.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-unrelated","output":"done"}}"#,
            to: sessionFile
        )
        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.state, .blocked)

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
                #"{"timestamp":"2026-05-24T10:23:00.000Z","type":"event_msg","payload":{"type":"exec_approval_request","call_id":"call-seeded-approval","turn_id":"turn-seeded-approval"}}"#
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
        XCTAssertEqual(events.last?.state, .blocked)
        XCTAssertEqual(events.last?.reason, SignalReason.approval)
    }

    func testCodexSessionMonitorRestoresLegacyUserReviewedApprovalAsBlocked() throws {
        let codexHome = try makeTemporaryCodexHome()
        let sessionID = "019e5994-aaaa-7444-8555-666677778888"
        _ = try writeSessionFile(
            codexHome: codexHome,
            sessionID: sessionID,
            lines: [
                #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e5994-aaaa-7444-8555-666677778888","cwd":"/tmp/seeded-user-review","originator":"codex-tui"}}"#,
                #"{"timestamp":"2026-05-24T10:22:51.645Z","type":"turn_context","payload":{"turn_id":"turn-seeded-user","cwd":"/tmp/seeded-user-review","approval_policy":"on-request","approvals_reviewer":"user"}}"#,
                #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-seeded-user"}}"#,
                #"{"timestamp":"2026-05-24T10:23:00.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"sleep 5\",\"sandbox_permissions\":\"require_escalated\",\"justification\":\"test\"}","call_id":"call-seeded-user"}}"#
            ]
        )

        var events: [SignalEvent] = []
        let monitor = CodexSessionMonitor(
            configuration: CodexSessionMonitor.Configuration(
                codexHomeURL: codexHome,
                blockedEmitDelay: 0
            )
        ) { events.append($0) }

        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.state, .blocked)
        XCTAssertEqual(events.last?.metadata?["state_certainty"], .string("inferred"))
    }

    func testCodexSessionMonitorDoesNotRestoreAutoReviewedApprovalAsBlocked() throws {
        let codexHome = try makeTemporaryCodexHome()
        let sessionID = "019e5994-bbbb-7444-8555-666677778888"
        _ = try writeSessionFile(
            codexHome: codexHome,
            sessionID: sessionID,
            lines: [
                #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e5994-bbbb-7444-8555-666677778888","cwd":"/tmp/seeded-auto-review","originator":"codex-tui"}}"#,
                #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-seeded-auto"}}"#,
                #"{"timestamp":"2026-05-24T10:22:51.648Z","type":"turn_context","payload":{"turn_id":"turn-seeded-auto","cwd":"/tmp/seeded-auto-review","approval_policy":"on-request","approvals_reviewer":"auto_review"}}"#,
                #"{"timestamp":"2026-05-24T10:23:00.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"true\",\"sandbox_permissions\":\"require_escalated\",\"justification\":\"test\"}","call_id":"call-seeded-auto"}}"#
            ]
        )

        var events: [SignalEvent] = []
        let monitor = CodexSessionMonitor(
            configuration: CodexSessionMonitor.Configuration(codexHomeURL: codexHome)
        ) { events.append($0) }

        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.state, .working)
        XCTAssertFalse(events.contains(where: { $0.state == .blocked }))
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
                #"{"timestamp":"2026-05-24T10:22:51.645Z","type":"turn_context","payload":{"turn_id":"turn-auto-review","cwd":"/tmp/auto-review","approval_policy":"on-request","approvals_reviewer":"auto_review"}}"#,
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
            #"{"timestamp":"2026-05-24T10:23:00.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const r = await tools.exec_command({cmd: \"true\", sandbox_permissions: \"require_escalated\"});","call_id":"call-auto-review"}}"#,
            to: sessionFile
        )
        monitor.scanOnceForTesting(now: Date(timeIntervalSince1970: 101))
        XCTAssertEqual(events.last?.state, .working)
        XCTAssertFalse(events.contains(where: { $0.state == .blocked }))

        monitor.scanOnceForTesting(now: Date(timeIntervalSince1970: 115))
        XCTAssertEqual(events.last?.state, .working)
        XCTAssertFalse(events.contains(where: { $0.state == .blocked }))

        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:01.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call-auto-review","output":"done"}}"#,
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
                #"{"timestamp":"2026-05-24T10:22:51.645Z","type":"turn_context","payload":{"turn_id":"turn-manual-approval","cwd":"/tmp/manual-approval","approval_policy":"on-request","approvals_reviewer":"user"}}"#,
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

    func testCodexSessionMonitorTracksBlockingQuestionByCallID() throws {
        let codexHome = try makeTemporaryCodexHome()
        let sessionID = "019e5998-3333-7444-8555-666677778888"
        let sessionFile = try writeSessionFile(
            codexHome: codexHome,
            sessionID: sessionID,
            lines: [
                #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e5998-3333-7444-8555-666677778888","cwd":"/tmp/question","originator":"codex-tui"}}"#,
                #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-question"}}"#
            ]
        )

        var events: [SignalEvent] = []
        let monitor = CodexSessionMonitor(
            configuration: CodexSessionMonitor.Configuration(
                codexHomeURL: codexHome,
                refreshInterval: 600,
                blockedEmitDelay: 0
            )
        ) { events.append($0) }

        monitor.scanOnceForTesting()
        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:00.000Z","type":"event_msg","payload":{"type":"request_user_input","call_id":"call-question","turn_id":"turn-question","isBlocking":true,"questions":[]}}"#,
            to: sessionFile
        )
        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.state, .blocked)
        XCTAssertEqual(events.last?.reason, SignalReason.question)

        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:01.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-question","output":"answered"}}"#,
            to: sessionFile
        )
        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.state, .working)
    }

    func testCodexSessionMonitorCoversPatchPermissionAndElicitationRequests() throws {
        let codexHome = try makeTemporaryCodexHome()
        let sessionID = "019e5998-cccc-7444-8555-666677778888"
        let sessionFile = try writeSessionFile(
            codexHome: codexHome,
            sessionID: sessionID,
            lines: [
                #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e5998-cccc-7444-8555-666677778888","cwd":"/tmp/interactions","originator":"codex-tui"}}"#,
                #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-interactions"}}"#
            ]
        )

        var events: [SignalEvent] = []
        let monitor = CodexSessionMonitor(
            configuration: CodexSessionMonitor.Configuration(
                codexHomeURL: codexHome,
                refreshInterval: 600,
                blockedEmitDelay: 0
            )
        ) { events.append($0) }
        monitor.scanOnceForTesting()

        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:00.000Z","type":"event_msg","payload":{"type":"apply_patch_approval_request","call_id":"call-patch","turn_id":"turn-interactions"}}"#,
            to: sessionFile
        )
        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.state, .blocked)
        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:01.000Z","type":"event_msg","payload":{"type":"patch_apply_begin","call_id":"call-patch","turn_id":"turn-interactions"}}"#,
            to: sessionFile
        )
        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.state, .working)

        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:02.000Z","type":"event_msg","payload":{"type":"request_permissions","call_id":"call-permission","turn_id":"turn-interactions"}}"#,
            to: sessionFile
        )
        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.state, .blocked)
        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:03.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-permission","output":"done"}}"#,
            to: sessionFile
        )
        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.state, .working)

        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:04.000Z","type":"event_msg","payload":{"type":"elicitation_request","id":"request-1","turn_id":"turn-interactions","server_name":"example"}}"#,
            to: sessionFile
        )
        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.state, .blocked)
        XCTAssertEqual(events.last?.reason, SignalReason.question)
        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:05.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"request-1","output":"done"}}"#,
            to: sessionFile
        )
        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.state, .working)
    }

    func testCodexSessionMonitorDoesNotBlockForNonBlockingQuestion() throws {
        let codexHome = try makeTemporaryCodexHome()
        let sessionID = "019e5999-3333-7444-8555-666677778888"
        let sessionFile = try writeSessionFile(
            codexHome: codexHome,
            sessionID: sessionID,
            lines: [
                #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e5999-3333-7444-8555-666677778888","cwd":"/tmp/nonblocking","originator":"codex-tui"}}"#,
                #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-nonblocking"}}"#
            ]
        )

        var events: [SignalEvent] = []
        let monitor = CodexSessionMonitor(
            configuration: CodexSessionMonitor.Configuration(
                codexHomeURL: codexHome,
                refreshInterval: 600,
                blockedEmitDelay: 0
            )
        ) { events.append($0) }

        monitor.scanOnceForTesting()
        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:00.000Z","type":"event_msg","payload":{"type":"request_user_input","call_id":"call-nonblocking","turn_id":"turn-nonblocking","isBlocking":false,"questions":[]}}"#,
            to: sessionFile
        )
        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.state, .working)
        XCTAssertFalse(events.contains(where: { $0.state == .blocked }))
    }

    func testCodexSessionMonitorEmitsTerminalError() throws {
        let codexHome = try makeTemporaryCodexHome()
        let sessionID = "019e6000-3333-7444-8555-666677778888"
        let sessionFile = try writeSessionFile(
            codexHome: codexHome,
            sessionID: sessionID,
            lines: [
                #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e6000-3333-7444-8555-666677778888","cwd":"/tmp/error","originator":"codex-tui"}}"#,
                #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-error"}}"#
            ]
        )

        var events: [SignalEvent] = []
        let monitor = CodexSessionMonitor(
            configuration: CodexSessionMonitor.Configuration(codexHomeURL: codexHome)
        ) { events.append($0) }

        monitor.scanOnceForTesting()
        try appendLine(
            #"{"timestamp":"2026-05-24T10:22:59.000Z","type":"event_msg","payload":{"type":"error","message":"Cannot steer this turn","codex_error_info":{"active_turn_not_steerable":{"turn_kind":"review"}}}}"#,
            to: sessionFile
        )
        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.state, .working)

        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:00.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-error","error":"Connection failed"}}"#,
            to: sessionFile
        )
        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.state, .error)
        XCTAssertEqual(events.last?.message, "Connection failed")
    }

    func testCodexSessionMonitorFailsClosedWhenActivityGoesStale() throws {
        let codexHome = try makeTemporaryCodexHome()
        let sessionID = "019e6001-3333-7444-8555-666677778888"
        _ = try writeSessionFile(
            codexHome: codexHome,
            sessionID: sessionID,
            lines: [
                #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e6001-3333-7444-8555-666677778888","cwd":"/tmp/stale","originator":"codex-tui"}}"#,
                #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-stale"}}"#
            ]
        )

        var events: [SignalEvent] = []
        let monitor = CodexSessionMonitor(
            configuration: CodexSessionMonitor.Configuration(
                codexHomeURL: codexHome,
                refreshInterval: 600,
                staleAfter: 1
            )
        ) { events.append($0) }
        let initial = Date()

        monitor.scanOnceForTesting(now: initial)
        XCTAssertEqual(events.last?.state, .working)
        monitor.scanOnceForTesting(now: initial.addingTimeInterval(2))
        XCTAssertEqual(events.last?.state, .unknown)
        XCTAssertEqual(events.last?.reason, SignalReason.stale)
    }

    func testCodexSessionMonitorRetiresDesktopTurnWhenHostExits() throws {
        let codexHome = try makeTemporaryCodexHome()
        let sessionID = "019e6002-3333-7444-8555-666677778888"
        let sessionFile = try writeSessionFile(
            codexHome: codexHome,
            sessionID: sessionID,
            lines: [
                #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e6002-3333-7444-8555-666677778888","cwd":"/tmp/desktop-exit","originator":"Codex Desktop"}}"#,
                #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-desktop-exit"}}"#
            ]
        )

        var hostLaunchDates: [Date]? = [.distantPast]
        var events: [SignalEvent] = []
        let monitor = CodexSessionMonitor(
            configuration: CodexSessionMonitor.Configuration(
                codexHomeURL: codexHome,
                refreshInterval: 600,
                staleAfter: 600,
                desktopOrphanGrace: 1
            ),
            desktopHostLaunchDates: { hostLaunchDates }
        ) { events.append($0) }
        let initial = Date()

        monitor.scanOnceForTesting(now: initial)
        XCTAssertEqual(events.last?.state, .working)

        hostLaunchDates = []
        monitor.scanOnceForTesting(now: initial.addingTimeInterval(2))
        XCTAssertEqual(events.last?.state, .working)

        hostLaunchDates = [.distantPast]
        monitor.scanOnceForTesting(now: initial.addingTimeInterval(3))
        XCTAssertEqual(events.last?.state, .working)

        hostLaunchDates = []
        monitor.scanOnceForTesting(now: initial.addingTimeInterval(4))
        XCTAssertEqual(events.last?.state, .working)
        monitor.scanOnceForTesting(now: initial.addingTimeInterval(6))
        XCTAssertEqual(events.last?.state, .unknown)
        XCTAssertEqual(events.last?.reason, SignalReason.interrupted)
        XCTAssertEqual(events.last?.metadata?["state_evidence"], .string("desktop_host_exit"))

        hostLaunchDates = [.distantPast]
        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:01.000Z","type":"event_msg","payload":{"type":"exec_command_begin","call_id":"call-resumed","turn_id":"turn-desktop-exit"}}"#,
            to: sessionFile
        )
        monitor.scanOnceForTesting(now: initial.addingTimeInterval(7))
        XCTAssertEqual(events.last?.state, .working)
        XCTAssertEqual(events.last?.reason, SignalReason.command)
    }

    func testCodexSessionMonitorRetiresDesktopTurnFromPreviousHostLaunch() throws {
        let codexHome = try makeTemporaryCodexHome()
        let sessionID = "019e6003-3333-7444-8555-666677778888"
        _ = try writeSessionFile(
            codexHome: codexHome,
            sessionID: sessionID,
            lines: [
                #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e6003-3333-7444-8555-666677778888","cwd":"/tmp/desktop-restart","originator":"codex_work_desktop"}}"#,
                #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-before-restart"}}"#
            ]
        )

        var hostLaunchDates: [Date]? = [.distantPast]
        var events: [SignalEvent] = []
        let monitor = CodexSessionMonitor(
            configuration: CodexSessionMonitor.Configuration(
                codexHomeURL: codexHome,
                refreshInterval: 600,
                staleAfter: 600,
                desktopOrphanGrace: 1
            ),
            desktopHostLaunchDates: { hostLaunchDates }
        ) { events.append($0) }
        let initial = Date()

        monitor.scanOnceForTesting(now: initial)
        XCTAssertEqual(events.last?.state, .working)

        hostLaunchDates = [initial.addingTimeInterval(1)]
        monitor.scanOnceForTesting(now: initial.addingTimeInterval(2))
        XCTAssertEqual(events.last?.state, .unknown)
        XCTAssertEqual(events.last?.reason, SignalReason.interrupted)
    }

    func testCodexSessionMonitorDoesNotApplyDesktopExitToTUISession() throws {
        let codexHome = try makeTemporaryCodexHome()
        let sessionID = "019e6005-3333-7444-8555-666677778888"
        _ = try writeSessionFile(
            codexHome: codexHome,
            sessionID: sessionID,
            lines: [
                #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e6005-3333-7444-8555-666677778888","cwd":"/tmp/tui","originator":"codex-tui"}}"#,
                #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-tui"}}"#
            ]
        )

        var events: [SignalEvent] = []
        let monitor = CodexSessionMonitor(
            configuration: CodexSessionMonitor.Configuration(
                codexHomeURL: codexHome,
                refreshInterval: 600,
                staleAfter: 600,
                desktopOrphanGrace: 1
            ),
            desktopHostLaunchDates: { [] }
        ) { events.append($0) }
        let initial = Date()

        monitor.scanOnceForTesting(now: initial)
        monitor.scanOnceForTesting(now: initial.addingTimeInterval(2))
        XCTAssertEqual(events.last?.state, .working)
    }

    func testCodexSessionMonitorNewTurnSupersedesUnfinishedTurn() throws {
        let codexHome = try makeTemporaryCodexHome()
        let sessionID = "019e6004-3333-7444-8555-666677778888"
        let sessionFile = try writeSessionFile(
            codexHome: codexHome,
            sessionID: sessionID,
            lines: [
                #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e6004-3333-7444-8555-666677778888","cwd":"/tmp/new-turn","originator":"Codex Desktop"}}"#,
                #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-before-exit"}}"#
            ]
        )

        var events: [SignalEvent] = []
        let monitor = CodexSessionMonitor(
            configuration: CodexSessionMonitor.Configuration(codexHomeURL: codexHome)
        ) { events.append($0) }

        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.state, .working)

        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-after-relaunch"}}"#,
            to: sessionFile
        )
        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:05.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-after-relaunch"}}"#,
            to: sessionFile
        )
        monitor.scanOnceForTesting()

        XCTAssertEqual(events.last?.state, .idle)
        XCTAssertEqual(events.last?.reason, SignalReason.done)
    }

    func testCodexSessionMonitorReadsLargeSessionMetadataLine() throws {
        let codexHome = try makeTemporaryCodexHome()
        let sessionID = "019e6006-3333-7444-8555-666677778888"
        let padding = String(repeating: "x", count: 100_000)
        let metadata = #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"padding":""#
            + padding
            + #"","id":"019e6006-3333-7444-8555-666677778888","cwd":"/tmp/large-metadata","originator":"codex-tui"}}"#
        _ = try writeSessionFile(
            codexHome: codexHome,
            sessionID: sessionID,
            lines: [
                metadata,
                #"{"timestamp":"2026-05-24T10:22:51Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-large-metadata"}}"#
            ]
        )

        var events: [SignalEvent] = []
        let monitor = CodexSessionMonitor(
            configuration: CodexSessionMonitor.Configuration(codexHomeURL: codexHome)
        ) { events.append($0) }

        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.state, .working)
        XCTAssertEqual(events.last?.workspace, "/tmp/large-metadata")
        XCTAssertEqual(
            events.last?.startedAt,
            ISO8601DateFormatter().date(from: "2026-05-24T10:22:51Z")
        )
    }

    func testCodexSessionMonitorAcceptsJSONWhitespaceWithoutMatchingTypePrefixes() throws {
        let codexHome = try makeTemporaryCodexHome()
        let sessionID = "019e6010-3333-7444-8555-666677778888"
        let sessionFile = try writeSessionFile(
            codexHome: codexHome,
            sessionID: sessionID,
            lines: [
                #"{"timestamp":"2026-05-24T10:22:51.643Z","type" : "session_meta","payload":{"id":"019e6010-3333-7444-8555-666677778888","cwd":"/tmp/兼容性","originator":"codex-tui"}}"#,
                #"{"timestamp":"2026-05-24T10:22:52.000Z","type":"event_msg","payload":{"type" : "task_started_extra","turn_id":"not-a-turn"}}"#
            ]
        )

        var events: [SignalEvent] = []
        let monitor = CodexSessionMonitor(
            configuration: CodexSessionMonitor.Configuration(codexHomeURL: codexHome)
        ) { events.append($0) }

        monitor.scanOnceForTesting()
        XCTAssertTrue(events.isEmpty)

        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:00.000Z","type":"response_item","payload":{"type":"message","role" : "user","content":[{"type":"input_text","text":"优化中文日志兼容性"}]}}"#,
            to: sessionFile
        )
        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:01.000Z","type":"event_msg","payload":{"type" : "task_started","turn_id":"turn-whitespace"}}"#,
            to: sessionFile
        )
        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:02.000Z","type":"response_item","payload":{"type" : "web_search_call","status":"completed"}}"#,
            to: sessionFile
        )

        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.state, .working)
        XCTAssertEqual(events.last?.workspace, "/tmp/兼容性")
        XCTAssertEqual(events.last?.title, "优化中文日志兼容性")
        XCTAssertEqual(events.last?.message, "Searching the web")

        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:03.000Z","type" : "event_msg","payload":{"type" : "task_complete","turn_id":"turn-whitespace"}}"#,
            to: sessionFile
        )
        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.state, .idle)
        XCTAssertEqual(events.last?.reason, SignalReason.done)
    }

    func testCodexSessionMonitorCompletesRecordSplitAcrossStartup() throws {
        let codexHome = try makeTemporaryCodexHome()
        let sessionID = "019e6009-3333-7444-8555-666677778888"
        let sessionFile = try writeSessionFile(
            codexHome: codexHome,
            sessionID: sessionID,
            lines: [
                #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e6009-3333-7444-8555-666677778888","cwd":"/tmp/partial-record","originator":"codex-tui"}}"#,
                #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-partial"}}"#
            ]
        )
        let completion = #"{"timestamp":"2026-05-24T10:23:00.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-partial"}}"#
        let split = completion.index(completion.startIndex, offsetBy: completion.count / 2)
        try appendText(String(completion[..<split]), to: sessionFile)

        var events: [SignalEvent] = []
        let monitor = CodexSessionMonitor(
            configuration: CodexSessionMonitor.Configuration(codexHomeURL: codexHome)
        ) { events.append($0) }
        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.state, .working)

        try appendText(String(completion[split...]) + "\n", to: sessionFile)
        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.state, .idle)
    }

    func testCodexSessionMonitorDoesNotSkipTaskStartBeforeLargeBurst() throws {
        let codexHome = try makeTemporaryCodexHome()
        let sessionID = "019e6007-3333-7444-8555-666677778888"
        let sessionFile = try writeSessionFile(
            codexHome: codexHome,
            sessionID: sessionID,
            lines: [
                #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e6007-3333-7444-8555-666677778888","cwd":"/tmp/large-burst","originator":"codex-tui"}}"#,
                #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-old"}}"#,
                #"{"timestamp":"2026-05-24T10:22:52.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-old"}}"#
            ]
        )

        var events: [SignalEvent] = []
        let monitor = CodexSessionMonitor(
            configuration: CodexSessionMonitor.Configuration(codexHomeURL: codexHome)
        ) { events.append($0) }
        monitor.scanOnceForTesting()
        XCTAssertTrue(events.isEmpty)

        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-large-burst"}}"#,
            to: sessionFile
        )
        let largeOutput = String(repeating: "x", count: 5_000_000)
        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:01.000Z","type":"response_item","payload":{"type":"output_text","text":""#
                + largeOutput
                + #""}}"#,
            to: sessionFile
        )

        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.state, .working)
    }

    func testCodexSessionMonitorResolvesInteractionAcrossLargeLineChunks() throws {
        let codexHome = try makeTemporaryCodexHome()
        let sessionID = "019e6008-3333-7444-8555-666677778888"
        let sessionFile = try writeSessionFile(
            codexHome: codexHome,
            sessionID: sessionID,
            lines: [
                #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e6008-3333-7444-8555-666677778888","cwd":"/tmp/large-line","originator":"codex-tui"}}"#,
                #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-large-line"}}"#,
                #"{"timestamp":"2026-05-24T10:22:52.000Z","type":"event_msg","payload":{"type":"request_user_input","call_id":"call-large-line","turn_id":"turn-large-line","isBlocking":true}}"#
            ]
        )

        var events: [SignalEvent] = []
        let monitor = CodexSessionMonitor(
            configuration: CodexSessionMonitor.Configuration(
                codexHomeURL: codexHome,
                refreshInterval: 600,
                maxIncrementalBytes: 400_000,
                blockedEmitDelay: 0
            )
        ) { events.append($0) }
        monitor.scanOnceForTesting()
        XCTAssertEqual(events.last?.state, .blocked)

        let largeOutput = String(repeating: "x", count: 1_200_000)
        try appendLine(
            #"{"timestamp":"2026-05-24T10:23:00.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-large-line","output":""#
                + largeOutput
                + #""}}"#,
            to: sessionFile
        )
        for _ in 0..<4 {
            monitor.scanOnceForTesting()
        }

        XCTAssertEqual(events.last?.state, .working)
        XCTAssertEqual(events.last?.reason, SignalReason.tool)
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
        try appendText(line + "\n", to: file)
    }

    private func appendText(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer {
            try? handle.close()
        }
        try handle.seekToEnd()
        handle.write(Data(text.utf8))
    }
}
