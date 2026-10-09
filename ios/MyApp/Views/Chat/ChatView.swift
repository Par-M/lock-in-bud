import SwiftUI

struct ChatView: View {
    @Environment(ChatService.self) private var chatService
    @State private var input = ""
    @State private var drafts: [UUID: String] = [:]
    @State private var isSwitchingConversation = false
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if chatService.messages.isEmpty && !chatService.isSending {
                            ContentUnavailableView(
                                "Ask the assistant",
                                systemImage: "bubble.left.and.bubble.right",
                                description: Text("Ask about your tasks or discuss a plan for your day. The assistant offers advice, but does not change your tasks or schedule.")
                            )
                            .padding(.top, 40)
                        }
                        ForEach(chatService.messages) { message in
                            MessageBubble(message: message)
                        }
                    }
                    .padding()
                }
                .refreshable {
                    guard !chatService.isSending, !isSwitchingConversation else { return }
                    await chatService.loadConversations()
                    if let id = chatService.currentConversation?.id {
                        await chatService.loadConversation(id)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    if chatService.isSending {
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Assistant is thinking…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                    }
                    HStack(alignment: .top, spacing: 8) {
                        TextField("Type a message...", text: $input, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .focused($isFocused)
                            .lineLimit(1...4)
                            .disabled(chatService.isSending || isSwitchingConversation)

                        Button {
                            Task {
                                let text = input
                                if await chatService.send(text) {
                                    input = ""
                                    if let id = chatService.currentConversation?.id { drafts[id] = nil }
                                    isFocused = false
                                }
                            }
                        } label: {
                            Image(systemName: "paperplane.fill")
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(chatService.isSending ? Color.accentColor.opacity(0.5) : Color.accentColor)
                                .clipShape(Circle())
                        }
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chatService.isSending || isSwitchingConversation)
                    }
                    .padding([.horizontal, .bottom])
                }
            }
            .navigationTitle("Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(chatService.conversations) { conversation in
                            Button(conversation.title ?? "Untitled conversation") {
                                Task {
                                    isSwitchingConversation = true
                                    defer { isSwitchingConversation = false }
                                    rememberDraft()
                                    await chatService.loadConversation(conversation.id)
                                    if chatService.currentConversation?.id == conversation.id {
                                        input = drafts[conversation.id] ?? ""
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(chatService.isSending || isSwitchingConversation || chatService.conversations.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("New") {
                        Task {
                            isSwitchingConversation = true
                            defer { isSwitchingConversation = false }
                            rememberDraft()
                            if await chatService.createConversation() != nil { input = "" }
                        }
                    }
                    .disabled(chatService.isSending || isSwitchingConversation)
                }
            }
            .task {
                await chatService.loadConversations()
                if chatService.currentConversation == nil, let first = chatService.conversations.first {
                    await chatService.loadConversation(first.id)
                } else if chatService.currentConversation == nil {
                    _ = await chatService.createConversation()
                }
            }
        }
        .alert(item: Binding(
            get: { chatService.errorMessage.map(ErrorAlert.init) },
            set: { _ in chatService.clearError() }
        )) { alert in
            Alert(title: Text("Error"), message: Text(alert.message))
        }
    }

    private func rememberDraft() {
        if let id = chatService.currentConversation?.id { drafts[id] = input }
    }

    private struct ErrorAlert: Identifiable {
        let id = UUID()
        let message: String
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var isUser: Bool {
        message.role == "user"
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser {
                Spacer(minLength: 60)
                Text(message.content ?? "")
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.primary)
            } else {
                ZStack {
                    Circle()
                        .fill(Color(.secondarySystemBackground))
                        .frame(width: 32, height: 32)
                    Text("A")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                }
                Text(message.content ?? "")
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.primary)
                Spacer(minLength: 60)
            }
        }
    }
}
