import SwiftUI

// MARK: - Screen-specific panda (New task frame layers)

private struct NewTaskPanda: View {
    var size: CGFloat = 58

    private var scale: CGFloat { size / 72 }

    private func layer(
        _ name: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        Image(name)
            .resizable()
            .scaledToFit()
            .frame(width: width * scale, height: height * scale)
            .offset(x: x * scale, y: y * scale)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            layer("body-c9985b31", x: 19.78, y: 32.91, width: 33.90, height: 26.68)
            layer("feet-cf0fd98b", x: 16.83, y: 50.32, width: 38.19, height: 9.70)
            layer("ears-ba615e97", x: 19.70, y: 12.19, width: 33.75, height: 8.94)
            layer("head-f7f0cf6d", x: 19.55, y: 13.79, width: 33.30, height: 26.70)
            layer("thumbs-up-2d3c959b", x: 11.55, y: 30.63, width: 14.04, height: 16.00)
            layer("bamboo", x: 49.80, y: 29.70, width: 11.75, height: 23.72)
            layer("holding-paw-346965a5", x: 47.00, y: 39.42, width: 9.82, height: 8.62)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct DesignToggleRow: View {
    let icon: String?
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 19, height: 19)
                    .accessibilityHidden(true)
            }
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignPalette.ink)
            Spacer(minLength: 8)
            Button {
                isOn.toggle()
            } label: {
                Group {
                    if isOn {
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(DesignPalette.primary)
                                .frame(width: 42, height: 26)
                            Circle()
                                .fill(.white)
                                .frame(width: 20, height: 20)
                                .offset(x: 19)
                        }
                    } else {
                        Image("off")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 42, height: 26)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityValue(isOn ? "On" : "Off")
        }
        .padding(.vertical, 16)
    }
}

private struct DividerRow: View {
    var body: some View {
        Color(red: 233 / 255, green: 236 / 255, blue: 228 / 255)
            .frame(height: 1)
    }
}

// MARK: - Task form

struct TaskFormView: View {
    enum Mode {
        case add
        case edit(TaskItem)
    }

    @Environment(TaskService.self) private var taskService
    @Environment(ScheduleService.self) private var scheduleService
    @Environment(CategoryStore.self) private var categoryStore
    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    let onSaved: ((TaskItem) -> Void)?

    @State private var title: String
    @State private var detail: String
    @State private var hasFixedEvent: Bool
    @State private var fixedStart: Date
    @State private var fixedEnd: Date
    @State private var hasDeadline: Bool
    @State private var deadline: Date
    @State private var priority: TaskPriority
    @State private var status: TaskStatus
    @State private var hasDuration: Bool
    @State private var durationHours: Int
    @State private var durationMinutesPart: Int
    @State private var hasRepeat: Bool
    @State private var repeatDays: Set<Int>
    @State private var hasRepeatEnd: Bool
    @State private var repeatEndDate: Date
    @State private var category: String
    @State private var notes: String
    @State private var checklist: [ChecklistItem]
    @State private var newChecklistItem = ""
    @State private var moreOptions = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(mode: Mode, onSaved: ((TaskItem) -> Void)? = nil) {
        self.mode = mode
        self.onSaved = onSaved
        switch mode {
        case .add:
            _title = State(initialValue: "")
            _detail = State(initialValue: "")
            _hasFixedEvent = State(initialValue: false)
            let defaultStart = Self.roundedToQuarterHour(Date())
            _fixedStart = State(initialValue: defaultStart)
            _fixedEnd = State(initialValue: defaultStart.addingTimeInterval(30 * 60))
            _hasDeadline = State(initialValue: false)
            _deadline = State(initialValue: Self.roundedToQuarterHour(Date()))
            _priority = State(initialValue: .medium)
            _status = State(initialValue: .pending)
            _hasDuration = State(initialValue: false)
            _durationHours = State(initialValue: 0)
            _durationMinutesPart = State(initialValue: 30)
            _hasRepeat = State(initialValue: false)
            _repeatDays = State(initialValue: [])
            _hasRepeatEnd = State(initialValue: false)
            _repeatEndDate = State(
                initialValue: Self.roundedToQuarterHour(Date())
                    .addingTimeInterval(30 * 24 * 3600)
            )
            _category = State(initialValue: "")
            _notes = State(initialValue: "")
            _checklist = State(initialValue: [])
        case .edit(let task):
            _title = State(initialValue: task.title)
            _detail = State(initialValue: task.description ?? "")
            _hasFixedEvent = State(initialValue: task.startAt != nil)
            let start = task.startAt ?? Self.roundedToQuarterHour(Date())
            _fixedStart = State(initialValue: start)
            _fixedEnd = State(
                initialValue: task.endAt ?? start.addingTimeInterval(30 * 60)
            )
            _hasDeadline = State(initialValue: task.deadline != nil)
            _deadline = State(initialValue: task.deadline ?? Date())
            _priority = State(initialValue: task.priority)
            _status = State(initialValue: task.status)
            _hasDuration = State(initialValue: task.estimatedDuration != nil)
            let minutes = task.estimatedDuration ?? 30
            _durationHours = State(initialValue: minutes / 60)
            _durationMinutesPart = State(initialValue: minutes % 60)
            _hasRepeat = State(initialValue: task.repeatWeekdays?.isEmpty == false)
            _repeatDays = State(initialValue: Set(task.repeatWeekdays ?? []))
            _hasRepeatEnd = State(initialValue: task.repeatEndsOn != nil)
            _repeatEndDate = State(
                initialValue: task.repeatEndsOn
                    ?? Self.roundedToQuarterHour(Date())
                        .addingTimeInterval(30 * 24 * 3600)
            )
            _category = State(initialValue: task.category ?? "")
            _notes = State(initialValue: task.notes ?? "")
            _checklist = State(initialValue: task.checklist ?? [])
        }
    }

