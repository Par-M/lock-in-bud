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
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AppHeader(eyebrow: "SCHEDULE", title: isRepeating ? "Edit Occurrence" : "Edit Event")

                    settingSection("EVENT") {
                        Text(task.title)
                            .font(DesignPalette.body(14).weight(.medium))
                            .foregroundStyle(DesignPalette.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    AppCard(padding: 14) {
                        Button {
                            Task { await toggleCompletion() }
                        } label: {
                            HStack {
                                Label(
                                    completionLabel,
                                    systemImage: occurrenceCompleted ? "xmark.circle" : "checkmark.circle"
                                )
                                .font(DesignPalette.body(14).weight(.semibold))
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isSaving)
                    }

                    settingSection("TIME") {
                        DatePicker("Start", selection: $start)
                            .font(DesignPalette.body(14))
                            .tint(DesignPalette.primary)
                        Divider().background(DesignPalette.cream)
                        DatePicker("End", selection: $end)
                            .font(DesignPalette.body(14))
                            .tint(DesignPalette.primary)
                        if start >= end {
                            Divider().background(DesignPalette.cream)
                            Text("End must be after start")
                                .font(DesignPalette.body(12))
                                .foregroundStyle(.red)
                        }
                    }

                    if isRepeating {
                        AppCard(padding: 14) {
                            Text("This event repeats. You'll choose whether the new time applies to today only or to all future events.")
                                .font(DesignPalette.body(12))
                                .foregroundStyle(DesignPalette.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if let errorMessage {
                        AppCard(padding: 14) {
                            Text(errorMessage)
                                .font(DesignPalette.body(12))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, DesignPalette.pagePadding)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .appBackdrop()
            .navigationTitle(isRepeating ? "Edit Occurrence" : "Edit Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DesignPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(DesignPalette.primary)
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

    @ViewBuilder
    private func settingSection<Content: View>(
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
