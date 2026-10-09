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
        List {
            Section {
                Text(currentTask.title)
                    .font(.title2.bold())
                if let description = currentTask.description, !description.isEmpty {
                    Text(description)
                        .foregroundStyle(.secondary)
                }
            }

            if !currentTask.isArchived && currentTask.completedAt == nil {
                Section("Time and completion") {
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
                                .font(.title3.weight(.semibold))
                                .monospacedDigit()
                            Spacer()
                            Text("Scheduled blocks completed")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(currentTask.progressPercent), total: 100)
                    }

                    if currentTask.status != .completed {
                        Button {
                            markComplete()
                        } label: {
                            Label(currentTask.repeatWeekdays?.isEmpty == false ? "Complete today’s occurrence" : "Mark Complete", systemImage: "checkmark.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .accessibilityIdentifier("completeTaskButton")
                    }
                }
            }

            Section("Details") {
                LabeledContent("Status", value: currentTask.status.label)
                LabeledContent("Priority", value: currentTask.priority.label)
                if let deadline = currentTask.deadline {
                    LabeledContent(
                        "Deadline",
                        value: deadline.formatted(date: .abbreviated, time: .shortened)
                    )
                }
                if let duration = currentTask.estimatedDuration {
                    LabeledContent("Duration", value: "\(duration) min")
                }
                if let category = currentTask.category, !category.isEmpty {
                    LabeledContent("Category", value: category)
                }
            }

            Section("Notes & Checklist") {
                TextEditor(text: $notesDraft)
                    .frame(minHeight: 100)
                    .onChange(of: notesDraft) { _, _ in
                        scheduleSave()
                    }
                TaskChecklistEditor(items: $checklistDraft, onSave: scheduleSave)
            }
        }
        .navigationTitle(currentTask.title)
        .navigationBarTitleDisplayMode(.inline)
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
            if archiveNotice { HStack { Text(currentTask.isArchived ? "Task archived" : "Task restored"); Spacer(); Button("Undo") { toggleArchive() }.disabled(archiveBusy); Button("Dismiss") { archiveNotice = false } }.padding().background(.regularMaterial) }
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
            if let errorMessage { HStack { Label(errorMessage, systemImage: "exclamationmark.triangle").font(.caption); Button("Dismiss") { self.errorMessage = nil } }.padding().background(.regularMaterial) }
        }
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