    private static func roundedToQuarterHour(_ date: Date) -> Date {
        let calendar = Calendar.current
        let minute = calendar.component(.minute, from: date)
        return calendar.date(
            bySettingHour: calendar.component(.hour, from: date),
            minute: minute - (minute % 15),
            second: 0,
            of: date
        ) ?? date
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var fixedStartBinding: Binding<Date> {
        Binding(
            get: { fixedStart },
            set: { newValue in
                let calendar = Calendar.current
                var endDate = fixedEnd
                if !calendar.isDate(fixedEnd, inSameDayAs: newValue) {
                    let time = calendar.dateComponents([.hour, .minute], from: fixedEnd)
                    endDate = calendar.date(
                        bySettingHour: time.hour ?? 0,
                        minute: time.minute ?? 0,
                        second: 0,
                        of: newValue
                    ) ?? newValue
                }
                fixedStart = newValue
                if endDate <= newValue {
                    endDate = newValue.addingTimeInterval(30 * 60)
                }
                fixedEnd = endDate
            }
        )
    }

    private var totalDurationMinutes: Int {
        durationHours * 60 + durationMinutesPart
    }

    private var totalDurationLabel: String {
        if totalDurationMinutes < 60 {
            return "= \(totalDurationMinutes) min"
        }
        return "= \(totalDurationMinutes / 60)h \(totalDurationMinutes % 60)m"
    }

    private static let weekdayLetters = ["S", "M", "Tu", "W", "Th", "F", "Sa"]
    private static let weekdayFullNames = [
        "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
    ]

    private var selectedWeekdaysValue: [Int]? {
        hasRepeat ? Array(repeatDays).sorted() : nil
    }

    private var repeatEndsOnValue: Date? {
        guard hasRepeat, hasRepeatEnd else { return nil }
        return repeatEndDate
    }

    private var categorySuggestions: [String] {
        guard !category.isEmpty else { return [] }
        return Array(
            categoryStore.categories(from: taskService.tasks)
                .filter { $0.localizedCaseInsensitiveContains(category) && $0 != category }
                .prefix(5)
        )
    }

    private var segmentTrack: Color {
        Color(red: 228 / 255, green: 231 / 255, blue: 220 / 255)
    }

    private var disabledCTA: Color {
        Color(red: 220 / 255, green: 225 / 255, blue: 213 / 255)
    }

    private var disabledText: Color {
        Color(red: 104 / 255, green: 113 / 255, blue: 95 / 255)
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
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .frame(minWidth: 44, minHeight: 44)
                .background(
                    isSelected ? DesignPalette.primary : DesignPalette.sage,
                    in: Circle()
                )
                .foregroundStyle(isSelected ? .white : DesignPalette.ink)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.weekdayFullNames[day])
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityIdentifier("repeatDay\(day)")
    }

