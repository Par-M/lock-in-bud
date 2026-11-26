import SwiftUI

struct HabitFormView: View {
    enum Mode {
        case add
        case edit(Habit)
    }

    @Environment(HabitService.self) private var habitService
    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    let onSaved: ((Habit) -> Void)?

    @State private var title: String
    @State private var dailyGoal: Int
    @State private var hasRepeat: Bool
    @State private var repeatDays: Set<Int>
    @State private var isSaving = false
    @State private var errorMessage: String?

    private static let weekdayLetters = ["S", "M", "Tu", "W", "Th", "F", "Sa"]
    private static let weekdayFullNames = [
        "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
    ]

    init(mode: Mode, onSaved: ((Habit) -> Void)? = nil) {
        self.mode = mode
        self.onSaved = onSaved
        switch mode {
        case .add:
            _title = State(initialValue: "")
            _dailyGoal = State(initialValue: 1)
            _hasRepeat = State(initialValue: false)
            _repeatDays = State(initialValue: [])
        case .edit(let habit):
            _title = State(initialValue: habit.title)
            _dailyGoal = State(initialValue: habit.dailyGoal)
            _hasRepeat = State(initialValue: habit.repeatWeekdays?.isEmpty == false)
            _repeatDays = State(initialValue: Set(habit.repeatWeekdays ?? []))
        }
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedWeekdaysValue: [Int]? {
        hasRepeat ? Array(repeatDays).sorted() : nil
    }

    private func repeatDayButton(_ day: Int) -> some View {
        let isSelected = repeatDays.contains(day)
        return Button {
            if isSelected {
                repeatDays.remove(day)
            } else {
                repeatDays.insert(day)
            }
        } label: {
            Text(Self.weekdayLetters[day])
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .frame(width: 40, height: 40)
                .background(
                    isSelected ? DesignPalette.primary : DesignPalette.background,
                    in: Circle()
                )
                .foregroundStyle(isSelected ? .white : DesignPalette.ink)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.weekdayFullNames[day])
        .accessibilityIdentifier("repeatDay\(day)")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AppHeader(eyebrow: "HABIT", title: navigationTitle)

                    VStack(alignment: .leading, spacing: 10) {
                        AppEyebrow(text: "DETAILS")
                        AppCard(padding: 14) {
                            AppTextField(
                                placeholder: "Habit name",
                                text: $title,
                                font: DesignPalette.body(14)
                            )
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(DesignPalette.background, in: RoundedRectangle(cornerRadius: DesignPalette.compactRadius))
                                .accessibilityIdentifier("habitTitleField")

                            Divider().background(DesignPalette.cream)

                            Stepper(value: $dailyGoal, in: 1...100) {
                                HStack {
                                    Text("Daily goal")
                                        .font(DesignPalette.body(14))
                                    Spacer()
                                    Text("\(dailyGoal)x/day")
                                        .font(DesignPalette.body(13))
                                        .foregroundStyle(DesignPalette.secondary)
                                }
                            }
                            .tint(DesignPalette.primary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        AppEyebrow(text: "SCHEDULE")
                        AppCard(padding: 14) {
                            Toggle("Every day", isOn: Binding(
                                get: { !hasRepeat },
                                set: { isEveryDay in
                                    hasRepeat = !isEveryDay
                                    if isEveryDay {
                                        repeatDays = []
                                    }
                                }
                            ))
                            .font(DesignPalette.body(14))
                            .tint(DesignPalette.primary)

                            if hasRepeat {
                                Divider().background(DesignPalette.cream)
                                HStack(spacing: 8) {
                                    ForEach(0..<7, id: \.self) { day in
                                        repeatDayButton(day)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                if repeatDays.isEmpty {
                                    Text("Select at least one day")
                                        .font(DesignPalette.body(12))
                                        .foregroundStyle(DesignPalette.secondary)
                                }
                            }
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
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DesignPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(DesignPalette.primary)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text(saveButtonTitle)
                        }
                    }
                    .disabled(
                        isSaving || trimmedTitle.isEmpty || (hasRepeat && repeatDays.isEmpty)
                    )
                    .accessibilityIdentifier("saveHabitButton")
                }
            }
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .add: "New Habit"
        case .edit: "Edit Habit"
        }
    }

    private var saveButtonTitle: String {
        switch mode {
        case .add: "Add"
        case .edit: "Save"
        }
    }

    private func save() async {
        guard !trimmedTitle.isEmpty else { return }
        guard !hasRepeat || !repeatDays.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }

        switch mode {
        case .add:
            let created = await habitService.createHabit(
                title: trimmedTitle,
                repeatWeekdays: selectedWeekdaysValue,
                dailyGoal: dailyGoal
            )
            if created != nil {
                onSaved?(created!)
                dismiss()
            } else {
                errorMessage = habitService.errorMessage ?? "Couldn't save habit. Try again."
            }
        case .edit(let habit):
            let updated = await habitService.updateHabit(
                id: habit.id,
                title: trimmedTitle,
                repeatWeekdays: selectedWeekdaysValue,
                dailyGoal: dailyGoal
            )
            if updated != nil {
                onSaved?(updated!)
                dismiss()
            } else {
                errorMessage = habitService.errorMessage ?? "Couldn't save habit. Try again."
            }
        }
    }
}

#Preview {
    HabitFormView(mode: .add)
        .environment(HabitService())
}
