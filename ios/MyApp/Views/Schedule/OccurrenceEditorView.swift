import SwiftUI

struct OccurrenceEditorView: View {
    let task: TaskItem
    let date: Date

    @Environment(TaskService.self) private var taskService
    @Environment(\.dismiss) private var dismiss

    @State private var start: Date
    @State private var end: Date
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showScopeDialog = false

    private var isRepeating: Bool {
        !(task.repeatWeekdays ?? []).isEmpty
    }

    private var occurrenceCompleted: Bool {
        guard isRepeating else {
            return task.status == .completed
        }
        return task.repeatOverrides?[OccurrenceDateKey.key(for: date)]?.completed == true
    }

    init(task: TaskItem, date: Date) {
        self.task = task
        self.date = date
        let times = Self.occurrenceTimes(task: task, date: date)
        _start = State(initialValue: times.start)
        _end = State(initialValue: times.end)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Event") {
                    Text(task.title)
                }
                Section {
                    Button {
                        Task { await toggleCompletion() }
                    } label: {
                        Label(
                            completionLabel,
                            systemImage: occurrenceCompleted ? "xmark.circle" : "checkmark.circle"
                        )
                    }
                    .disabled(isSaving)
                }
                Section("Time") {
                    DatePicker("Start", selection: $start)
                    DatePicker("End", selection: $end)
                    if start >= end {
                        Text("End must be after start")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                if isRepeating {
                    Section {
                        Text("This event repeats. You'll choose whether the new time applies to today only or to all future events.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isRepeating ? "Edit Occurrence" : "Edit Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if isRepeating {
                            showScopeDialog = true
                        } else {
                            Task { await save(scope: .fromNowOnwards) }
                        }
                    }
                    .disabled(start >= end || isSaving)
                }
            }
            .confirmationDialog(
                "Apply changes to…",
                isPresented: $showScopeDialog,
                titleVisibility: .visible
            ) {
                Button("Only this event") {
                    Task { await save(scope: .thisEventOnly) }
                }
                Button("From now onwards") {
                    Task { await save(scope: .fromNowOnwards) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Choose how the new time should apply to this repeating event.")
            }
        }
    }

    private var completionLabel: String {
        if occurrenceCompleted {
            return "Reopen this event"
        }
        return isRepeating ? "Complete this occurrence" : "Mark complete"
    }

    private func toggleCompletion() async {
        isSaving = true
        defer { isSaving = false }
        do {
            if occurrenceCompleted {
                if isRepeating {
                    _ = try await taskService.reopenOccurrence(task, on: date)
                } else {
                    _ = try await taskService.setStatus(.pending, for: task)
                }
            } else {
                _ = try await taskService.completeOccurrence(task, on: date)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save(scope: OccurrenceScope) async {
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await taskService.updateOccurrence(
                task,
                date: date,
                scope: scope,
                startAt: start,
                endAt: end
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func occurrenceTimes(
        task: TaskItem,
        date: Date
    ) -> (start: Date, end: Date) {
        let override = task.repeatOverrides?[OccurrenceDateKey.key(for: date)]
        let baseStart = task.startAt ?? date
        let baseEnd = task.endAt ?? baseStart.addingTimeInterval(30 * 60)
        let interval = CalendarEventItem.occurrenceInterval(start: baseStart, end: baseEnd, on: date)
        return (override?.startAt ?? interval.start, override?.endAt ?? interval.end)
    }
}
