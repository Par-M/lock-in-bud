import SwiftUI

struct ChatView: View {
    @Environment(ChatService.self) private var chatService
    @State private var input = ""
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
                                description: Text("Ask about tasks, plan your day, or take quick actions.")
                            )
                            .padding(.top, 40)
                        }
                        ForEach(chatService.messages) { message in
                            MessageBubble(message: message)
                        }
                    }
                    .padding()
                }

                Divider()

                HStack(alignment: .top, spacing: 8) {
                    TextField("Type a message...", text: $input, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .focused($isFocused)
                        .lineLimit(1...4)
                        .disabled(chatService.isSending)

                    Button {
                        Task {
                            let text = input
                            input = ""
                            await chatService.send(text)
                            isFocused = false
                        }
                    } label: {
                        Image(systemName: "paperplane.fill")
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(Color.accentColor)
                            .clipShape(Circle())
                    }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chatService.isSending)
                }
                .padding()
            }
            .navigationTitle("Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("New") {
                        Task {
                            await chatService.createConversation()
                            input = ""
                        }
                    }
                }
            }
            .task {
                await chatService.loadConversations()
                if chatService.currentConversation == nil, let first = chatService.conversations.first {
                    await chatService.loadConversation(first.id)
                } else if chatService.currentConversation == nil {
                    await chatService.createConversation()
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
        HStack {
            if isUser {
                Spacer(minLength: 60)
                Text(message.content ?? "")
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.primary)
            } else {
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
