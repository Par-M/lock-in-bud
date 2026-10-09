import SwiftUI

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
    @State private var beforeTaskIDs: Set<UUID>
    @State private var afterTaskIDs: Set<UUID>
    @State private var isOrderingExpanded: Bool
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
            _beforeTaskIDs = State(initialValue: [])
            _afterTaskIDs = State(initialValue: [])
            _isOrderingExpanded = State(initialValue: false)
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
            _beforeTaskIDs = State(initialValue: Set(task.beforeTaskIds ?? []))
            _afterTaskIDs = State(initialValue: Set(task.afterTaskIds ?? []))
            _isOrderingExpanded = State(initialValue: true)
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

    private var selfTaskID: UUID? {
        if case .edit(let task) = mode {
            return task.id
        }
        return nil
    }

    private var candidateTasks: [TaskItem] {
        taskService.tasks.filter {
            $0.id != selfTaskID && $0.status != .completed
        }
    }

    private var categorySuggestions: [String] {
        guard !category.isEmpty else { return [] }
        return Array(
            categoryStore.categories(from: taskService.tasks)
                .filter { $0.localizedCaseInsensitiveContains(category) && $0 != category }
                .prefix(5)
        )
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
                .frame(minWidth: 44, minHeight: 44)
                .background(
                    isSelected ? Color.accentColor : Color(.secondarySystemBackground),
                    in: Circle()
                )
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.weekdayFullNames[day])
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityIdentifier("repeatDay\(day)")
    }

    @ViewBuilder
    private func orderingList(title: String, selection: Binding<Set<UUID>>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(orderedCandidates) { task in
                let isSelected = selection.wrappedValue.contains(task.id)
                Button {
                    if isSelected {
                        selection.wrappedValue.remove(task.id)
                    } else {
                        selection.wrappedValue.insert(task.id)
                    }
                } label: {
                    HStack {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        Text(task.title)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ordering_\(title)_\(task.id)")
            }
        }
    }

    private var orderedCandidates: [TaskItem] {
        candidateTasks.sorted {
            let lhsDeadline = $0.deadline ?? $0.createdAt
            let rhsDeadline = $1.deadline ?? $1.createdAt
            return lhsDeadline < rhsDeadline
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .accessibilityIdentifier("taskTitleField")

                }

                Section {
                    Picker("Type", selection: $hasFixedEvent) { Text("Task").tag(false); Text("Event").tag(true) }.pickerStyle(.segmented)
                    if hasFixedEvent {
                        DatePicker(
                            "Date",
                            selection: fixedStartBinding,
                            displayedComponents: .date
                        )
                        DatePicker(
                            "Start",
                            selection: fixedStartBinding,
                            displayedComponents: .hourAndMinute
                        )
                        .datePickerStyle(.compact)
                        DatePicker(
                            "End",
                            selection: $fixedEnd,
                            in: fixedStart.addingTimeInterval(60)...,
                            displayedComponents: .hourAndMinute
                        )
                        .datePickerStyle(.compact)
                    }

                    if !hasFixedEvent {
                        Toggle("Deadline", isOn: $hasDeadline)
                        if hasDeadline {
                            DatePicker(
                                "Date",
                                selection: $deadline,
                                displayedComponents: .date
                            )
                            DatePicker(
                                "Time",
                                selection: $deadline,
                                displayedComponents: .hourAndMinute
                            )
                            .datePickerStyle(.compact)
                        }

                        Toggle("Estimated Duration", isOn: $hasDuration)
                        if hasDuration {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Hours")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    TextField("0", value: $durationHours, format: .number)
                                        .keyboardType(.numberPad)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 64)
                                }
                                Text("h")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Minutes")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    TextField("0", value: $durationMinutesPart, format: .number)
                                        .keyboardType(.numberPad)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 64)
                                }
                                Text("m")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(totalDurationLabel)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                }
                DisclosureGroup("More options", isExpanded: $moreOptions) {
                    Picker("Priority", selection: $priority) { ForEach(TaskPriority.allCases) { value in Text(value.label).tag(value) } }
                    TextField("Description", text: $detail, axis: .vertical).lineLimit(2...5)
                    Toggle("Repeats", isOn: $hasRepeat)
                    if hasRepeat {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 8) {
                            ForEach(0..<7, id: \.self) { day in
                                repeatDayButton(day)
                            }
                        }
                        .frame(maxWidth: .infinity)

                        Toggle("End Repeat", isOn: $hasRepeatEnd)
                        if hasRepeatEnd {
                            DatePicker(
                                "Repeat Until",
                                selection: $repeatEndDate,
                                in: Date()...,
                                displayedComponents: .date
                            )
                        }
                    }
                if !candidateTasks.isEmpty {
                    Section("Ordering", isExpanded: $isOrderingExpanded) {
                        VStack(alignment: .leading, spacing: 12) {
                            orderingList(title: "Do before", selection: $beforeTaskIDs)
                            orderingList(title: "Do after", selection: $afterTaskIDs)
                        }
                    }
                }

                if case .edit = mode {
                Section {
                    Picker("Status", selection: $status) {
                        ForEach(TaskStatus.allCases) { status in
                            Text(status.label).tag(status)
                        }
                    }
                }

                }
                Section {
                    VStack(alignment: .leading, spacing: 0) {
                        TextField("Category", text: $category)
                            .accessibilityIdentifier("categoryField")
                        ForEach(categorySuggestions, id: \.self) { suggestion in
                            Button {
                                category = suggestion
                            } label: {
                                Text(suggestion)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 4)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("categorySuggestion_\(suggestion)")
                        }
                    }
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...6)
                    TaskChecklistEditor(items: $checklist, onSave: {})
                        .padding(.vertical, 4)
                }

                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if case .edit = mode { moreOptions = true }
                if case .add = mode, scheduleService.preference == nil {
                    await scheduleService.loadPreferences()
                }
                applyDefaults()
            }
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
                    .disabled(isSaving || trimmedTitle.isEmpty)
                    .accessibilityIdentifier("saveTaskButton")
                }
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
        let beforeTaskIdsValue = beforeTaskIDs.isEmpty ? nil : Array(beforeTaskIDs)
        let afterTaskIdsValue = afterTaskIDs.isEmpty ? nil : Array(afterTaskIDs)

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
                    beforeTaskIds: beforeTaskIdsValue,
                    afterTaskIds: afterTaskIdsValue,
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
                updated.beforeTaskIds = beforeTaskIdsValue
                updated.afterTaskIds = afterTaskIdsValue
                let saved = try await taskService.updateTask(updated)
                onSaved?(saved)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
