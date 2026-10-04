import Foundation

enum ChatEndpoint: Endpoint {
    case createConversation(ChatConversationCreate)
    case listConversations
    case getConversation(UUID)
    case sendMessage(UUID, ChatMessageCreate)

    var path: String {
        switch self {
        case .createConversation, .listConversations:
            return "/api/v1/chat/conversations"
        case .getConversation(let id):
            return "/api/v1/chat/conversations/\(id.uuidString.lowercased())"
        case .sendMessage(let id, _):
            return "/api/v1/chat/conversations/\(id.uuidString.lowercased())/messages"
        }
    }

    var method: HTTPMethod {
        switch self {
        case .listConversations, .getConversation:
            return .get
        case .createConversation, .sendMessage:
            return .post
        }
    }

    var body: (any Encodable)? {
        switch self {
        case .createConversation(let payload):
            return payload
        case .sendMessage(_, let payload):
            return payload
        default:
            return nil
        }
    }
}