    // MARK: Screen sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 10) {
                Text("NEW TASK")
                    .font(DesignPalette.eyebrow())
                    .kerning(1.6)
                    .foregroundStyle(DesignPalette.primary)

                Spacer(minLength: 8)

                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 6) {
                        Image("close-icon")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                        Text("Cancel")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(DesignPalette.secondary)
                    }
                    .frame(height: 44)
                    .padding(.horizontal, 12)
                    .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")
            }

            Text("Write it down.")
                .font(DesignPalette.screenTitle())
                .kerning(-1)
                .foregroundStyle(DesignPalette.ink)
                .minimumScaleFactor(0.8)
        }
    }

    private var encouragementCard: some View {
        HStack(spacing: 12) {
            NewTaskPanda(size: 58)
            VStack(alignment: .leading, spacing: 2) {
                Text("Give the chaos a plan.")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignPalette.ink)
                Text("Free up some brain space.")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignPalette.ink)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignPalette.cream, in: RoundedRectangle(cornerRadius: 18))
    }

    private var titleCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What would you like to do?")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(DesignPalette.ink)
            AppTextField(
                placeholder: "Title",
                text: $title,
                font: .system(size: 16, weight: .medium, design: .rounded)
            )
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
                .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityIdentifier("taskTitleField")
        }
    }

    private var typePicker: some View {
        Picker("Type", selection: $hasFixedEvent) {
            Text("Task").tag(false)
            Text("Event").tag(true)
        }
        .pickerStyle(.segmented)
        .tint(DesignPalette.primary)
        .padding(4)
        .background(segmentTrack, in: RoundedRectangle(cornerRadius: 13))
    }

    private var timingCard: some View {
        VStack(spacing: 0) {
            DesignToggleRow(icon: "calendar-icon-f1205337", label: "Deadline", isOn: $hasDeadline)
            if hasDeadline {
                VStack(spacing: 8) {
                    DatePicker("Date", selection: $deadline, displayedComponents: .date)
                        .tint(DesignPalette.primary)
                        .foregroundStyle(DesignPalette.ink)
                    DatePicker("Time", selection: $deadline, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.compact)
                        .tint(DesignPalette.primary)
                        .foregroundStyle(DesignPalette.ink)
                }
                .padding(.bottom, 16)
            }

            DividerRow()

            DesignToggleRow(icon: "clock-icon", label: "Estimated Duration", isOn: $hasDuration)
            if hasDuration {
                durationFields
                    .padding(.bottom, 16)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private var durationFields: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hours")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(DesignPalette.secondary)
                TextField("0", value: $durationHours, format: .number)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .tint(DesignPalette.primary)
                    .foregroundStyle(DesignPalette.ink)
                    .frame(width: 64)
            }
            Text("h")
                .foregroundStyle(DesignPalette.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Minutes")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(DesignPalette.secondary)
                TextField("0", value: $durationMinutesPart, format: .number)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .tint(DesignPalette.primary)
                    .foregroundStyle(DesignPalette.ink)
                    .frame(width: 64)
            }
            Text("m")
                .foregroundStyle(DesignPalette.secondary)
            Spacer(minLength: 4)
            Text(totalDurationLabel)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(DesignPalette.secondary)
        }
    }

    private var moreOptionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                moreOptions.toggle()
            } label: {
                HStack {
                    Text("More options")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(DesignPalette.ink)
                    Spacer()
                    Image(moreOptions ? "up-icon" : "down-icon-d07e1302")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 17, height: 17)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More options")
            .accessibilityValue(moreOptions ? "Expanded" : "Collapsed")

            if moreOptions {
                priorityRepeatsCard
                if case .edit = mode {
                    statusCard
                }
            }
        }
    }

    private var priorityRepeatsCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image("flag-icon-1b0eece2")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 19, height: 19)
                    .accessibilityHidden(true)
                Text("Priority")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignPalette.ink)
                Spacer(minLength: 8)
                Menu {
                    ForEach(TaskPriority.allCases) { value in
                        Button {
                            priority = value
                        } label: {
                            Text(value.label)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image("flag-icon-1b0eece2")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 12, height: 12)
                        Text(priority.label)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(
                                Color(red: 98 / 255, green: 99 / 255, blue: 62 / 255)
                            )
                        Image("down-icon-d07e1302")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 12, height: 12)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(DesignPalette.cream, in: RoundedRectangle(cornerRadius: 10))
                }
                .accessibilityLabel("Priority")
            }
            .padding(.vertical, 16)

            DividerRow()

            DesignToggleRow(icon: "repeat-icon", label: "Repeats", isOn: $hasRepeat)
            if hasRepeat {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 8) {
                    ForEach(0..<7, id: \.self) { day in
                        repeatDayButton(day)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)

                DividerRow()
                DesignToggleRow(icon: nil, label: "End Repeat", isOn: $hasRepeatEnd)
                if hasRepeatEnd {
                    DatePicker(
                        "Repeat Until",
                        selection: $repeatEndDate,
                        in: Date()...,
                        displayedComponents: .date
                    )
                    .tint(DesignPalette.primary)
                    .foregroundStyle(DesignPalette.ink)
                    .padding(.bottom, 16)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var statusCard: some View {
        HStack(spacing: 10) {
            Text("Status")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignPalette.ink)
            Spacer(minLength: 8)
            Menu {
                ForEach(TaskStatus.allCases) { value in
                    Button {
                        status = value
                    } label: {
                        Text(value.label)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(status.label)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(DesignPalette.primary)
                    Image("down-icon-d07e1302")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 12, height: 12)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(DesignPalette.sage, in: RoundedRectangle(cornerRadius: 10))
            }
            .accessibilityLabel("Status")
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var checklistEditor: some View {
        VStack(spacing: 8) {
            ForEach(Array(checklist.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 8) {
                    Button {
                        checklist[index].done.toggle()
                    } label: {
                        Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(item.done ? DesignPalette.primary : DesignPalette.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.done ? "Mark as not done" : "Mark as done")

                    AppTextField(
                        placeholder: "Checklist item",
                        text: Binding(
                            get: { checklist[index].text },
                            set: {
                                checklist[index] = ChecklistItem(
                                    text: $0,
                                    done: checklist[index].done
                                )
                            }
                        ),
                        font: .system(size: 13, weight: .medium, design: .rounded),
                        color: item.done ? DesignPalette.secondary : DesignPalette.ink
                    )
                    .strikethrough(item.done, color: DesignPalette.secondary)

                    Button(role: .destructive) {
                        checklist.remove(at: index)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete checklist item")
                }
            }

            HStack(spacing: 10) {
                Image("plus-icon-6d087aba")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                AppTextField(
                    placeholder: "Add a checklist item…",
                    text: $newChecklistItem,
                    font: .system(size: 12, weight: .semibold, design: .rounded),
                    color: DesignPalette.primary
                )
                    .submitLabel(.done)
                    .onSubmit(commitChecklistItem)
                Button {
                    commitChecklistItem()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(DesignPalette.primary)
                }
                .buttonStyle(.plain)
                .disabled(newChecklistItem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Add checklist item")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commitChecklistItem() {
        let trimmed = newChecklistItem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        checklist.append(ChecklistItem(text: trimmed))
        newChecklistItem = ""
    }

    private var detailsCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AppTextField(
                    placeholder: "Category",
                    text: $category,
                    font: .system(size: 13, weight: .medium, design: .rounded)
                )
                    .accessibilityIdentifier("categoryField")
                Image("down-icon-1")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 16)

            ForEach(categorySuggestions, id: \.self) { suggestion in
                Button {
                    category = suggestion
                } label: {
                    Text(suggestion)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(DesignPalette.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("categorySuggestion_\(suggestion)")
            }

            DividerRow()

            AppTextField(
                placeholder: "Notes",
                text: $notes,
                font: .system(size: 13, weight: .medium, design: .rounded),
                axis: .vertical
            )
                .lineLimit(2...6)
                .padding(.top, 12)
                .padding(.bottom, 24)

            DividerRow()

            checklistEditor
                .padding(.vertical, 4)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private var errorCard: some View {
        if let errorMessage {
            Text(errorMessage)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var saveCTA: some View {
        VStack(spacing: 10) {
            Button {
                Task { await save() }
            } label: {
                HStack(spacing: 8) {
                    if isSaving {
                        ProgressView()
                            .tint(DesignPalette.primary)
                    } else {
                        Image("plus-icon-6d087aba")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 18, height: 18)
                    }
                    Text(saveButtonTitle == "Add" ? "Add task" : saveButtonTitle)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(trimmedTitle.isEmpty || isSaving ? disabledText : .white)
                .background(
                    trimmedTitle.isEmpty || isSaving ? disabledCTA : DesignPalette.primary,
                    in: RoundedRectangle(cornerRadius: 14)
                )
            }
            .buttonStyle(.plain)
            .disabled(isSaving || trimmedTitle.isEmpty)
            .accessibilityLabel(saveButtonTitle)
            .accessibilityIdentifier("saveTaskButton")

            if trimmedTitle.isEmpty {
                Text("Give your task a title to get started.")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(DesignPalette.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 14) {
            Text("Less scrolling. More bamboo.")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(DesignPalette.secondary)
            Capsule()
                .fill(DesignPalette.ink)
                .frame(width: 116, height: 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    encouragementCard
                    titleCard
                    typePicker
                    timingCard
                    moreOptionsSection
                    detailsCard
                    errorCard
                    saveCTA
                    footer
                }
                .padding(.horizontal, DesignPalette.pagePadding)
                .padding(.top, 22)
                .padding(.bottom, 24)
            }
            .appBackdrop()
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
            .task {
                if case .edit = mode { moreOptions = true }
                if case .add = mode, scheduleService.preference == nil {
                    await scheduleService.loadPreferences()
                }
                applyDefaults()
            }
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .add: "New Task"
        case .edit: "Edit Task"
        }
    }

    private var saveButtonTitle: String {
        switch mode {
        case .add: "Add"
        case .edit: "Save"
        }
    }

    private func applyDefaults() {
        guard case .add = mode else { return }
        guard let preference = scheduleService.preference else { return }
        if !hasDuration {
            durationHours = preference.defaultDurationMinutes / 60
            durationMinutesPart = preference.defaultDurationMinutes % 60
        }
        if trimmedTitle.isEmpty {
            priority = TaskPriority(rawValue: preference.defaultPriority) ?? .medium
        }
    }

    private func save() async {
        guard !trimmedTitle.isEmpty else { return }
        guard !hasDuration || totalDurationMinutes >= 1 else {
            errorMessage = "Estimated duration must be at least 1 minute."
            return
        }
        guard !hasFixedEvent || fixedEnd > fixedStart else {
            errorMessage = "Fixed event end must be after its start."
            return
        }
        isSaving = true
        defer { isSaving = false }

        let deadlineValue = hasDeadline && !hasFixedEvent ? deadline : nil
        let startAtValue = hasFixedEvent ? fixedStart : nil
        let endAtValue = hasFixedEvent ? fixedEnd : nil
        let durationValue = hasDuration && !hasFixedEvent ? totalDurationMinutes : nil
        let categoryValue = category.isEmpty ? nil : category
        let descriptionValue = detail.isEmpty ? nil : detail
        let notesValue = notes.isEmpty ? nil : notes
        let checklistValue = checklist.isEmpty ? nil : checklist
        let repeatWeekdaysValue = hasRepeat ? selectedWeekdaysValue : nil
        let repeatEndsOnValue = repeatEndsOnValue

        do {
            switch mode {
            case .add:
                let created = try await taskService.createTask(
                    title: trimmedTitle,
                    description: descriptionValue,
                    deadline: deadlineValue,
                    startAt: startAtValue,
                    endAt: endAtValue,
                    priority: priority,
                    status: status,
                    estimatedDuration: durationValue,
                    category: categoryValue,
                    notes: notesValue,
                    repeatWeekdays: repeatWeekdaysValue,
                    beforeTaskIds: nil,
                    afterTaskIds: nil,
                    repeatEndsOn: repeatEndsOnValue,
                    checklist: checklistValue
                )
                onSaved?(created)
            case .edit(let task):
                var updated = task
                updated.title = trimmedTitle
                updated.description = descriptionValue
                updated.deadline = deadlineValue
                updated.startAt = startAtValue
                updated.endAt = endAtValue
                updated.priority = priority
                updated.status = status
                updated.estimatedDuration = durationValue
                updated.category = categoryValue
                updated.notes = notesValue
                updated.checklist = checklistValue
                updated.repeatWeekdays = repeatWeekdaysValue
                updated.repeatEndsOn = repeatEndsOnValue
                let saved = try await taskService.updateTask(updated)
                onSaved?(saved)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
