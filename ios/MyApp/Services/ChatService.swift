import Foundation
import Observation

@MainActor
@Observable
final class ChatService {
    private(set) var conversations: [ChatConversation] = []
    private(set) var currentConversation: ChatConversation?
    private(set) var messages: [ChatMessage] = []
    private(set) var isSending = false
    private(set) var errorMessage: String?

    private let client: APIClient

    init(client: APIClient? = nil) {
        self.client = client ?? APIClient()
    }

    func loadConversations() async {
        do {
            let list: [ChatConversation] = try await client.request(ChatEndpoint.listConversations)
            conversations = list
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createConversation(title: String? = nil) async -> ChatConversation? {
        do {
            let conv: ChatConversation = try await client.request(
                ChatEndpoint.createConversation(ChatConversationCreate(title: title))
            )
            conversations.insert(conv, at: 0)
            currentConversation = conv
            messages = conv.messages ?? []
            return conv
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func loadConversation(_ id: UUID) async {
        do {
            let conv: ChatConversation = try await client.request(ChatEndpoint.getConversation(id))
            currentConversation = conv
            messages = conv.messages ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func send(_ text: String) async {
        guard let conv = currentConversation else {
            if let c = await createConversation() {
                await send(text)
            }
            return
        }
        isSending = true
        errorMessage = nil
        do {
            let res: ChatSendResponse = try await client.request(
                ChatEndpoint.sendMessage(conv.id, ChatMessageCreate(content: text))
            )
            if currentConversation?.id == res.conversationId {
                messages.append(res.message)
                messages.append(res.assistantMessage)
            }
            await loadConversations()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSending = false
    }

    func clearError() {
        errorMessage = nil
    }
}
