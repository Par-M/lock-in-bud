import SwiftUI

struct TaskDetailView: View {
    @Environment(TaskService.self) private var taskService
    @Environment(\.dismiss) private var dismiss

    let task: TaskItem
    @State private var currentTask: TaskItem
    @State private var showEdit = false
    @State private var confirmDelete = false
    @State private var archiveNotice = false
    @State private var archiveBusy = false
    @State private var confirmArchive = false
    @State private var errorMessage: String?

    @State private var notesDraft = ""
    @State private var checklistDraft: [ChecklistItem] = []
    @State private var didLoadDrafts = false
    @State private var saveWorkItem: DispatchWorkItem?

    init(task: TaskItem) {
        self.task = task
        _currentTask = State(initialValue: task)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                AppHeader(eyebrow: "TASK", title: currentTask.title)

                AppCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(currentTask.title)
                            .font(DesignPalette.screenTitle(20))
                            .foregroundStyle(DesignPalette.ink)
                        if let description = currentTask.description, !description.isEmpty {
                            Text(description)
                                .font(DesignPalette.body(13))
                                .foregroundStyle(DesignPalette.mutedInk)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !currentTask.isArchived && currentTask.completedAt == nil {
                    detailSection("TIME AND COMPLETION") {
                        if let estimated = currentTask.estimatedDuration, estimated > 0 {
                            CompletenessSlider(
                                estimatedMinutes: estimated,
                                completedMinutes: Binding(
                                    get: { currentTask.actualDuration ?? 0 },
                                    set: { currentTask.actualDuration = $0 }
                                ),
                                onCommit: { minutes in
                                    Task {
                                        await saveCompletedMinutes(minutes)
                                    }
                                }
                            )
                        } else {
                            HStack {
                                Text("\(currentTask.progressPercent)%")
                                    .font(DesignPalette.screenTitle(20))
                                    .monospacedDigit()
                                    .foregroundStyle(DesignPalette.ink)
                                Spacer()
                                Text("Scheduled blocks completed")
                                    .font(DesignPalette.body(12))
                                    .foregroundStyle(DesignPalette.secondary)
                            }
                            ProgressView(value: Double(currentTask.progressPercent), total: 100)
                                .tint(DesignPalette.primary)
                        }

                        if currentTask.status != .completed {
                            Button {
                                markComplete()
                            } label: {
                                HStack {
                                    Label(
                                        currentTask.repeatWeekdays?.isEmpty == false ? "Complete today’s occurrence" : "Mark Complete",
                                        systemImage: "checkmark.circle.fill"
                                    )
                                    .font(DesignPalette.body(14).weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(AppPrimaryButtonStyle())
                            .accessibilityIdentifier("completeTaskButton")
                        }
                    }
                }

                detailSection("DETAILS") {
                    detailRow("Status", currentTask.status.label)
                    Divider().background(DesignPalette.cream)
                    detailRow("Priority", currentTask.priority.label)
                    if let deadline = currentTask.deadline {
                        Divider().background(DesignPalette.cream)
                        detailRow(
                            "Deadline",
                            deadline.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                    if let duration = currentTask.estimatedDuration {
                        Divider().background(DesignPalette.cream)
                        detailRow("Duration", "\(duration) min")
                    }
                    if let category = currentTask.category, !category.isEmpty {
                        Divider().background(DesignPalette.cream)
                        detailRow("Category", category)
                    }
                }

                detailSection("NOTES & CHECKLIST") {
                    TextEditor(text: $notesDraft)
                        .font(DesignPalette.body(14))
                        .foregroundStyle(DesignPalette.ink)
                        .scrollContentBackground(.hidden)
                        .background(DesignPalette.background, in: RoundedRectangle(cornerRadius: DesignPalette.compactRadius))
                        .frame(minHeight: 100)
                        .tint(DesignPalette.primary)
                        .onChange(of: notesDraft) { _, _ in
                            scheduleSave()
                        }
                    Divider().background(DesignPalette.cream)
                    TaskChecklistEditor(items: $checklistDraft, onSave: scheduleSave)
                }
            }
            .padding(.horizontal, DesignPalette.pagePadding)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .appBackdrop()
        .navigationTitle(currentTask.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(DesignPalette.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .tint(DesignPalette.primary)
        .onAppear {
            if !didLoadDrafts {
                notesDraft = currentTask.notes ?? ""
                checklistDraft = currentTask.checklist ?? []
                didLoadDrafts = true
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Edit") {
                    showEdit = true
                }
                .accessibilityIdentifier("editTaskButton")

                Menu {
                    Button(currentTask.isArchived ? "Restore" : "Archive", systemImage: "archivebox") {
                        if currentTask.isArchived {
                            toggleArchive()
                        } else {
                            confirmArchive = true
                        }
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        confirmDelete = true
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("moreMenuButton")
            }
        }
        .sheet(isPresented: $showEdit) {
            TaskFormView(mode: .edit(currentTask)) { saved in
                currentTask = saved
            }
        }
        .confirmationDialog(
            "Delete this task?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deleteTask()
            }
        } message: {
            Text("This cannot be undone.")
        }
        .safeAreaInset(edge: .bottom) {
            if archiveNotice {
                HStack {
                    Text(currentTask.isArchived ? "Task archived" : "Task restored")
                        .font(DesignPalette.body(12))
                        .foregroundStyle(DesignPalette.ink)
                    Spacer()
                    Button("Undo") { toggleArchive() }
                        .disabled(archiveBusy)
                        .font(DesignPalette.body(12).weight(.semibold))
                        .foregroundStyle(DesignPalette.primary)
                    Button("Dismiss") { archiveNotice = false }
                        .font(DesignPalette.body(12))
                        .foregroundStyle(DesignPalette.secondary)
                }
                .padding()
                .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: DesignPalette.compactRadius))
                .padding(.horizontal, DesignPalette.pagePadding)
            }
        }
        .confirmationDialog(
            "Archive this task?",
            isPresented: $confirmArchive,
            titleVisibility: .visible
        ) {
            Button("Archive", role: .destructive) {
                toggleArchive()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Archived tasks are hidden from your lists but can be restored anytime.")
        }
        .safeAreaInset(edge: .top) {
            if let errorMessage {
                HStack {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(DesignPalette.body(12))
                    Spacer()
                    Button("Dismiss") { self.errorMessage = nil }
                        .font(DesignPalette.body(12).weight(.semibold))
                }
                .foregroundStyle(DesignPalette.ink)
                .padding()
                .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: DesignPalette.compactRadius))
                .padding(.horizontal, DesignPalette.pagePadding)
            }
        }
    }

    @ViewBuilder
    private func detailSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            AppEyebrow(text: title)
            AppCard(padding: 14) {
                content()
            }
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(DesignPalette.body(14))
                .foregroundStyle(DesignPalette.ink)
            Spacer(minLength: 8)
            Text(value)
                .font(DesignPalette.body(13))
                .foregroundStyle(DesignPalette.mutedInk)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggleArchive() {
        guard !archiveBusy else { return }
        archiveBusy = true
        Task {
            defer { archiveBusy = false }
            do {
                if currentTask.isArchived {
                    currentTask = try await taskService.restoreTask(currentTask)
                } else {
                    currentTask = try await taskService.archiveTask(currentTask)
                }
                archiveNotice = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteTask() {
        Task {
            do {
                try await taskService.deleteTask(currentTask)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func saveCompletedMinutes(_ minutes: Int) async {
        do {
            currentTask = try await taskService.setCompletedMinutes(
                id: currentTask.id,
                minutes: minutes
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func markComplete() {
        Task {
            do {
                currentTask = try await taskService.completeTask(
                    id: currentTask.id,
                    minutes: nil,
                    productivity: currentTask.productivity
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { saveNotesAndChecklist() }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
    }

    private func saveNotesAndChecklist() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        var updated = currentTask
        let notes = notesDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.notes = notes.isEmpty ? nil : notes
        updated.checklist = checklistDraft.isEmpty ? nil : checklistDraft
        let previous = currentTask
        currentTask = updated
        Task {
            do {
                let saved = try await taskService.updateTask(updated)
                await MainActor.run { currentTask = saved }
            } catch {
                await MainActor.run {
                    currentTask = previous
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
