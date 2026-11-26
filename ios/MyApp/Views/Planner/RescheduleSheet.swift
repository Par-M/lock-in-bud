import SwiftUI

struct RescheduleSheet: View {
    let task: TaskItem
    let onSubmit: (Int, Date?, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var minutes: Int
    @State private var hasDeadline: Bool
    @State private var deadline: Date
    @State private var reason: String = ""

    private static let suggestedReasons = [
        "Took longer than planned",
        "Got distracted",
        "Overlapping meetings",
        "Lost track of time",
        "Task was too big",
    ]

    init(task: TaskItem, onSubmit: @escaping (Int, Date?, String?) -> Void) {
        self.task = task
        self.onSubmit = onSubmit
        let duration = min(max(task.estimatedDuration ?? 30, 5), 180)
        _minutes = State(initialValue: duration)
        let now = Date()
        let existing = task.deadline.flatMap { $0 > now ? $0 : nil }
        _hasDeadline = State(initialValue: false)
        _deadline = State(
            initialValue: existing
                ?? now.addingTimeInterval(TimeInterval(duration * 60))
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AppHeader(eyebrow: "RESCHEDULE", title: "Make room.")

                    settingSection("TASK") {
                        valueRow("Title", task.title)
                        if let deadline = task.deadline {
                            Divider().background(DesignPalette.cream)
                            valueRow(
                                "Deadline",
                                deadline.formatted(date: .abbreviated, time: .shortened)
                            )
                        }
                    }

                    settingSection("HOW MUCH TIME REMAINS?") {
                        Picker("Minutes", selection: $minutes) {
                            ForEach(Array(stride(from: 5, through: 180, by: 5)), id: \.self) { value in
                                Text("\(value) min").tag(value)
                            }
                        }
                        .pickerStyle(.wheel)
                        .tint(DesignPalette.primary)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Minutes remaining")
                    }

                    settingSection("NEW DEADLINE") {
                        Toggle("Change deadline", isOn: $hasDeadline)
                            .font(DesignPalette.body(14))
                            .tint(DesignPalette.primary)
                        if hasDeadline {
                            Divider().background(DesignPalette.cream)
                            DatePicker(
                                "Due",
                                selection: $deadline,
                                in: Date()...,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                            .font(DesignPalette.body(14))
                            .tint(DesignPalette.primary)
                        }
                    }
                    .onChange(of: minutes) { _, newValue in
                        guard !hasDeadline else { return }
                        if let existing = task.deadline, existing > Date() { return }
                        deadline = Date()
                            .addingTimeInterval(TimeInterval(newValue * 60))
                    }

                    settingSection("WHY WAS IT MISSED? (OPTIONAL)") {
                        AppTextField(
                            placeholder: "Reason",
                            text: $reason,
                            font: DesignPalette.body(14),
                            axis: .vertical
                        )
                            .lineLimit(2...4)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(DesignPalette.background, in: RoundedRectangle(cornerRadius: DesignPalette.compactRadius))
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Self.suggestedReasons, id: \.self) { suggestion in
                                    Button {
                                        reason = suggestion
                                    } label: {
                                        Text(suggestion)
                                            .font(DesignPalette.body(11).weight(.semibold))
                                            .foregroundStyle(DesignPalette.primary)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 7)
                                            .background(DesignPalette.sage, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    AppCard(padding: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("What happens next")
                                .font(DesignPalette.body(12).weight(.semibold))
                                .foregroundStyle(DesignPalette.ink)
                            Text(explanation)
                                .font(DesignPalette.body(11))
                                .foregroundStyle(DesignPalette.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, DesignPalette.pagePadding)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .appBackdrop()
            .navigationTitle("Reschedule Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DesignPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(DesignPalette.primary)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Reschedule") {
                        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSubmit(
                            minutes,
                            hasDeadline ? deadline : nil,
                            trimmed.isEmpty ? nil : trimmed
                        )
                        dismiss()
                    }
                    .font(DesignPalette.body(14).weight(.semibold))
                }
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

    private func valueRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(DesignPalette.body(14))
                .foregroundStyle(DesignPalette.ink)
            Spacer(minLength: 8)
            Text(value)
                .font(DesignPalette.body(13))
                .foregroundStyle(DesignPalette.mutedInk)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var explanation: String {
        let move = "Your unfinished calendar blocks for this task will move into the next \(minutes) minutes."
        guard hasDeadline else { return move }
        let due = deadline.formatted(date: .abbreviated, time: .shortened)
        return move + " The deadline will be set to \(due)."
    }
}
