import Foundation

enum ChatEndpoint: Endpoint {
    case createConversation(ChatConversationCreate)
    case listConversations
    case getConversation(UUID)
    case sendMessage(UUID, ChatMessageCreate)
    case decide(UUID, UUID, confirm: Bool)
    case rename(UUID, ChatConversationRename)
    case delete(UUID)
    case messages(UUID, after: UUID?, before: UUID? = nil)
    case memory
    case clearMemory

    var path: String {
        switch self {
        case .createConversation, .listConversations:
            return "/api/v1/chat/conversations"
        case .getConversation(let id), .rename(let id, _), .delete(let id):
            return "/api/v1/chat/conversations/\(id.uuidString.lowercased())"
        case .decide(let id, let action, let confirm):
            return "/api/v1/chat/conversations/\(id.uuidString.lowercased())/actions/\(action.uuidString.lowercased())/\(confirm ? "confirm" : "cancel")"
        case .memory, .clearMemory:
            return "/api/v1/chat/memory"
        case .messages(let id, _, _):
            return "/api/v1/chat/conversations/\(id.uuidString.lowercased())/messages"
        case .sendMessage(let id, _):
            return "/api/v1/chat/conversations/\(id.uuidString.lowercased())/messages"
        }
    }

    var method: HTTPMethod {
        switch self {
        case .listConversations, .getConversation, .messages, .memory:
            return .get
        case .createConversation, .sendMessage, .decide:
            return .post
        case .rename: return .patch
        case .delete, .clearMemory: return .delete
        }
    }

    var queryItems: [URLQueryItem]? {
        guard case .messages(_, let after, let before) = self else { return nil }
        return [URLQueryItem(name: "limit", value: "100")] + (after.map { [URLQueryItem(name: "after", value: $0.uuidString)] } ?? []) + (before.map { [URLQueryItem(name: "before", value: $0.uuidString)] } ?? [])
    }

    var body: (any Encodable)? {
        switch self {
        case .createConversation(let payload):
            return payload
        case .sendMessage(_, let payload):
            return payload
        case .rename(_, let payload): return payload
        default:
            return nil
        }
    }
}
