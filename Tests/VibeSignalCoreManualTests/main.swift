import Darwin
import Foundation
import VibeSignalCore

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected {
        fputs("Assertion failed: \(message). Expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

func assertTrue(_ condition: Bool, _ message: String) {
    if !condition {
        fputs("Assertion failed: \(message)\n", stderr)
        exit(1)
    }
}

final class EventRecorder {
    private let lock = NSLock()
    private var storage: [SignalEvent] = []

    func append(_ event: SignalEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var last: SignalEvent? {
        lock.lock()
        defer { lock.unlock() }
        return storage.last
    }
}

func waitUntil(timeout: TimeInterval = 2, _ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() {
            return true
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return predicate()
}

func writeSessionFile(codexHome: URL, sessionID: String, lines: [String]) throws -> URL {
    let sessionsDirectory = codexHome
        .appendingPathComponent("sessions", isDirectory: true)
        .appendingPathComponent("2026", isDirectory: true)
        .appendingPathComponent("05", isDirectory: true)
        .appendingPathComponent("24", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

    let file = sessionsDirectory
        .appendingPathComponent("rollout-2026-05-24T18-22-35-\(sessionID).jsonl")
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
    return file
}

func appendLine(_ line: String, to file: URL) throws {
    let handle = try FileHandle(forWritingTo: file)
    defer {
        try? handle.close()
    }
    try handle.seekToEnd()
    handle.write(Data((line + "\n").utf8))
}

let now = Date()

let emptySnapshot = SignalSnapshot.make(from: [], now: now)
assertEqual(emptySnapshot.globalState, .unknown, "empty session set should be unknown")

let working = SignalEvent(
    source: "codex",
    adapter: "test",
    sessionId: "working",
    state: .working,
    reason: SignalReason.thinking,
    updatedAt: now
)
let blocked = SignalEvent(
    source: "codex",
    adapter: "test",
    sessionId: "blocked",
    state: .blocked,
    reason: SignalReason.approval,
    updatedAt: now
)
let snapshot = SignalSnapshot.make(from: [working, blocked], now: now)
assertEqual(snapshot.globalState, .blocked, "blocked should outrank working")
assertEqual(snapshot.sessions.map(\.sessionId), ["blocked", "working"], "sessions should sort by state priority")

let unknown = SignalEvent(
    source: "codex",
    adapter: "test",
    sessionId: "unknown",
    state: .unknown,
    reason: SignalReason.stale,
    updatedAt: now
)
let uncertainSnapshot = SignalSnapshot.make(from: [working, unknown], now: now)
assertEqual(uncertainSnapshot.globalState, .working, "verified working should outrank a transient unknown session")

let uncertainIdle = SignalEvent(
    source: "codex",
    adapter: "test",
    sessionId: "idle",
    state: .idle,
    reason: SignalReason.done,
    updatedAt: now
)
let uncertainIdleSnapshot = SignalSnapshot.make(from: [uncertainIdle, unknown], now: now)
assertEqual(uncertainIdleSnapshot.globalState, .unknown, "unknown should still prevent an unverified green state")

let expired = SignalEvent(
    source: "codex",
    adapter: "test",
    sessionId: "expired",
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
let expirySnapshot = SignalSnapshot.make(from: [expired, idle], now: now)
assertEqual(expirySnapshot.globalState, .idle, "expired blocked sessions should be ignored")
assertEqual(expirySnapshot.sessions.map(\.sessionId), ["idle"], "expired sessions should be absent")

let boundedSnapshot = SignalSnapshot.make(
    from: [
        SignalEvent(source: "test", adapter: "manual", sessionId: "old", state: .idle, reason: SignalReason.done, updatedAt: now.addingTimeInterval(-30)),
        SignalEvent(source: "test", adapter: "manual", sessionId: "new", state: .idle, reason: SignalReason.done, updatedAt: now),
        SignalEvent(source: "test", adapter: "manual", sessionId: "active", state: .working, reason: SignalReason.thinking, updatedAt: now.addingTimeInterval(-60))
    ],
    now: now,
    maxSessions: 2
)
assertEqual(boundedSnapshot.sessions.map(\.sessionId), ["active", "new"], "bounded snapshots should keep active and recent sessions")

let jsonEvent = SignalEvent(
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
let encoded = try SignalJSON.encode(jsonEvent)
let decoded = try SignalJSON.decode(SignalEvent.self, from: encoded)
assertEqual(decoded, jsonEvent, "JSON event should round trip")

let hookInput = Data(#"{"session_id":"thread-hook","turn_id":"turn-hook","cwd":"/tmp/hook","hook_event_name":"UserPromptSubmit","prompt":"private prompt must not be forwarded"}"#.utf8)
let hookEvent = try CodexHookBridge.makeEvent(from: hookInput, now: now)
assertEqual(hookEvent?.state, .working, "user prompt hook should provide a low-latency working hint")
assertEqual(hookEvent?.sessionId, "thread-hook", "hook should preserve the official session id")
assertTrue(hookEvent?.metadata?["prompt"] == nil, "hook bridge must not forward prompt content")

let permissionHookInput = Data(#"{"session_id":"thread-hook","turn_id":"turn-hook","cwd":"/tmp/hook","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"private"}}"#.utf8)
let permissionHookEvent = try CodexHookBridge.makeEvent(from: permissionHookInput, now: now)
assertEqual(permissionHookEvent?.state, .working, "permission hook alone must not claim user attention")
assertTrue(permissionHookEvent?.metadata?["tool_input"] == nil, "hook bridge must not forward tool input")

let subagentHookInput = Data(#"{"session_id":"thread-child","turn_id":"turn-child","agent_id":"agent-child","agent_type":"guardian","cwd":"/tmp/hook","hook_event_name":"UserPromptSubmit","prompt":"private prompt"}"#.utf8)
let subagentHookEvent = try CodexHookBridge.makeEvent(from: subagentHookInput, now: now)
assertTrue(subagentHookEvent == nil, "subagent hooks should not create standalone sidebar sessions")

let hookConfigRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("VibeSignalManualTests-Hooks-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: hookConfigRoot, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: hookConfigRoot)
}
let hookConfigURL = hookConfigRoot.appendingPathComponent("hooks.json")
let existingHooks = #"{"hooks":{"SessionStart":[{"matcher":"resume","hooks":[{"type":"command","command":"/usr/bin/true"}]}]}}"#
try Data(existingHooks.utf8).write(to: hookConfigURL)
let hookManager = CodexHookConfigurationManager(
    configurationURL: hookConfigURL,
    executableURL: URL(fileURLWithPath: "/usr/bin/true")
)
try hookManager.install()
assertTrue(hookManager.isInstalled(), "hook integration should install all lifecycle events")
try hookManager.uninstall()
assertTrue(!hookManager.isInstalled(), "hook integration should uninstall its own handlers")
let preservedHookConfig = try String(contentsOf: hookConfigURL)
assertTrue(preservedHookConfig.contains("resume"), "hook integration must preserve existing Codex hooks")

assertTrue(
    VibeSignalError.socketAlreadyRunning("/tmp/vibe-signal.sock").isSocketOwnershipConflict,
    "socketAlreadyRunning should be treated as an ownership conflict"
)
assertTrue(
    VibeSignalError.posix("bind", EADDRINUSE).isSocketOwnershipConflict,
    "bind EADDRINUSE should be treated as an ownership conflict"
)
assertTrue(
    !VibeSignalError.posix("listen", EADDRINUSE).isSocketOwnershipConflict,
    "non-bind errors should not be treated as duplicate app instances"
)

let store = StatusStore()
store.apply(SignalEvent(
    source: "codex",
    adapter: "codex-session-monitor",
    sessionId: "old",
    state: .working,
    reason: SignalReason.thinking,
    updatedAt: now
))
store.apply(SignalEvent(
    source: "demo",
    adapter: "manual-test",
    sessionId: "keep",
    state: .idle,
    reason: SignalReason.done,
    updatedAt: now
))
store.removeEvents(source: "codex", adapter: "codex-session-monitor", now: now)
assertEqual(store.snapshot(now: now).sessions.map(\.sessionKey), ["demo:keep"], "monitor cleanup should keep unrelated events")

let boundedStore = StatusStore(configuration: StatusStore.Configuration(maxSessions: 2))
for index in 0..<4 {
    boundedStore.apply(SignalEvent(
        source: "bounded",
        adapter: "manual-test",
        sessionId: "session-\(index)",
        state: .idle,
        reason: SignalReason.done,
        updatedAt: now.addingTimeInterval(Double(index))
    ))
}
assertEqual(boundedStore.snapshot(now: now).sessions.count, 2, "status store should cap retained sessions")

let reentrantStore = StatusStore()
reentrantStore.onSnapshotChanged = { _ in
    _ = reentrantStore.snapshot()
}
reentrantStore.apply(SignalEvent(
    source: "callback",
    adapter: "manual-test",
    sessionId: "reentrant",
    state: .working,
    reason: SignalReason.thinking,
    updatedAt: now
))
assertEqual(
    reentrantStore.snapshot(now: now).globalState,
    .working,
    "store callbacks should run outside the internal queue"
)

let codexHome = FileManager.default.temporaryDirectory
    .appendingPathComponent("VibeSignalManualTests-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: codexHome)
}

let codexSessionID = "019e5982-0b7c-78e2-a08b-771afa1bc9e4"
let sidebarIndexLine = #"{"id":"019e5982-0b7c-78e2-a08b-771afa1bc9e4","thread_name":"Sidebar Session Title","updated_at":"2026-05-24T10:22:52Z"}"# + "\n"
try Data(sidebarIndexLine.utf8).write(
    to: codexHome.appendingPathComponent("session_index.jsonl")
)
let codexSessionFile = try writeSessionFile(
    codexHome: codexHome,
    sessionID: codexSessionID,
    lines: [
        #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e5982-0b7c-78e2-a08b-771afa1bc9e4","cwd":"/tmp/project","originator":"codex-tui"}}"#,
        #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#,
        #"{"timestamp":"2026-05-24T10:23:01.894Z","type":"response_item","payload":{"type":"web_search_call","status":"completed"}}"#
    ]
)

let recorder = EventRecorder()
let monitor = CodexSessionMonitor(
    configuration: CodexSessionMonitor.Configuration(
        codexHomeURL: codexHome,
        pollInterval: 0.05,
        discoveryInterval: 0.05,
        refreshInterval: 60
    )
) { event in
    recorder.append(event)
}
monitor.start()

assertTrue(
    waitUntil {
        recorder.last?.state == .working
    },
    "Codex monitor should emit working for a seeded active session"
)
assertEqual(recorder.last?.sessionId, codexSessionID, "Codex monitor should preserve session id")
assertEqual(recorder.last?.workspace, "/tmp/project", "Codex monitor should read workspace")
assertEqual(recorder.last?.title, "Sidebar Session Title", "Codex monitor should use the Codex sidebar title")
assertEqual(recorder.last?.message, "Searching the web", "Codex monitor should surface web activity")

try appendLine(
    #"{"timestamp":"2026-05-24T10:23:25.259Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#,
    to: codexSessionFile
)

assertTrue(
    waitUntil {
        recorder.last?.state == .idle
    },
    "Codex monitor should emit idle when a task completes"
)
assertEqual(recorder.last?.message, "Turn finished", "Codex monitor should explain completion")
monitor.stop()

let subagentCodexHome = FileManager.default.temporaryDirectory
    .appendingPathComponent("VibeSignalManualTests-Subagent-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: subagentCodexHome, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: subagentCodexHome)
}
_ = try writeSessionFile(
    codexHome: subagentCodexHome,
    sessionID: "019e5982-7777-7888-8999-000011112222",
    lines: [
        #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e5982-7777-7888-8999-000011112222","cwd":"/tmp/subagent","originator":"Codex Desktop","source":{"subagent":{"other":"guardian"}}}}"#,
        #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-subagent"}}"#
    ]
)
let subagentRecorder = EventRecorder()
let subagentMonitor = CodexSessionMonitor(
    configuration: CodexSessionMonitor.Configuration(
        codexHomeURL: subagentCodexHome,
        pollInterval: 0.05,
        discoveryInterval: 0.05
    )
) { event in
    subagentRecorder.append(event)
}
subagentMonitor.start()
Thread.sleep(forTimeInterval: 0.2)
assertTrue(subagentRecorder.last == nil, "internal subagents should not appear as sidebar sessions")
subagentMonitor.stop()

let approvalCodexHome = FileManager.default.temporaryDirectory
    .appendingPathComponent("VibeSignalManualTests-Approval-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: approvalCodexHome, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: approvalCodexHome)
}

let approvalSessionID = "019e5993-3333-7444-8555-666677778888"
let approvalSessionFile = try writeSessionFile(
    codexHome: approvalCodexHome,
    sessionID: approvalSessionID,
    lines: [
        #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e5993-3333-7444-8555-666677778888","cwd":"/tmp/approval","originator":"codex-tui"}}"#,
        #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-approval"}}"#
    ]
)
let approvalRecorder = EventRecorder()
let approvalMonitor = CodexSessionMonitor(
    configuration: CodexSessionMonitor.Configuration(
        codexHomeURL: approvalCodexHome,
        pollInterval: 0.05,
        discoveryInterval: 0.05,
        refreshInterval: 600,
        blockedEmitDelay: 0
    )
) { event in
    approvalRecorder.append(event)
}
approvalMonitor.start()
assertTrue(
    waitUntil {
        approvalRecorder.last?.state == .working
    },
    "approval session should start as working"
)

try appendLine(
    #"{"timestamp":"2026-05-24T10:23:00.000Z","type":"event_msg","payload":{"type":"exec_approval_request","call_id":"call-approval","turn_id":"turn-approval"}}"#,
    to: approvalSessionFile
)
assertTrue(
    waitUntil {
        approvalRecorder.last?.state == .blocked
    },
    "escalated command should emit blocked approval"
)
assertEqual(approvalRecorder.last?.reason, SignalReason.approval, "approval block should use approval reason")

try appendLine(
    #"{"timestamp":"2026-05-24T10:23:03.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-unrelated","output":"done"}}"#,
    to: approvalSessionFile
)
Thread.sleep(forTimeInterval: 0.2)
assertEqual(approvalRecorder.last?.state, .blocked, "unrelated tool output must not clear approval")

try appendLine(
    #"{"timestamp":"2026-05-24T10:23:05.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-approval","output":"done"}}"#,
    to: approvalSessionFile
)
assertTrue(
    waitUntil {
        approvalRecorder.last?.state == .working
    },
    "tool output should release blocked state back to working"
)
approvalMonitor.stop()

let seededApprovalCodexHome = FileManager.default.temporaryDirectory
    .appendingPathComponent("VibeSignalManualTests-SeededApproval-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: seededApprovalCodexHome, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: seededApprovalCodexHome)
}

let seededApprovalSessionID = "019e5994-3333-7444-8555-666677778888"
_ = try writeSessionFile(
    codexHome: seededApprovalCodexHome,
    sessionID: seededApprovalSessionID,
    lines: [
        #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e5994-3333-7444-8555-666677778888","cwd":"/tmp/seeded-approval","originator":"codex-tui"}}"#,
        #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-seeded-approval"}}"#,
        #"{"timestamp":"2026-05-24T10:23:00.000Z","type":"event_msg","payload":{"type":"exec_approval_request","call_id":"call-seeded-approval","turn_id":"turn-seeded-approval"}}"#
    ]
)
let seededApprovalRecorder = EventRecorder()
let seededApprovalMonitor = CodexSessionMonitor(
    configuration: CodexSessionMonitor.Configuration(
        codexHomeURL: seededApprovalCodexHome,
        blockedEmitDelay: 0
    )
) { event in
    seededApprovalRecorder.append(event)
}
seededApprovalMonitor.start()
assertTrue(
    waitUntil {
        seededApprovalRecorder.last?.state == .blocked
    },
    "seeded approval sessions should restore as blocked"
)
seededApprovalMonitor.stop()

let completedApprovalCodexHome = FileManager.default.temporaryDirectory
    .appendingPathComponent("VibeSignalManualTests-CompletedApproval-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: completedApprovalCodexHome, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: completedApprovalCodexHome)
}

let completedApprovalSessionID = "019e5997-3333-7444-8555-666677778888"
_ = try writeSessionFile(
    codexHome: completedApprovalCodexHome,
    sessionID: completedApprovalSessionID,
    lines: [
        #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e5997-3333-7444-8555-666677778888","cwd":"/tmp/completed-approval","originator":"codex-tui"}}"#,
        #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-completed-approval"}}"#,
        #"{"timestamp":"2026-05-24T10:23:00.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"true\",\"sandbox_permissions\":\"require_escalated\",\"justification\":\"test\"}","call_id":"call-completed-approval"}}"#,
        #"{"timestamp":"2026-05-24T10:23:01.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-completed-approval","output":"done"}}"#
    ]
)
let completedApprovalRecorder = EventRecorder()
let completedApprovalMonitor = CodexSessionMonitor(
    configuration: CodexSessionMonitor.Configuration(codexHomeURL: completedApprovalCodexHome)
) { event in
    completedApprovalRecorder.append(event)
}
completedApprovalMonitor.start()
assertTrue(
    waitUntil {
        completedApprovalRecorder.last?.state == .working
    },
    "completed approval sessions should not restore as blocked"
)
assertTrue(
    completedApprovalRecorder.last?.reason != SignalReason.approval,
    "completed approval sessions should not keep approval reason"
)
completedApprovalMonitor.stop()

let autoReviewCodexHome = FileManager.default.temporaryDirectory
    .appendingPathComponent("VibeSignalManualTests-AutoReview-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: autoReviewCodexHome, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: autoReviewCodexHome)
}

let autoReviewSessionID = "019e5995-3333-7444-8555-666677778888"
let autoReviewSessionFile = try writeSessionFile(
    codexHome: autoReviewCodexHome,
    sessionID: autoReviewSessionID,
    lines: [
        #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e5995-3333-7444-8555-666677778888","cwd":"/tmp/auto-review","originator":"codex-tui"}}"#,
        #"{"timestamp":"2026-05-24T10:22:51.645Z","type":"turn_context","payload":{"turn_id":"turn-auto-review","cwd":"/tmp/auto-review","approval_policy":"on-request","approvals_reviewer":"auto_review"}}"#,
        #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-auto-review"}}"#
    ]
)
let autoReviewRecorder = EventRecorder()
let autoReviewMonitor = CodexSessionMonitor(
    configuration: CodexSessionMonitor.Configuration(
        codexHomeURL: autoReviewCodexHome,
        pollInterval: 0.05,
        discoveryInterval: 0.05,
        refreshInterval: 600,
        blockedEmitDelay: 10
    )
) { event in
    autoReviewRecorder.append(event)
}
autoReviewMonitor.start()
assertTrue(
    waitUntil {
        autoReviewRecorder.last?.state == .working
    },
    "auto review test should start as working"
)

try appendLine(
    #"{"timestamp":"2026-05-24T10:23:00.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const r = await tools.exec_command({cmd: \"true\", sandbox_permissions: \"require_escalated\"});","call_id":"call-auto-review"}}"#,
    to: autoReviewSessionFile
)
Thread.sleep(forTimeInterval: 0.2)
assertTrue(autoReviewRecorder.last?.state != .blocked, "blocked state should be debounced before reaching the UI")

try appendLine(
    #"{"timestamp":"2026-05-24T10:23:01.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call-auto-review","output":"done"}}"#,
    to: autoReviewSessionFile
)
assertTrue(
    waitUntil {
        autoReviewRecorder.last?.state == .working
    },
    "fast auto review output should keep the UI working instead of red"
)
autoReviewMonitor.stop()

let resumedCodexHome = FileManager.default.temporaryDirectory
    .appendingPathComponent("VibeSignalManualTests-Resume-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: resumedCodexHome, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: resumedCodexHome)
}

let resumedSessionID = "019e5991-047d-7252-a0a6-6be8c94e92b3"
let resumedSessionFile = try writeSessionFile(
    codexHome: resumedCodexHome,
    sessionID: resumedSessionID,
    lines: [
        #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e5991-047d-7252-a0a6-6be8c94e92b3","cwd":"/tmp/resumed","originator":"codex-tui"}}"#,
        #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#,
        #"{"timestamp":"2026-05-24T10:23:25.259Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#
    ]
)

let resumedRecorder = EventRecorder()
let resumedMonitor = CodexSessionMonitor(
    configuration: CodexSessionMonitor.Configuration(
        codexHomeURL: resumedCodexHome,
        pollInterval: 0.05,
        discoveryInterval: 0.05,
        coldFilePollInterval: 3_600,
        refreshInterval: 600
    )
) { event in
    resumedRecorder.append(event)
}
resumedMonitor.start()
Thread.sleep(forTimeInterval: 0.2)
assertTrue(resumedRecorder.last == nil, "completed seeded sessions should stay quiet")

try appendLine(
    #"{"timestamp":"2026-05-24T10:24:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-2"}}"#,
    to: resumedSessionFile
)
assertTrue(
    waitUntil {
        resumedRecorder.last?.state == .working
    },
    "discovery should notice resumed idle files"
)
assertEqual(resumedRecorder.last?.sessionId, resumedSessionID, "discovery should notice resumed idle files")
assertEqual(resumedRecorder.last?.state, .working, "resumed sessions should become working")
resumedMonitor.stop()

let noisyCodexHome = FileManager.default.temporaryDirectory
    .appendingPathComponent("VibeSignalManualTests-Noisy-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: noisyCodexHome, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: noisyCodexHome)
}

let noisySessionID = "019e5992-3333-7444-8555-666677778888"
let noisyTail = (0..<1_200).map { index in
    #"{"timestamp":"2026-05-24T10:24:00.000Z","type":"response_item","payload":{"type":"output_text","text":""# +
        String(repeating: "x", count: 320) +
        #"\#(index)"}}"#
}
let noisySessionFile = try writeSessionFile(
    codexHome: noisyCodexHome,
    sessionID: noisySessionID,
    lines: [
        #"{"timestamp":"2026-05-24T10:22:51.643Z","type":"session_meta","payload":{"id":"019e5992-3333-7444-8555-666677778888","cwd":"/tmp/noisy","originator":"codex-tui"}}"#,
        #"{"timestamp":"2026-05-24T10:22:51.647Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#,
        #"{"timestamp":"2026-05-24T10:23:25.259Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#
    ] + noisyTail
)
_ = noisySessionFile

let noisyRecorder = EventRecorder()
let noisyMonitor = CodexSessionMonitor(
    configuration: CodexSessionMonitor.Configuration(
        codexHomeURL: noisyCodexHome,
        pollInterval: 0.05,
        discoveryInterval: 0.05,
        refreshInterval: 600
    )
) { event in
    noisyRecorder.append(event)
}
noisyMonitor.start()
Thread.sleep(forTimeInterval: 0.2)
assertTrue(noisyRecorder.last == nil, "reverse seed scan should find completion before a large noisy tail")
noisyMonitor.stop()

print("manual core tests passed")
