import Foundation
import Observation

@MainActor
@Observable
final class ChatService {
    private(set) var conversations: [ChatConversation] = []
    private(set) var currentConversation: ChatConversation?
    private(set) var messages: [ChatMessage] = []
    private(set) var actions: [ChatAction] = []
    private(set) var memory: [String] = []
    private(set) var isSending = false
    private(set) var errorMessage: String?
    private(set) var partialText = ""
    private(set) var failedDraft: String?
    private(set) var hasOlderMessages = false
    private let client: any ChatTransport
    private let connectivity: ConnectivityMonitor
    private var pendingRequest: (conversation: UUID, text: String, id: UUID)?
    private var owner: UUID?
    private var selectionVersion = 0

    init(client: (any ChatTransport)? = nil, connectivity: ConnectivityMonitor? = nil) {
        self.client = client ?? APIClient()
        self.connectivity = connectivity ?? ConnectivityMonitor()
        owner = self.client.userID
    }
    var isOnline: Bool { connectivity.isConnected }

    func synchronizeAccount() {
        guard owner != client.userID else { return }
        owner = client.userID
        selectionVersion += 1
        conversations = []; currentConversation = nil; messages = []; actions = []; memory = []
        pendingRequest = nil; failedDraft = nil; partialText = ""; errorMessage = nil
    }
    func loadConversations() async {
        synchronizeAccount()
        let account = owner
        do {
            let list: [ChatConversation] = try await client.request(ChatEndpoint.listConversations)
            guard owner == account, client.userID == account else { return }
            conversations = list
        } catch { errorMessage = error.localizedDescription }
    }
    func createConversation(title: String? = nil) async -> ChatConversation? {
        synchronizeAccount()
        let account = owner
        do {
            let conv: ChatConversation = try await client.request(ChatEndpoint.createConversation(ChatConversationCreate(title: title)))
            guard owner == account, client.userID == account else { return nil }
            conversations.insert(conv, at: 0); apply(conv); pendingRequest = nil
            return conv
        } catch { errorMessage = error.localizedDescription; return nil }
    }
    func loadConversation(_ id: UUID) async {
        guard !isSending else { return }
        synchronizeAccount(); selectionVersion += 1
        let version = selectionVersion, account = owner
        do {
            let conv: ChatConversation = try await client.request(ChatEndpoint.getConversation(id))
            guard version == selectionVersion, owner == account, client.userID == account else { return }
            apply(conv); pendingRequest = nil; failedDraft = nil
        } catch { if version == selectionVersion { errorMessage = error.localizedDescription } }
    }
    private func apply(_ conv: ChatConversation) {
        currentConversation = conv; messages = conv.messages ?? []; actions = conv.actions ?? []
        hasOlderMessages = messages.count >= 100
    }
    func send(_ text: String) async -> Bool {
        guard !isSending else { return false }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        synchronizeAccount()
        guard isOnline else { failedDraft = text; errorMessage = "The assistant needs a connection."; return false }
        isSending = true; errorMessage = nil; partialText = ""
        let account = owner
        defer { isSending = false; partialText = "" }
        if currentConversation == nil { guard await createConversation() != nil else { failedDraft = text; return false } }
        guard let conv = currentConversation else { return false }
        if pendingRequest?.conversation != conv.id || pendingRequest?.text != text {
            pendingRequest = (conv.id, text, UUID())
        }
        do {
            let payload = ChatMessageCreate(content: text, requestId: pendingRequest?.id)
            let result = try await client.streamChat(ChatEndpoint.sendMessage(conv.id, payload)) { [weak self] text in
                guard self?.client.userID == account else { return }; self?.partialText = text
            }
            guard client.userID == account, currentConversation?.id == result.conversationId else { return false }
            messages.append(result.message); messages.append(result.assistantMessage); actions = result.actions ?? []
            pendingRequest = nil; failedDraft = nil
            await loadConversations()
            return true
        } catch {
            guard client.userID == account else { synchronizeAccount(); return false }
            failedDraft = text; errorMessage = "Message not sent — your draft was kept. \(error.localizedDescription)"
            return false
        }
    }
    func retry() async -> Bool { guard let draft = failedDraft else { return false }; return await send(draft) }
    func decide(_ action: ChatAction, confirm: Bool) async -> ChatAction? {
        guard let conv = currentConversation, !isSending, isOnline else { return nil }
        let account = owner
        isSending = true; defer { isSending = false }
        do {
            let result: ChatAction = try await client.request(ChatEndpoint.decide(conv.id, action.id, confirm: confirm))
            guard client.userID == account else { synchronizeAccount(); return nil }
            if let index = actions.firstIndex(where: { $0.id == action.id }) { actions[index] = result }
            if result.status == "confirmed", result.result?["client_action"]?.string == "start_focus_session", confirm {
                let key = "assistant.focus.\(account?.uuidString ?? "").\(action.id)"
                if !UserDefaults.standard.bool(forKey: key) {
                    UserDefaults.standard.set(true, forKey: key)
                    FocusTimerStarter.startFocus(taskID: result.result?["task_id"]?.string.flatMap(UUID.init(uuidString:)),
                        title: result.result?["task_title"]?.string, category: result.result?["category"]?.string)
                }
            }
            if result.name == "remember_fact" { await loadMemory() }
            return result
        } catch { errorMessage = error.localizedDescription; return nil }
    }
    func rename(_ title: String) async {
        guard let conv = currentConversation, !isSending, isOnline else { return }
        let account = owner
        do {
            let _: ChatConversation = try await client.request(ChatEndpoint.rename(conv.id, ChatConversationRename(title: title)))
            guard client.userID == account else { synchronizeAccount(); return }
            await loadConversations(); await loadConversation(conv.id)
        } catch { errorMessage = error.localizedDescription }
    }
    func deleteCurrent() async {
        guard let conv = currentConversation, !isSending, isOnline else { return }
        let account = owner
        do {
            let _: MessageResponse = try await client.request(ChatEndpoint.delete(conv.id))
            guard client.userID == account else { synchronizeAccount(); return }
            currentConversation = nil; messages = []; actions = []; failedDraft = nil; pendingRequest = nil
            await loadConversations()
        } catch { errorMessage = error.localizedDescription }
    }
    func loadOlder() async {
        guard let id = currentConversation?.id, !isSending, isOnline else { return }
        let account = owner
        do {
            guard let anchor = messages.first?.id else { hasOlderMessages = false; return }
            let page: [ChatMessage] = try await client.request(ChatEndpoint.messages(id, after: nil, before: anchor))
            guard currentConversation?.id == id, client.userID == account else { return }
            messages = page + messages; hasOlderMessages = page.count == 100
        } catch { errorMessage = error.localizedDescription }
    }
    func loadMemory() async {
        let account = owner
        do {
            let result: ChatMemory = try await client.request(ChatEndpoint.memory)
            guard client.userID == account else { synchronizeAccount(); return }
            memory = result.facts
        } catch { if client.userID == account { errorMessage = error.localizedDescription } }
    }
    func clearMemory() async {
        let account = owner
        do {
            let _: ChatMemory = try await client.request(ChatEndpoint.clearMemory)
            guard client.userID == account else { synchronizeAccount(); return }
            memory = []
        } catch { if client.userID == account { errorMessage = error.localizedDescription } }
    }
    func citedTask(_ id: UUID) async -> TaskItem? {
        let account = owner
        do {
            let task: TaskItem = try await client.request(TaskEndpoint.get(id))
            guard client.userID == account else { return nil }
            return task
        } catch { if client.userID == account { errorMessage = error.localizedDescription }; return nil }
    }
    func clearError() { errorMessage = nil }
}
