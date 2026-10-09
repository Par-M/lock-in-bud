import Foundation

struct ChatMessage: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let conversationId: UUID
    let role: String
    let content: String?
    let createdAt: Date
    var toolResult: ChatMetadata? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case conversationId = "conversation_id"
        case role
        case content
        case toolResult = "tool_result"
        case createdAt = "created_at"
    }
}

struct ChatConversation: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let userId: UUID
    let title: String?
    let createdAt: Date
    let updatedAt: Date
    let messages: [ChatMessage]?
    var actions: [ChatAction]? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case title
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case messages
        case actions
    }
}

struct ChatConversationCreate: Encodable, Sendable {
    let title: String?
}

struct ChatMessageCreate: Encodable, Sendable {
    let content: String
    var timezone: String = TimeZone.current.identifier
    var requestId: UUID? = nil
    enum CodingKeys: String, CodingKey { case content, timezone, requestId = "request_id" }
}

struct ChatSendResponse: Codable, Sendable {
    let conversationId: UUID
    let message: ChatMessage
    let assistantMessage: ChatMessage
    var actions: [ChatAction]? = nil

    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case message
        case assistantMessage = "assistant_message"
        case actions
    }
}

// Preserve structured action arguments without guessing their shape.
indirect enum ChatValue: Codable, Hashable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: ChatValue]), array([ChatValue]), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode([String: ChatValue].self) { self = .object(v) }
        else { self = .array(try value.decode([ChatValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }
    var string: String? { if case .string(let v) = self { return v }; return nil }
}

struct ChatAction: Codable, Identifiable, Hashable, Sendable {
    let actionId: UUID
    let name: String
    let args: [String: ChatValue]
    let status: String
    let result: [String: ChatValue]?
    var id: UUID { actionId }
    var summary: String {
        args["title"]?.string ?? args["task_title"]?.string ?? args["fact"]?.string ?? "Focus timer"
    }
    enum CodingKeys: String, CodingKey { case actionId = "action_id", name, args, status, result }
}
struct ChatCitation: Codable, Hashable, Sendable { let id: UUID; let title: String }
struct ChatMetadata: Codable, Hashable, Sendable { let citations: [ChatCitation]? }
struct ChatMemory: Codable, Sendable { let facts: [String] }
struct ChatConversationRename: Encodable, Sendable { let title: String }
struct ChatStreamEvent: Decodable {
    let type: String
    let text: String?
    let detail: String?
    let result: ChatSendResponse?
}

@MainActor
protocol ChatTransport {
    var userID: UUID? { get }
    func request<T: Decodable>(_ endpoint: Endpoint) async throws -> T
    func streamChat(_ endpoint: Endpoint, onText: @escaping @MainActor (String) -> Void) async throws -> ChatSendResponse
}
extension ChatTransport {
    func streamChat(_ endpoint: Endpoint, onText: @escaping @MainActor (String) -> Void) async throws -> ChatSendResponse {
        try await request(endpoint)
    }
}
extension APIClient: ChatTransport {}
