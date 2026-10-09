import SwiftUI
import UIKit

struct ChatView: View {
    @Environment(ChatService.self) private var chatService
    @Environment(TaskService.self) private var taskService
    @State private var input = ""
    @State private var drafts: [UUID: String] = [:]
    @State private var isSwitchingConversation = false
    @State private var renameTitle = ""
    @State private var renaming = false
    @State private var deleting = false
    @State private var citedTask: TaskItem?
    @FocusState private var isFocused: Bool
    private let suggestions = ["What's my plan today?", "What's overdue?", "What can I focus on right now?"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if chatService.hasOlderMessages {
                                Button("Load older messages") { Task { await chatService.loadOlder() } }
                                    .disabled(!chatService.isOnline || chatService.isSending)
                            }
                            if chatService.messages.isEmpty && !chatService.isSending {
                                ContentUnavailableView("Ask the assistant", systemImage: "bubble.left.and.bubble.right",
                                    description: Text("Ask about your day. Review and confirm proposed changes before they are applied."))
                                ForEach(suggestions, id: \.self) { prompt in Button(prompt) { input = prompt } }
                            }
                            ForEach(chatService.messages.filter { $0.role == "user" || $0.role == "assistant" }) { message in
                                MessageBubble(message: message)
                                ForEach(message.toolResult?.citations ?? [], id: \.id) { citation in
                                    Button(citation.title) { Task { citedTask = await chatService.citedTask(citation.id) } }
                                        .disabled(!chatService.isOnline)
                                }
                            }
                            ForEach(chatService.actions) { action in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(action.name.replacingOccurrences(of: "_", with: " ").capitalized).font(.headline)
                                    Text(action.summary)
                                    if let deadline = action.args["deadline"]?.string { Text("Deadline: \(deadline)") }
                                    if let duration = action.args["estimated_duration"], case .number(let minutes) = duration { Text("\(Int(minutes)) minutes") }
                                    if action.status == "pending" {
                                        HStack {
                                            Button("Confirm") { decide(action, confirm: true) }
                                            Button("Cancel") { decide(action, confirm: false) }
                                        }.disabled(chatService.isSending || !chatService.isOnline)
                                    } else { Text(action.status.capitalized).font(.caption).foregroundStyle(.secondary) }
                                }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                            }
                            if chatService.isSending {
                                HStack { ProgressView(); Text(chatService.partialText.isEmpty ? "Assistant is thinking…" : chatService.partialText) }
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }.padding()
                    }.onChange(of: chatService.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                .refreshable {
                    guard !chatService.isSending, !isSwitchingConversation else { return }
                    await chatService.loadConversations()
                    if let id = chatService.currentConversation?.id { await chatService.loadConversation(id) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    if !chatService.isOnline { Text("The assistant needs a connection. History is still readable.").font(.caption) }
                    if let error = chatService.errorMessage {
                        HStack {
                            Text(error).font(.caption).foregroundStyle(.red)
                            if chatService.failedDraft != nil {
                                Button("Retry") { Task { if await chatService.retry() { input = "" } } }
                                    .disabled(chatService.isSending || !chatService.isOnline)
                            }
                        }.accessibilityElement(children: .contain)
                    }
                    HStack(alignment: .top, spacing: 8) {
                        TextField("Type a message...", text: $input, axis: .vertical)
                            .textFieldStyle(.roundedBorder).focused($isFocused).lineLimit(1...4)
                            .disabled(chatService.isSending || isSwitchingConversation)
                        Button { send() } label: {
                            if chatService.isSending { ProgressView() }
                            else { Image(systemName: "paperplane.fill") }
                        }.accessibilityLabel("Send message")
                            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chatService.isSending || isSwitchingConversation || !chatService.isOnline)
                    }
                }.padding()
            }
            .navigationTitle("Assistant").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(chatService.conversations) { conversation in
                            Button(conversation.title ?? "Untitled conversation") {
                                Task {
                                    isSwitchingConversation = true; defer { isSwitchingConversation = false }
                                    rememberDraft(); await chatService.loadConversation(conversation.id)
                                    if chatService.currentConversation?.id == conversation.id { input = drafts[conversation.id] ?? "" }
                                }
                            }
                        }
                    } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                    .disabled(chatService.isSending || isSwitchingConversation || !chatService.isOnline)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Menu {
                        Button("New conversation") {
                            Task { rememberDraft(); if await chatService.createConversation() != nil { input = "" } }
                        }
                        Button("Rename conversation") { renameTitle = chatService.currentConversation?.title ?? ""; renaming = true }
                        Button("Delete conversation", role: .destructive) { deleting = true }
                        Section("Assistant memory") {
                            ForEach(chatService.memory, id: \.self) { Text($0) }
                            Button("Clear remembered preferences", role: .destructive) { Task { await chatService.clearMemory() } }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .disabled(chatService.isSending || isSwitchingConversation || !chatService.isOnline)
                }
            }
            .alert("Rename conversation", isPresented: $renaming) {
                TextField("Title", text: $renameTitle)
                Button("Save") { Task { await chatService.rename(renameTitle) } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete this conversation and its history?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await chatService.deleteCurrent(); input = "" } }
            }
            .sheet(item: $citedTask) { task in NavigationStack { TaskDetailView(task: task) } }
            .task {
                await chatService.loadConversations(); await chatService.loadMemory()
                if chatService.currentConversation == nil, let first = chatService.conversations.first { await chatService.loadConversation(first.id) }
            }
        }
    }
    private func rememberDraft() { if let id = chatService.currentConversation?.id { drafts[id] = input } }
    private func send() {
        Task {
            if await chatService.send(input) { input = ""; if let id = chatService.currentConversation?.id { drafts[id] = nil }; isFocused = false }
        }
    }
    private func decide(_ action: ChatAction, confirm: Bool) {
        Task { if await chatService.decide(action, confirm: confirm)?.status == "confirmed" { await taskService.loadTasks() } }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    private var isUser: Bool { message.role == "user" }
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 60) }
            else { Text("A").font(.caption.bold()).frame(width: 32, height: 32).background(.quaternary, in: Circle()) }
            VStack(alignment: .leading, spacing: 4) {
                // Inline-only Markdown preserves line breaks; no external URLs
                // are interactive. Verified task citations have separate buttons.
                Text((try? AttributedString(markdown: message.content ?? "", options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.content ?? ""))
                    .textSelection(.enabled)
                    .padding(10).background(isUser ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    .environment(\.openURL, OpenURLAction { _ in .discarded })
                Text(message.createdAt, style: .time).font(.caption2).foregroundStyle(.secondary)
            }.contextMenu { Button("Copy message", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.content ?? "" } }
            if !isUser { Spacer(minLength: 60) }
        }.id(message.id)
    }
}
