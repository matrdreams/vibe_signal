import Foundation

public enum CodexHookBridge {
    public static func makeEvent(from data: Data, now: Date = Date()) throws -> SignalEvent? {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventName = payload["hook_event_name"] as? String,
              let sessionID = payload["session_id"] as? String,
              !sessionID.isEmpty else {
            return nil
        }

        let isSubagentEvent = eventName == "SubagentStart" || eventName == "SubagentStop"
        let hasSubagentID = (payload["agent_id"] as? String)?.isEmpty == false
        guard !isSubagentEvent, !hasSubagentID else {
            // Root rollouts remain the status anchor. Publishing child hook
            // events as standalone sessions creates rows that do not exist in
            // the Codex sidebar.
            return nil
        }

        let mapping: (state: SignalState, reason: String, message: String, ttl: Int)
        switch eventName {
        case "UserPromptSubmit":
            mapping = (.working, SignalReason.thinking, "Starting Codex turn", 30_000)
        case "PreToolUse":
            mapping = toolMapping(payload: payload, prefix: "Running")
        case "PermissionRequest":
            // PermissionRequest fires before Codex decides whether an automatic
            // reviewer or the user will handle it. It is activity evidence, not
            // proof that human attention is required.
            mapping = (.working, SignalReason.approval, "Resolving permission request", 30_000)
        case "PostToolUse":
            mapping = toolMapping(payload: payload, prefix: "Processing")
        case "PreCompact", "PostCompact":
            mapping = (.working, SignalReason.thinking, "Compacting conversation context", 30_000)
        case "Stop":
            // Another Stop hook can still continue the turn. The rollout's
            // task_complete event is the authority for green/idle.
            mapping = (.working, SignalReason.thinking, "Finishing Codex turn", 15_000)
        case "SessionStart":
            mapping = (.unknown, SignalReason.sessionStart, "Session opened; waiting for turn state", 60_000)
        case "SessionEnd":
            mapping = (.unknown, SignalReason.sessionEnd, "Session ended", 60_000)
        default:
            return nil
        }

        var metadata: [String: JSONValue] = [
            "hook_event": .string(eventName),
            "state_evidence": .string("codex_hook"),
            "state_certainty": .string("candidate"),
            "jump_url": .string("codex://threads/\(sessionID)"),
            "host_bundle_id": .string("com.openai.codex")
        ]
        if let turnID = payload["turn_id"] as? String, !turnID.isEmpty {
            metadata["turn_id"] = .string(turnID)
        }
        if let toolName = payload["tool_name"] as? String, !toolName.isEmpty {
            metadata["tool_name"] = .string(toolName)
        }

        return SignalEvent(
            source: "codex",
            adapter: "codex-hooks",
            sessionId: sessionID,
            workspace: payload["cwd"] as? String,
            state: mapping.state,
            reason: mapping.reason,
            message: mapping.message,
            startedAt: mapping.state.isActive ? now : nil,
            updatedAt: now,
            ttlMs: mapping.ttl,
            metadata: metadata
        )
    }

    private static func toolMapping(
        payload: [String: Any],
        prefix: String
    ) -> (state: SignalState, reason: String, message: String, ttl: Int) {
        let toolName = (payload["tool_name"] as? String) ?? ""
        if toolName == "Bash" || toolName == "exec" || toolName == "exec_command" {
            return (.working, SignalReason.command, "\(prefix) command", 30_000)
        }
        if toolName == "apply_patch" || toolName == "Edit" || toolName == "Write" {
            return (.working, SignalReason.fileChange, "\(prefix) file changes", 30_000)
        }
        return (.working, SignalReason.tool, "\(prefix) tool", 30_000)
    }
}

public struct CodexHookConfigurationManager {
    public static let integrationID = "com.vibe-signal.codex-status"
    public static let eventNames = [
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "Stop"
    ]

    public let configurationURL: URL
    public let executableURL: URL
    private let fileManager: FileManager

