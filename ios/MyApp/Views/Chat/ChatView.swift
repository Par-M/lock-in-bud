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
    @State private var showingHistory = false
    @State private var citedTask: TaskItem?
    @FocusState private var isFocused: Bool
    private let suggestions = ["What's my plan today?", "What's overdue?", "What can I focus on right now?"]

    private var visibleMessages: [ChatMessage] {
        chatService.messages.filter { $0.role == "user" || $0.role == "assistant" }
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !chatService.isSending
            && !isSwitchingConversation
            && chatService.isOnline
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                messageList
                Divider().background(DesignPalette.cream)
                composer
            }
            .appBackdrop()
            .navigationTitle("Assistant").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DesignPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(DesignPalette.primary)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingHistory = true } label: { Label("History", systemImage: "clock.arrow.circlepath") }
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
            .sheet(isPresented: $showingHistory) { historySheet }
            .task {
                await chatService.loadConversations(); await chatService.loadMemory()
                if chatService.currentConversation == nil, let first = chatService.conversations.first { await chatService.loadConversation(first.id) }
            }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if chatService.hasOlderMessages {
                        loadOlderButton
                    }
                    if chatService.messages.isEmpty && !chatService.isSending {
                        emptyState
                    }
                    ForEach(visibleMessages) { message in
                        MessageBubble(message: message)
                        ForEach(message.toolResult?.citations ?? [], id: \.id) { citation in
                            citationButton(citation)
                        }
                    }
                    ForEach(chatService.actions) { action in
                        actionCard(action)
                    }
                    if chatService.isSending {
                        sendingIndicator
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .onChange(of: chatService.messages.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .refreshable {
                guard !chatService.isSending, !isSwitchingConversation else { return }
                await chatService.loadConversations()
                if let id = chatService.currentConversation?.id { await chatService.loadConversation(id) }
            }
        }
    }

    private var loadOlderButton: some View {
        Button("Load older messages") { Task { await chatService.loadOlder() } }
            .font(DesignPalette.body(12).weight(.semibold))
            .foregroundStyle(DesignPalette.primary)
            .disabled(!chatService.isOnline || chatService.isSending)
    }

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView("Ask the assistant", systemImage: "bubble.left.and.bubble.right",
                               description: Text("Ask about your day. Review and confirm proposed changes before they are applied."))
        ForEach(suggestions, id: \.self) { prompt in
            Button {
                input = prompt
            } label: {
                Text(prompt)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AppSecondaryButtonStyle())
        }
    }

    private func citationButton(_ citation: ChatCitation) -> some View {
        Button {
            Task { citedTask = await chatService.citedTask(citation.id) }
        } label: {
            Text(citation.title)
        }
        .font(DesignPalette.body(12).weight(.semibold))
        .foregroundStyle(DesignPalette.primary)
        .disabled(!chatService.isOnline)
    }

    private func actionTitle(for action: ChatAction) -> String {
        if action.name == "create_task" { return "Create task" }
        if action.name == "complete_task" { return "Complete occurrence" }
        if action.name == "start_focus_session" { return "Start timer" }
        return "Remember preference"
    }

    @ViewBuilder
    private func actionCard(_ action: ChatAction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(action.name.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(DesignPalette.body(14).weight(.semibold))
                .foregroundStyle(DesignPalette.ink)
            Text(action.summary)
                .font(DesignPalette.body(12))
                .foregroundStyle(DesignPalette.ink)
            if let deadline = action.args["deadline"]?.string {
                Text("Deadline: \(deadline)")
                    .font(DesignPalette.body(12))
                    .foregroundStyle(DesignPalette.secondary)
            }
            if let duration = action.args["estimated_duration"], case .number(let minutes) = duration {
                Text("\(Int(minutes)) minutes")
                    .font(DesignPalette.body(12))
                    .foregroundStyle(DesignPalette.secondary)
            }
            if action.status == "pending" {
                HStack {
                    Button(actionTitle(for: action)) { decide(action, confirm: true) }
                    Button("Cancel") { decide(action, confirm: false) }
                }
                .font(DesignPalette.body(12).weight(.semibold))
                .foregroundStyle(DesignPalette.primary)
                .disabled(chatService.isSending || !chatService.isOnline)
            } else {
                Text(action.status.capitalized)
                    .font(DesignPalette.body(11))
                    .foregroundStyle(DesignPalette.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignPalette.cream, in: RoundedRectangle(cornerRadius: DesignPalette.cardRadius))
    }

    private var sendingIndicator: some View {
        HStack {
            ProgressView()
                .tint(DesignPalette.primary)
            Text(chatService.partialText.isEmpty ? "Assistant is thinking…" : chatService.partialText)
                .font(DesignPalette.body(12))
                .foregroundStyle(DesignPalette.secondary)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !chatService.isOnline {
                Text("The assistant needs a connection. History is still readable.")
                    .font(DesignPalette.body(11))
                    .foregroundStyle(DesignPalette.secondary)
            }
            if let error = chatService.errorMessage {
                HStack {
                    Text(error)
                        .font(DesignPalette.body(11))
                        .foregroundStyle(.red)
                    if chatService.failedDraft != nil {
                        retryButton
                    }
                }
                .accessibilityElement(children: .contain)
            }
            HStack(alignment: .top, spacing: 8) {
                messageField
                sendButton
            }
        }
        .padding()
        .background(DesignPalette.background)
    }

    private var messageField: some View {
        AppTextField(
            placeholder: "Type a message...",
            text: $input,
            font: DesignPalette.body(14),
            axis: .vertical
        )
            .focused($isFocused)
            .lineLimit(1...4)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: DesignPalette.compactRadius))
            .disabled(chatService.isSending || isSwitchingConversation)
    }

    private var retryButton: some View {
        Button("Retry") { Task { if await chatService.retry() { input = "" } } }
            .font(DesignPalette.body(12).weight(.semibold))
            .foregroundStyle(DesignPalette.primary)
            .disabled(chatService.isSending || !chatService.isOnline)
    }

    private var sendButton: some View {
        Button { send() } label: {
            if chatService.isSending {
                ProgressView()
                    .tint(DesignPalette.primary)
            } else {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(DesignPalette.primary)
            }
        }
        .frame(width: 44, height: 44)
        .background(DesignPalette.sage, in: Circle())
        .buttonStyle(.plain)
        .accessibilityLabel("Send message")
        .disabled(!canSend)
    }

    @ViewBuilder
    private var historySheet: some View {
        NavigationStack {
            List {
                ForEach(chatService.conversations) { conversation in
                    conversationRow(conversation)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .appBackdrop()
            .navigationTitle("Conversations").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DesignPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(DesignPalette.primary)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingHistory = false } } }
        }
    }

    private func rememberDraft() { if let id = chatService.currentConversation?.id { drafts[id] = input } }

    private func send() {
        Task {
            if await chatService.send(input) {
                input = ""
                if let id = chatService.currentConversation?.id { drafts[id] = nil }
                isFocused = false
            }
        }
    }

    private func decide(_ action: ChatAction, confirm: Bool) {
        Task { if await chatService.decide(action, confirm: confirm)?.status == "confirmed" { await taskService.loadTasks() } }
    }

    @ViewBuilder
    private func conversationRow(_ conversation: ChatConversation) -> some View {
        Button {
            Task {
                isSwitchingConversation = true
                defer { isSwitchingConversation = false }
                rememberDraft()
                await chatService.loadConversation(conversation.id)
                if chatService.currentConversation?.id == conversation.id {
                    input = drafts[conversation.id] ?? ""
                }
                showingHistory = false
            }
        } label: {
            HStack {
                Text(conversation.title ?? "Untitled conversation")
                    .font(DesignPalette.body(14))
                    .foregroundStyle(DesignPalette.ink)
                Spacer()
                if chatService.currentConversation?.id == conversation.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(DesignPalette.primary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(DesignPalette.card)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                Task { await chatService.deleteConversation(conversation.id) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    private var isUser: Bool { message.role == "user" }
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 60) }
            else {
                Text("A")
                    .font(DesignPalette.body(12).weight(.bold))
                    .foregroundStyle(DesignPalette.primary)
                    .frame(width: 32, height: 32)
                    .background(DesignPalette.cream, in: Circle())
            }
            VStack(alignment: .leading, spacing: 4) {
                // Inline-only Markdown preserves line breaks; no external URLs
                // are interactive. Verified task citations have separate buttons.
                Text((try? AttributedString(markdown: message.content ?? "", options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.content ?? ""))
                    .font(DesignPalette.body(14))
                    .foregroundStyle(DesignPalette.ink)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(isUser ? DesignPalette.sage : DesignPalette.card, in: RoundedRectangle(cornerRadius: DesignPalette.compactRadius))
                    .environment(\.openURL, OpenURLAction { _ in .discarded })
                Text(message.createdAt, style: .time)
                    .font(DesignPalette.body(10))
                    .foregroundStyle(DesignPalette.secondary)
            }.contextMenu { Button("Copy message", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.content ?? "" } }
            if !isUser { Spacer(minLength: 60) }
        }.id(message.id)
    }
}
