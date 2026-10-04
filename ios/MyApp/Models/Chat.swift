import Foundation

struct ChatMessage: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let conversationId: UUID
    let role: String
    let content: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case conversationId = "conversation_id"
        case role
        case content
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

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case title
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case messages
    }
}

struct ChatConversationCreate: Encodable, Sendable {
    let title: String?
}

struct ChatMessageCreate: Encodable, Sendable {
    let content: String
}

struct ChatSendResponse: Codable, Sendable {
    let conversationId: UUID
    let message: ChatMessage
    let assistantMessage: ChatMessage

    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case message
        case assistantMessage = "assistant_message"
    }
}
