import Foundation

enum FocusEndpoint: Endpoint {
    case sessions(after: Date?, before: Date?)
    case summary(after: Date?, before: Date?)
    case create(FocusSessionCreate)
    case update(id: UUID, FocusSessionUpdate)
    case delete(UUID)
    case morningMessage

    var path: String {
        switch self {
        case .sessions, .create:
            return "/api/v1/focus/sessions"
        case .summary:
            return "/api/v1/focus/summary"
        case .update(let id, _):
            return "/api/v1/focus/sessions/\(id.uuidString.lowercased())"
        case .delete(let id):
            return "/api/v1/focus/sessions/\(id.uuidString.lowercased())"
        case .morningMessage:
            return "/api/v1/reflections/morning-message"
        }
    }

    var method: HTTPMethod {
        switch self {
        case .sessions, .summary, .morningMessage:
            return .get
        case .create:
            return .post
        case .update:
            return .patch
        case .delete:
            return .delete
        }
    }

    var body: (any Encodable)? {
        switch self {
        case .create(let payload):
            return payload
        case .update(_, let payload):
            return payload
        default:
            return nil
        }
    }

    var queryItems: [URLQueryItem]? {
        switch self {
        case .sessions(let after, let before), .summary(let after, let before):
            var items: [URLQueryItem] = []
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let after {
                items.append(URLQueryItem(name: "after", value: formatter.string(from: after)))
            }
            if let before {
                items.append(URLQueryItem(name: "before", value: formatter.string(from: before)))
            }
            return items.isEmpty ? nil : items
        default:
            return nil
        }
    }
}
