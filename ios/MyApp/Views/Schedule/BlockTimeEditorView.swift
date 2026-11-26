import SwiftUI

struct BlockTimeEditorView: View {
    let block: CalendarBlock

    @Environment(ScheduleService.self) private var scheduleService
    @Environment(\.dismiss) private var dismiss

    @State private var start: Date
    @State private var end: Date
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmDelete = false

    init(block: CalendarBlock) {
        self.block = block
        _start = State(initialValue: block.startAt)
        _end = State(initialValue: block.endAt)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AppHeader(eyebrow: "SCHEDULE", title: "Edit block.")

                    settingSection("TASK") {
                        Text(block.title)
                            .font(DesignPalette.body(14).weight(.medium))
                            .foregroundStyle(DesignPalette.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
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

                    AppCard(padding: 14) {
                        Button {
                            Task {
                                if block.completedAt != nil {
                                    await reopen()
                                } else {
                                    await complete()
                                }
                            }
                        } label: {
                            HStack {
                                Label(
                                    block.completedAt != nil ? "Reopen Block" : "Mark Complete",
                                    systemImage: block.completedAt != nil ? "arrow.uturn.backward.circle" : "checkmark.circle"
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

                    AppCard(padding: 14) {
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            HStack {
                                Text("Delete Block")
                                    .font(DesignPalette.body(14).weight(.semibold))
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isSaving)
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
            .navigationTitle("Edit Block")
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
                        Task { await save() }
                    }
                    .disabled(start >= end || isSaving)
                }
            }
            .confirmationDialog(
                "Delete this block?",
                isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    Task { await delete() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes \(block.title) from your schedule. This cannot be undone.")
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

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await scheduleService.updateBlockTime(block, start: start, end: end)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await scheduleService.deleteBlock(block)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func complete() async {
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await scheduleService.completeBlock(block, note: nil)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reopen() async {
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await scheduleService.reopenBlock(block)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    BlockTimeEditorView(
        block: CalendarBlock(
            id: UUID(),
            userId: UUID(),
            taskId: UUID(),
            calendarEventId: nil,
            title: "Write report",
            startAt: Date(),
            endAt: Date().addingTimeInterval(3600),
            completedAt: nil,
            completionNote: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
    )
    .environment(ScheduleService())
}
