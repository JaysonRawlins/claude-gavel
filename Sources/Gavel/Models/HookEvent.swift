import Foundation

/// The type of hook that fired.
enum HookType: String, Codable {
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case sessionStart = "SessionStart"
    case stop = "Stop"
    case userPromptSubmit = "UserPromptSubmit"
    case notification = "Notification"
    case stopFailure = "StopFailure"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case permissionRequest = "PermissionRequest"
    case unknown
}

/// Incoming event from a Claude Code hook shim.
///
/// The gavel-hook binary wraps Claude's raw JSON in this envelope,
/// adding the PID and hook type.
struct HookEvent: Codable {
    let hookType: HookType
    let sessionPid: Int
    let timestamp: Double
    let payload: HookPayload
}

/// The hook-specific payload, matching Claude Code's hook stdin schema.
enum HookPayload: Codable {
    case preToolUse(PreToolUsePayload)
    case postToolUse(PostToolUsePayload)
    case sessionStart(SessionStartPayload)
    case stop
    case userPromptSubmit(UserPromptSubmitPayload)
    case notification(NotificationPayload)
    case stopFailure(StopFailurePayload)
    case passthrough(String) // Unhandled event types — store hook_event_name

    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "PreToolUse":
            self = .preToolUse(try PreToolUsePayload(from: decoder))
        case "PostToolUse":
            self = .postToolUse(try PostToolUsePayload(from: decoder))
        case "SessionStart":
            self = .sessionStart(try SessionStartPayload(from: decoder))
        case "Stop":
            self = .stop
        case "UserPromptSubmit":
            self = .userPromptSubmit(try UserPromptSubmitPayload(from: decoder))
        case "Notification":
            self = .notification(try NotificationPayload(from: decoder))
        case "StopFailure":
            self = .stopFailure(try StopFailurePayload(from: decoder))
        default:
            self = .passthrough(type)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .preToolUse(let p): try p.encode(to: encoder)
        case .postToolUse(let p): try p.encode(to: encoder)
        case .sessionStart(let p): try p.encode(to: encoder)
        case .userPromptSubmit(let p): try p.encode(to: encoder)
        case .notification(let p): try p.encode(to: encoder)
        case .stopFailure(let p): try p.encode(to: encoder)
        case .stop, .passthrough: break
        }
    }
}

// MARK: - Payload types

struct PreToolUsePayload: Codable {
    let toolName: String
    let toolInput: [String: AnyCodable]
    let sessionId: String?
    let cwd: String?
    let permissionMode: String?
    let toolUseId: String?

    enum CodingKeys: String, CodingKey {
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case sessionId = "session_id"
        case cwd
        case permissionMode = "permission_mode"
        case toolUseId = "tool_use_id"
    }

    init(toolName: String, toolInput: [String: AnyCodable],
         sessionId: String? = nil, cwd: String? = nil,
         permissionMode: String? = nil, toolUseId: String? = nil) {
        self.toolName = toolName
        self.toolInput = toolInput
        self.sessionId = sessionId
        self.cwd = cwd
        self.permissionMode = permissionMode
        self.toolUseId = toolUseId
    }

    var command: String? {
        toolInput["command"]?.stringValue
    }

    var filePath: String? {
        toolInput["file_path"]?.stringValue
    }
}

struct PostToolUsePayload: Codable {
    let toolName: String
    let toolInput: [String: AnyCodable]
    let toolResponse: AnyCodable?
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case toolResponse = "tool_response"
        case sessionId = "session_id"
    }
}

struct SessionStartPayload: Codable {
    let sessionId: String?
    let cwd: String?
    let source: String?  // startup, resume, clear, compact
    let model: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case source
        case model
    }
}

struct UserPromptSubmitPayload: Codable {
    let prompt: String?
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case prompt
        case sessionId = "session_id"
    }
}

struct NotificationPayload: Codable {
    let message: String?
    let title: String?
    let notificationType: String?
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case message
        case title
        case notificationType = "notification_type"
        case sessionId = "session_id"
    }
}

struct StopFailurePayload: Codable {
    let errorType: String?
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case errorType = "error_type"
        case sessionId = "session_id"
    }
}

// MARK: - AnyCodable helper for dynamic JSON

struct AnyCodable: Codable {
    let value: Any

    var stringValue: String? { value as? String }
    var intValue: Int? { value as? Int }
    var boolValue: Bool? { value as? Bool }
    var dictValue: [String: AnyCodable]? { value as? [String: AnyCodable] }

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            value = str
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict
        } else if let arr = try? container.decode([AnyCodable].self) {
            value = arr
        } else if container.decodeNil() {
            value = NSNull()
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let str as String: try container.encode(str)
        case let int as Int: try container.encode(int)
        case let double as Double: try container.encode(double)
        case let bool as Bool: try container.encode(bool)
        case let dict as [String: AnyCodable]: try container.encode(dict)
        case let arr as [AnyCodable]: try container.encode(arr)
        default: try container.encodeNil()
        }
    }
}