    public init(
        configurationURL: URL = CodexSessionMonitor.defaultCodexHomeURL()
            .appendingPathComponent("hooks.json"),
        executableURL: URL,
        fileManager: FileManager = .default
    ) {
        self.configurationURL = configurationURL
        self.executableURL = executableURL
        self.fileManager = fileManager
    }

    public func isInstalled() -> Bool {
        guard let root = try? loadRoot(),
              let hooks = root["hooks"] as? [String: Any] else {
            return false
        }

        return Self.eventNames.allSatisfy { eventName in
            guard let groups = hooks[eventName] as? [[String: Any]] else {
                return false
            }
            return groups.contains { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else {
                    return false
                }
                return handlers.contains(where: isIntegrationHandler)
            }
        }
    }

    public func install() throws {
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw CodexHookConfigurationError.missingExecutable(executableURL.path)
        }

        var root = try loadRoot()
        var hooks = try hooksDictionary(from: root)
        removeIntegrationHandlers(from: &hooks)

        let handler: [String: Any] = [
            "type": "command",
            "command": integrationCommand,
            "timeout": 2
        ]
        for eventName in Self.eventNames {
            let groupsValue = hooks[eventName]
            guard groupsValue == nil || groupsValue is [[String: Any]] else {
                throw CodexHookConfigurationError.invalidConfiguration
            }
            var groups = (groupsValue as? [[String: Any]]) ?? []
            groups.append(["hooks": [handler]])
            hooks[eventName] = groups
        }

        root["hooks"] = hooks
        try save(root)
    }

    public func uninstall() throws {
        guard fileManager.fileExists(atPath: configurationURL.path) else {
            return
        }
        var root = try loadRoot()
        guard var hooks = root["hooks"] as? [String: Any] else {
            return
        }
        removeIntegrationHandlers(from: &hooks)
        root["hooks"] = hooks
        try save(root)
    }

    private var integrationCommand: String {
        "\(shellQuote(executableURL.path)) codex-hook --integration-id \(Self.integrationID)"
    }

    private func isIntegrationHandler(_ handler: [String: Any]) -> Bool {
        guard handler["type"] as? String == "command",
              let command = handler["command"] as? String else {
            return false
        }
        return command.contains("codex-hook --integration-id \(Self.integrationID)")
    }

    private func removeIntegrationHandlers(from hooks: inout [String: Any]) {
        for eventName in Array(hooks.keys) {
            guard let groups = hooks[eventName] as? [[String: Any]] else {
                continue
            }

            let filteredGroups = groups.compactMap { group -> [String: Any]? in
                guard let handlers = group["hooks"] as? [[String: Any]] else {
                    return group
                }
                let filteredHandlers = handlers.filter { !isIntegrationHandler($0) }
                guard !filteredHandlers.isEmpty else {
                    return nil
                }
                var updatedGroup = group
                updatedGroup["hooks"] = filteredHandlers
                return updatedGroup
            }

            if filteredGroups.isEmpty {
                hooks.removeValue(forKey: eventName)
            } else {
                hooks[eventName] = filteredGroups
            }
        }
    }

    private func loadRoot() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: configurationURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: configurationURL)
        guard !data.isEmpty else {
            return [:]
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexHookConfigurationError.invalidConfiguration
        }
        return root
    }

    private func hooksDictionary(from root: [String: Any]) throws -> [String: Any] {
        guard let value = root["hooks"] else {
            return [:]
        }
        guard let hooks = value as? [String: Any] else {
            throw CodexHookConfigurationError.invalidConfiguration
        }
        return hooks
    }

    private func save(_ root: [String: Any]) throws {
        try fileManager.createDirectory(
            at: configurationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: configurationURL, options: .atomic)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

public enum CodexHookConfigurationError: LocalizedError {
    case invalidConfiguration
    case missingExecutable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Codex hooks.json is not a valid hooks object."
        case .missingExecutable(let path):
            return "Vibe Signal hook helper is missing or not executable at \(path)."
        }
    }
}
