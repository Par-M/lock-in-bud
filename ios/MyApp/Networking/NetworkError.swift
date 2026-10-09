import Foundation

enum NetworkError: Error {
    case invalidResponse
    case unauthorized
    case httpStatus(Int)
    case serverError(status: Int, detail: String)
    case decoding(Error)

    static func response(status: Int, data: Data) -> NetworkError {
        if status == 401 { return .unauthorized }
        // Keep 404 recognizable for callers handling already-deleted records.
        if status != 404,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = object["detail"] as? String ?? object["message"] as? String {
                return .serverError(status: status, detail: detail)
            }
            if let details = object["detail"] as? [[String: Any]] {
                let message = details.compactMap { $0["msg"] as? String }.joined(separator: "; ")
                if !message.isEmpty { return .serverError(status: status, detail: message) }
            }
        }
        return .httpStatus(status)
    }
}

extension NetworkError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The server returned an invalid response."
        case .unauthorized:
            return "Your session has expired. Please sign in again."
        case .httpStatus(let code):
            return "The server returned an error (HTTP \(code))."
        case .serverError(let status, let detail):
            return "\(detail) (HTTP \(status))."
        case .decoding:
            return "The server response could not be decoded."
        }
    }
}
