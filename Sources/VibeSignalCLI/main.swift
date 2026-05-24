import Darwin
import Foundation
import VibeSignalCore

enum CLIError: Error, LocalizedError {
    case missingValue(String)
    case unknownCommand(String)
    case invalidState(String)
    case invalidMetadata(String)
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let name):
            return "Missing value for \(name)"
        case .unknownCommand(let command):
            return "Unknown command: \(command)"
        case .invalidState(let value):
            return "Invalid state: \(value)"
        case .invalidMetadata(let value):
            return "Metadata must use key=value format: \(value)"
        case .invalidJSON(let detail):
            return "Invalid JSON: \(detail)"
        }
    }
}

@main
struct VibeSignalCLI {
    static func main() {
        do {
            var arguments = Array(CommandLine.arguments.dropFirst())
            let command = arguments.isEmpty ? "help" : arguments.removeFirst()
            switch command {
            case "emit":
                try emit(arguments)
            case "status":
                try status()
            case "paths":
                try paths()
            case "ping":
                try ping()
            case "demo":
                try demo(arguments)
            case "codex-notify":
                try codexNotify(arguments)
            case "help", "-h", "--help":
                printHelp()
            default:
                throw CLIError.unknownCommand(command)
            }
        } catch {
            fputs("vibe-signal: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func emit(_ arguments: [String]) throws {
        var parser = OptionParser(arguments)
        let requireHub = parser.flag("--require-hub")

        if let json = try parser.optionalValue(for: "--json") {
            let data: Data
            if json == "-" {
                data = FileHandle.standardInput.readDataToEndOfFile()
            } else {
                data = Data(json.utf8)
            }
            let event = try SignalJSON.decode(SignalEvent.self, from: data)
            try sendOrPersist(event, allowOffline: !requireHub)
            print("sent \(event.state.rawValue)/\(event.reason) \(event.sessionKey)")
            return
        }

        let stateValue = try parser.value(for: "--state")
        guard let state = SignalState(rawValue: stateValue) else {
            throw CLIError.invalidState(stateValue)
        }

        let now = Date()
        let workspace = try parser.optionalValue(for: "--workspace")
            ?? ProcessInfo.processInfo.environment["VIBE_SIGNAL_WORKSPACE"]
            ?? ProcessInfo.processInfo.environment["CODEX_WORKSPACE"]
            ?? FileManager.default.currentDirectoryPath
        let source = try parser.optionalValue(for: "--source") ?? "manual"
        let adapter = try parser.optionalValue(for: "--adapter") ?? "vibe-signal-cli"
        let sessionId = try parser.optionalValue(for: "--session-id")
            ?? ProcessInfo.processInfo.environment["VIBE_SIGNAL_SESSION_ID"]
            ?? ProcessInfo.processInfo.environment["CODEX_SESSION_ID"]
            ?? stableSessionId(source: source, workspace: workspace)

        let reason = try parser.optionalValue(for: "--reason") ?? defaultReason(for: state)
        let ttlMs = try parser.optionalValue(for: "--ttl-ms").flatMap(Int.init)
            ?? defaultTTL(for: state)
        let metadata = try parseMetadata(parser.values(for: "--metadata"))

        let event = SignalEvent(
            source: source,
            adapter: adapter,
            sessionId: sessionId,
            workspace: workspace,
            state: state,
            reason: reason,
            message: try parser.optionalValue(for: "--message"),
            startedAt: now,
            updatedAt: now,
            ttlMs: ttlMs,
            metadata: metadata.isEmpty ? nil : metadata
        )

        try sendOrPersist(event, allowOffline: !requireHub)
        print("sent \(event.state.rawValue)/\(event.reason) \(event.sessionKey)")
    }

    private static func status() throws {
        let persistence = SnapshotPersistence()
        let snapshot = SignalSnapshot.make(from: try persistence.load().sessions)
        print("global: \(snapshot.globalState.rawValue)")
        print("updated: \(SignalJSON.format(snapshot.generatedAt))")
        if snapshot.sessions.isEmpty {
            print("sessions: none")
            return
        }

        for event in snapshot.sessions {
            let workspace = event.workspace.map(workspaceName) ?? "-"
            let message = event.message ?? event.reason
            print("\(event.state.rawValue)\t\(workspace)\t\(message)\t\(event.sessionKey)")
        }
    }

    private static func paths() throws {
        let paths = VibeSignalPaths()
        print("socket: \(paths.socketURL.path)")
        print("snapshot: \(paths.snapshotURL.path)")
        print("app-support: \(paths.appSupportDirectory.path)")
    }

    private static func ping() throws {
        if UnixSocketClient.canConnect() {
            print("hub: online")
        } else {
            print("hub: offline")
            exit(2)
        }
    }

    private static func demo(_ arguments: [String]) throws {
        let stateValue = arguments.first ?? "working"
        guard let state = SignalState(rawValue: stateValue) else {
            throw CLIError.invalidState(stateValue)
        }

        let now = Date()
        let event = SignalEvent(
            source: "demo",
            adapter: "vibe-signal-cli",
            sessionId: "demo",
            workspace: FileManager.default.currentDirectoryPath,
            state: state,
            reason: defaultReason(for: state),
            message: demoMessage(for: state),
            startedAt: now,
            updatedAt: now,
            ttlMs: defaultTTL(for: state)
        )

        try sendOrPersist(event)
        print("demo \(state.rawValue) emitted")
    }

    private static func codexNotify(_ arguments: [String]) throws {
        let eventName = arguments.first ?? "turn-ended"
        let mapping = codexMapping(for: eventName)
        let now = Date()
        let workspace = ProcessInfo.processInfo.environment["CODEX_WORKSPACE"]
            ?? ProcessInfo.processInfo.environment["PWD"]
            ?? FileManager.default.currentDirectoryPath
        let sessionId = ProcessInfo.processInfo.environment["CODEX_SESSION_ID"]
            ?? ProcessInfo.processInfo.environment["VIBE_SIGNAL_SESSION_ID"]
            ?? stableSessionId(source: "codex", workspace: workspace)

        var metadata: [String: JSONValue] = [
            "event": .string(eventName)
        ]
        if !arguments.isEmpty {
            metadata["argv"] = .array(arguments.map { .string($0) })
        }

        let event = SignalEvent(
            source: "codex",
            adapter: "codex-notify",
            sessionId: sessionId,
            workspace: workspace,
            state: mapping.state,
            reason: mapping.reason,
            message: mapping.message,
            startedAt: now,
            updatedAt: now,
            ttlMs: defaultTTL(for: mapping.state),
            metadata: metadata
        )

        try sendOrPersist(event)
    }

    private static func sendOrPersist(_ event: SignalEvent, allowOffline: Bool = true) throws {
        do {
            try UnixSocketClient.send(event: event)
        } catch {
            guard allowOffline else {
                throw error
            }
            _ = try SnapshotPersistence().applyOffline(event)
            fputs("vibe-signal: hub is not running; wrote snapshot only\n", stderr)
        }
    }

    private static func defaultReason(for state: SignalState) -> String {
        switch state {
        case .blocked:
            return SignalReason.approval
        case .working:
            return SignalReason.thinking
        case .idle:
            return SignalReason.done
        case .error:
            return SignalReason.error
        case .unknown:
            return SignalReason.stale
        }
    }

    private static func defaultTTL(for state: SignalState) -> Int {
        switch state {
        case .blocked, .working, .error:
            return 300_000
        case .idle:
            return 900_000
        case .unknown:
            return 60_000
        }
    }

    private static func demoMessage(for state: SignalState) -> String {
        switch state {
        case .blocked:
            return "Waiting for user input"
        case .working:
            return "Processing a task"
        case .idle:
            return "Idle"
        case .error:
            return "Adapter reported an error"
        case .unknown:
            return "No live session"
        }
    }

    private static func codexMapping(for eventName: String) -> (state: SignalState, reason: String, message: String) {
        let normalized = eventName.lowercased()
        if normalized.contains("approval") {
            return (.blocked, SignalReason.approval, "Waiting for approval")
        }
        if normalized.contains("question") || normalized.contains("input") {
            return (.blocked, SignalReason.question, "Waiting for input")
        }
        if normalized.contains("tool") {
            return (.working, SignalReason.tool, "Running a tool")
        }
        if normalized.contains("command") || normalized.contains("exec") {
            return (.working, SignalReason.command, "Running a command")
        }
        if normalized.contains("error") || normalized.contains("failed") {
            return (.error, SignalReason.error, "Codex reported an error")
        }
        if normalized.contains("done") || normalized.contains("end") || normalized.contains("complete") {
            return (.idle, SignalReason.done, "Turn finished")
        }
        return (.working, SignalReason.thinking, "Codex is working")
    }

    private static func parseMetadata(_ values: [String]) throws -> [String: JSONValue] {
        var metadata: [String: JSONValue] = [:]
        for value in values {
            let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty else {
                throw CLIError.invalidMetadata(value)
            }
            metadata[parts[0]] = .string(parts[1])
        }
        return metadata
    }

    private static func stableSessionId(source: String, workspace: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "\(source):\(workspace)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private static func workspaceName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    private static func printHelp() {
        print("""
        Vibe Signal

        Usage:
          vibe-signal emit --state blocked --reason approval --message "Waiting for approval"
          vibe-signal emit --json '{"schemaVersion":1,...}'
          vibe-signal emit --require-hub --state working
          vibe-signal demo working
          vibe-signal codex-notify turn-ended
          vibe-signal ping
          vibe-signal status
          vibe-signal paths

        States:
          blocked, working, idle, error, unknown
        """)
    }
}

struct OptionParser {
    private var arguments: [String]

    init(_ arguments: [String]) {
        self.arguments = arguments
    }

    mutating func value(for name: String) throws -> String {
        guard let value = try optionalValue(for: name) else {
            throw CLIError.missingValue(name)
        }
        return value
    }

    mutating func optionalValue(for name: String) throws -> String? {
        guard let index = arguments.firstIndex(of: name) else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            throw CLIError.missingValue(name)
        }
        let value = arguments[valueIndex]
        arguments.remove(at: valueIndex)
        arguments.remove(at: index)
        return value
    }

    mutating func values(for name: String) -> [String] {
        var values: [String] = []
        while let index = arguments.firstIndex(of: name) {
            let valueIndex = arguments.index(after: index)
            guard valueIndex < arguments.endIndex else {
                break
            }
            values.append(arguments[valueIndex])
            arguments.remove(at: valueIndex)
            arguments.remove(at: index)
        }
        return values
    }

    mutating func flag(_ name: String) -> Bool {
        guard let index = arguments.firstIndex(of: name) else {
            return false
        }
        arguments.remove(at: index)
        return true
    }
}
