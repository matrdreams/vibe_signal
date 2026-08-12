import Foundation

public enum SignalState: String, Codable, CaseIterable, Equatable, Sendable {
    case blocked
    case working
    case idle
    case error
    case unknown

    public var priority: Int {
        switch self {
        case .blocked:
            return 50
        case .error:
            return 40
        case .unknown:
            return 35
        case .working:
            return 30
        case .idle:
            return 20
        }
    }

    public var isActive: Bool {
        self == .blocked || self == .error || self == .working
    }
}

public enum SignalReason {
    public static let approval = "approval"
    public static let question = "question"
    public static let thinking = "thinking"
    public static let tool = "tool"
    public static let command = "command"
    public static let fileChange = "file_change"
    public static let review = "review"
    public static let done = "done"
    public static let interrupted = "interrupted"
    public static let sessionStart = "session_start"
    public static let sessionEnd = "session_end"
    public static let error = "error"
    public static let stale = "stale"
}

public enum JSONValue: Codable, Equatable, Sendable, CustomStringConvertible {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
        } else if let intValue = try? container.decode(Int.self) {
            self = .number(Double(intValue))
        } else if let doubleValue = try? container.decode(Double.self) {
            self = .number(doubleValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let objectValue = try? container.decode([String: JSONValue].self) {
            self = .object(objectValue)
        } else if let arrayValue = try? container.decode([JSONValue].self) {
            self = .array(arrayValue)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public var description: String {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            if value.rounded() == value {
                return String(Int64(value))
            }
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .object(let value):
            return value.description
        case .array(let value):
            return value.description
        case .null:
            return "null"
        }
    }
}

public struct SignalEvent: Codable, Equatable, Sendable, Identifiable {
    public var schemaVersion: Int
    public var source: String
    public var adapter: String
    public var sessionId: String
    public var title: String?
    public var workspace: String?
    public var state: SignalState
    public var reason: String
    public var message: String?
    public var startedAt: Date?
    public var updatedAt: Date
    public var ttlMs: Int?
    public var metadata: [String: JSONValue]?

    public var id: String {
        sessionKey
    }

    public var sessionKey: String {
        "\(source):\(sessionId)"
    }

    public init(
        schemaVersion: Int = 1,
        source: String,
        adapter: String,
        sessionId: String,
        title: String? = nil,
        workspace: String? = nil,
        state: SignalState,
        reason: String,
        message: String? = nil,
        startedAt: Date? = nil,
        updatedAt: Date = Date(),
        ttlMs: Int? = nil,
        metadata: [String: JSONValue]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.source = source
        self.adapter = adapter
        self.sessionId = sessionId
        self.title = title
        self.workspace = workspace
        self.state = state
        self.reason = reason
        self.message = message
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.ttlMs = ttlMs
        self.metadata = metadata
    }

    public func isExpired(now: Date = Date()) -> Bool {
        guard let ttlMs else {
            return false
        }
        return updatedAt.addingTimeInterval(Double(ttlMs) / 1000.0) < now
    }
}

public struct SignalSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var globalState: SignalState
    public var generatedAt: Date
    public var sessions: [SignalEvent]

    public init(
        schemaVersion: Int = 1,
        globalState: SignalState,
        generatedAt: Date = Date(),
        sessions: [SignalEvent]
    ) {
        self.schemaVersion = schemaVersion
        self.globalState = globalState
        self.generatedAt = generatedAt
        self.sessions = sessions
    }

    public var activeSessions: [SignalEvent] {
        sessions.filter { $0.state.isActive }
    }

    public var recentIdleSessions: [SignalEvent] {
        sessions.filter { $0.state == .idle }
    }

    public static func make(
        from events: [SignalEvent],
        now: Date = Date(),
        maxSessions: Int? = nil
    ) -> SignalSnapshot {
        var validSessions = events
            .filter { !$0.isExpired(now: now) }
            .sorted { left, right in
                if left.state.priority == right.state.priority {
                    return left.updatedAt > right.updatedAt
                }
                return left.state.priority > right.state.priority
            }

        if let maxSessions,
           validSessions.count > maxSessions {
            validSessions = Array(validSessions.prefix(maxSessions))
        }

        let globalState = aggregate(events: validSessions)
        return SignalSnapshot(globalState: globalState, generatedAt: now, sessions: validSessions)
    }

    public static func aggregate(events: [SignalEvent]) -> SignalState {
        guard !events.isEmpty else {
            return .unknown
        }

        // Unknown outranks working and idle because a definitive global colour
        // must account for every observed session. A verified blocked/error
        // remains actionable even if another source has gone stale.
        for state in [SignalState.blocked, .error, .unknown, .working, .idle] {
            if events.contains(where: { $0.state == state }) {
                return state
            }
        }

        return .unknown
    }
}
