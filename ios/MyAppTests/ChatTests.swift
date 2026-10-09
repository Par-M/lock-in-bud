import Foundation
import XCTest
@testable import MyApp

@MainActor
final class ChatTests: XCTestCase {
    func testFailedSendKeepsDraftAndRetryReusesRequestID() async throws {
        let transport = MockChatTransport()
        let service = ChatService(client: transport)
        let firstSent = await service.send("Plan today")
        XCTAssertFalse(firstSent)
        XCTAssertEqual(service.failedDraft, "Plan today")
        XCTAssertTrue(service.messages.isEmpty)
        XCTAssertTrue(service.errorMessage?.contains("draft was kept") == true)
        transport.failSend = false
        let retried = await service.retry()
        XCTAssertTrue(retried)
        XCTAssertEqual(transport.sent.count, 2)
        XCTAssertEqual(transport.sent[0].requestId, transport.sent[1].requestId)
        XCTAssertEqual(transport.sent[0].content, transport.sent[1].content)
        XCTAssertEqual(service.messages.map(\.role), ["user", "assistant"])
        XCTAssertNil(service.failedDraft)
        XCTAssertNil(service.errorMessage)
    }

    func testInternshipInputNeverFabricatesAReply() async throws {
        let transport = MockChatTransport()
        let service = ChatService(client: transport)
        transport.failSend = false
        let sent = await service.send("how do i get an internship")
        XCTAssertTrue(sent)
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertEqual(service.messages.last?.content, "Server answer")
    }

    func testChangingDraftGetsNewRequestID() async throws {
        let transport = MockChatTransport()
        let service = ChatService(client: transport)
        _ = await service.send("First")
        _ = await service.send("Second")
        XCTAssertNotEqual(transport.sent[0].requestId, transport.sent[1].requestId)
        XCTAssertEqual(service.failedDraft, "Second")
    }

    func testAccountChangeClearsHistoryAndRetryState() async throws {
        let transport = MockChatTransport()
        let service = ChatService(client: transport)
        _ = await service.send("Private draft")
        transport.userID = UUID()
        service.synchronizeAccount()
        XCTAssertNil(service.failedDraft)
        XCTAssertNil(service.currentConversation)
        XCTAssertTrue(service.messages.isEmpty)
        XCTAssertTrue(service.conversations.isEmpty)
    }

    func testDuplicateSendWhileRequestIsInFlightIsIgnored() async throws {
        let transport = MockChatTransport()
        transport.pauseSend = true
        let service = ChatService(client: transport)
        let first = Task { await service.send("Hello") }
        while transport.continuation == nil { await Task.yield() }
        let duplicate = await service.send("Hello")
        XCTAssertFalse(duplicate)
        transport.continuation?.resume(); transport.continuation = nil
        _ = await first.value
        XCTAssertEqual(transport.sent.count, 1)
    }
}

@MainActor
private final class MockChatTransport: ChatTransport {
    var userID: UUID? = UUID()
    let conversationID = UUID()
    var failSend = true
    var pauseSend = false
    var continuation: CheckedContinuation<Void, Never>?
    var sent: [ChatMessageCreate] = []

    func request<T: Decodable>(_ endpoint: Endpoint) async throws -> T {
        guard let endpoint = endpoint as? ChatEndpoint else { throw NetworkError.invalidResponse }
        let conversation = ChatConversation(id: conversationID, userId: userID!, title: nil,
                                            createdAt: Date(), updatedAt: Date(), messages: [])
        let data: Data
        switch endpoint {
        case .createConversation, .getConversation:
            data = try JSONCoding.encoder.encode(conversation)
        case .listConversations:
            data = try JSONCoding.encoder.encode([conversation])
        case .sendMessage(_, let payload):
            sent.append(payload)
            if pauseSend { await withCheckedContinuation { continuation = $0 } }
            if failSend { throw URLError(.timedOut) }
            let result = ChatSendResponse(conversationId: conversationID,
                message: ChatMessage(id: UUID(), conversationId: conversationID, role: "user", content: payload.content, createdAt: Date()),
                assistantMessage: ChatMessage(id: UUID(), conversationId: conversationID, role: "assistant", content: "Server answer", createdAt: Date()))
            data = try JSONCoding.encoder.encode(result)
        default:
            throw NetworkError.invalidResponse
        }
        return try JSONCoding.decoder.decode(T.self, from: data)
    }
}
