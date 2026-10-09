import SwiftUI

struct WeeklyScheduleView: View {
    @Environment(ScheduleService.self) private var scheduleService
    @Environment(CalendarService.self) private var calendarService
    @Environment(RecommendationService.self) private var recommendationService
    @Environment(TaskService.self) private var taskService
    @Environment(NotificationService.self) private var notificationService
    @Environment(FocusService.self) private var focusService
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("focusTimerStartedAt") private var focusTimerStartedAt: Double = 0

    private enum ScheduleViewMode: String, CaseIterable, Identifiable {
        case calendar
        case review

        var id: String { rawValue }

        var label: String {
            switch self {
            case .calendar: "Calendar"
            case .review: "Review"
            }
        }
    }

    private struct OccurrenceEditContext: Identifiable {
        let id = UUID()
        let task: TaskItem
        let date: Date
    }

    private var calendar: Calendar { Calendar.current }

    @State private var viewMode: ScheduleViewMode = .calendar
    @State private var selectedDate = Date()
    @State private var calendarMonth = Date()
    @State private var calendarExpanded = true
    @State private var showPreferences = false
    @State private var showSettings = false
    @State private var showProposal = false
    @State private var busyEvents: [CalendarEventItem] = []
    @State private var errorDismissed = false
    @State private var expandedSlots: Set<String> = []
    @State private var editingBlock: CalendarBlock?
    @State private var editingOccurrence: OccurrenceEditContext?
    @State private var reviewStore = ScheduleReviewStore()
    @State private var confirmedReviewKeys: Set<String> = []
    @State private var orderStore = RecommendationOrderStore()
    @State private var draggingId: String?
    @State private var dragStartCenter: CGFloat?
    @State private var rowCenters: [String: CGFloat] = [:]
    @State private var selectedTask: TaskItem?
    @AppStorage("didSeeReorderTip") private var didSeeReorderTip = false

    private var dayStart: Date {
        calendar.startOfDay(for: selectedDate)
    }

    private var dayEnd: Date {
        calendar.date(byAdding: .day, value: 1, to: dayStart) ?? selectedDate
    }

    private var monthStart: Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: calendarMonth)) ?? calendarMonth
    }

    private var monthEnd: Date {
        calendar.date(byAdding: .month, value: 1, to: monthStart) ?? calendarMonth
    }

    private var visibleStart: Date {
        switch viewMode {
        case .calendar: return monthStart
        case .review: return monthStart
        }
    }

    private var visibleEnd: Date {
        switch viewMode {
        case .calendar: return monthEnd
        case .review: return monthEnd
        }
    }

    private var monthCells: [Date?] {
        let firstWeekday = calendar.firstWeekday
        let weekday = calendar.component(.weekday, from: monthStart)
        let leadingBlanks = (weekday - firstWeekday + 7) % 7
        let days = calendar.range(of: .day, in: .month, for: monthStart) ?? 1..<2
        var cells: [Date?] = Array(repeating: nil, count: leadingBlanks)
        cells.append(contentsOf: days.compactMap {
            calendar.date(byAdding: .day, value: $0 - 1, to: monthStart)
        })
        while cells.count % 7 != 0 {
            cells.append(nil)
        }
        return cells
    }

    private var orderedWeekdaySymbols: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...]) + Array(symbols[..<first])
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    viewModePicker

                    if recommendationService.isLoading {
                        HStack {
                            Spacer()
                            ProgressView("Finding recommendations…")
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }

                    if let message = activeErrorMessage, !errorDismissed {
                        errorBanner(message)
                    }

                    if calendarService.permission == .denied {
                        permissionDeniedBanner
                    }

                    switch viewMode {
                    case .calendar:
                        monthGrid
                        dayContent
                        unscheduledSection
                    case .review:
                        reviewContent
                    }
                }
                .coordinateSpace(name: "schedule")
                .padding()
            }
            .refreshable {
                await loadData(force: true)
            }
            .navigationTitle("Schedule")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        Task { await generatePlan() }
                    } label: {
                        if scheduleService.isGenerating {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Generate plan", systemImage: "sparkles")
                        }
                    }
                    .disabled(scheduleService.isGenerating)

                    Button {
                        showPreferences = true
                    } label: {
                        Label("Preferences", systemImage: "gearshape")
                    }

                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }

                    Button {
                        Task { await loadData(force: true) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        selectedDate = Date()
                        calendarMonth = Date()
                        viewMode = .calendar
                    } label: {
                        Label("Today", systemImage: "sun.max")
                    }
                    Spacer()
                    NavigationLink {
                        CalendarSelectionView()
                    } label: {
                        Label("Calendars", systemImage: "calendar")
                    }
                }
            }
            .task(id: visibleStart) {
                await loadData()
            }
            .onChange(of: calendarService.permission) { _, newValue in
                if newValue == .granted {
                    Task { await loadData(force: true) }
                }
            }
            .onChange(of: taskService.dataVersion) { _, _ in
                Task { await loadData(force: true) }
            }
            .onChange(of: scheduleService.blocks) { _, _ in
                rescheduleNotifications()
            }
            .sheet(isPresented: $showPreferences) {
                PreferencesView()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showProposal) {
                ScheduleProposalView()
            }
            .sheet(item: $editingBlock) { block in
                BlockTimeEditorView(block: block)
            }
            .sheet(item: $editingOccurrence) { context in
                OccurrenceEditorView(task: context.task, date: context.date)
            }
            .sheet(item: $selectedTask) { task in
                NavigationStack {
                    TaskDetailView(task: task)
                }
            }
        }
    }

    private func generatePlan() async {
        errorDismissed = false
        let busyTimes = busyEvents
            .filter { !$0.isAllDay && !calendarService.isIgnored($0) }
            .map { BusyTimeRequest(start: $0.start, end: $0.end) }
        await scheduleService.generate(
            startDate: visibleStart,
            endDate: visibleEnd,
            busyTimes: busyTimes
        )
        showProposal = true
    }

    private var activeErrorMessage: String? {
        recommendationService.errorMessage ?? scheduleService.errorMessage
    }

    private var viewModePicker: some View {
        Picker("View", selection: $viewMode) {
            ForEach(ScheduleViewMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: .infinity)
    }

private var dayContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if calendar.isDateInToday(selectedDate) {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text("Now · \(context.date.formatted(date: .omitted, time: .shortened))")
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }
            daySection(selectedDate)
        }
    }

    private var monthGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        calendarExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: calendarExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                        Text(calendarExpanded
                            ? calendarMonth.formatted(.dateTime.month(.wide).year())
                            : "View calendar")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.primary)
                    .contentTransition(.opacity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(calendarExpanded ? "Collapse calendar" : "Expand calendar")

                Spacer()

                Button {
                    selectedDate = Date()
                    calendarMonth = Date()
                } label: {
                    Label("Today", systemImage: "sun.max")
                }
                .accessibilityLabel("Jump to today")

                if calendarExpanded {
                    Button {
                        stepMonth(-1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("Previous month")
                    Button {
                        stepMonth(1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .accessibilityLabel("Next month")
                }
            }
            .padding(.horizontal, 4)

            if calendarExpanded {
                HStack {
                    ForEach(Array(orderedWeekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                        Text(symbol)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 8) {
                    ForEach(Array(monthCells.enumerated()), id: \.offset) { _, day in
                        if let day {
                            monthCell(day)
                        } else {
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .frame(height: 40)
                        }
                    }
                }
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private func stepMonth(_ delta: Int) {
        calendarMonth = calendar.date(byAdding: .month, value: delta, to: calendarMonth) ?? calendarMonth
    }

    private func monthCell(_ day: Date) -> some View {
        let hasEvents = !events(for: day).isEmpty
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDate)
        let isToday = calendar.isDateInToday(day)

        return Button {
            selectedDate = day
        } label: {
            VStack(spacing: 4) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.subheadline)
                    .fontWeight(isToday ? .bold : .regular)
                Circle()
                    .fill(hasEvents ? Color.accentColor : Color.clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                isSelected ? Color.accentColor.opacity(0.2) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isToday ? Color.accentColor : Color.clear, lineWidth: isToday ? 1 : 0)
            )
        }
        .buttonStyle(.plain)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Text(message)
                .font(.footnote)
            Spacer()
            Button {
                errorDismissed = true
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var permissionDeniedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark")
            Text("Calendar access is off. Enable it in Settings to see your events.")
                .font(.footnote)
            Spacer()
        }
        .padding()
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Day section (calendar events + recommendations)

    private func daySection(_ day: Date) -> some View {
        let groups = groupExactOverlap(events(for: day))
        let isToday = calendar.isDateInToday(day)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(day, format: .dateTime.weekday(.abbreviated))
                    .font(.headline)
                Text(day, format: .dateTime.month().day())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if isToday {
                    Text("Today")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.2), in: Capsule())
                }
            }

            if groups.isEmpty {
                Text("No events")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { slotIndex, group in
                        if group.count == 1 {
                            eventRow(group[0])
                        } else {
                            eventSlot(group, day: day, slotIndex: slotIndex)
                        }
                    }
                }
            }

            recommendationsSection(day)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isToday ? Color.accentColor : Color(.separator), lineWidth: isToday ? 1.5 : 0.5)
        )
    }

    // MARK: - Recommendations

    private func recommendationsSection(_ day: Date) -> some View {
        let recommendation = recommendationService.recommendations(for: day)

        return Group {
            if let recommendation {
                VStack(alignment: .leading, spacing: 6) {
                    Divider()
                    HStack(spacing: 6) {
                        Image(systemName: "lightbulb.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                        Text("Recommended")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if calendar.isDateInToday(day) {
                            Text("\(formatMinutes(remainingFreeMinutesToday())) left today")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(formatMinutes(recommendation.availableMinutes)) free")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)

                    if !didSeeReorderTip && !recommendation.items.isEmpty {
                        Label("Long-press and drag a task to reorder", systemImage: "hand.draw")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            .onAppear {
                                didSeeReorderTip = true
                            }
                    }

                    if recommendation.items.isEmpty {
                        Text("Nothing recommended — no free time or no open tasks.")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(
                            orderStore.reorder(recommendation.items, id: \.id)
                        ) { item in
                            recommendedRow(item, for: day)
                                .opacity(draggingId == item.id ? 0.4 : 1)
                                .overlay {
                                    if draggingId == item.id {
                                        recommendedRow(item, for: day)
                                            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                                .background(
                                    GeometryReader { proxy in
                                        Color.clear
                                            .preference(
                                                key: RowCenterKey.self,
                                                value: [item.id: proxy.frame(in: .named("schedule")).midY]
                                            )
                                    }
                                )
                                .draggableReorder(
                                    id: item.id,
                                    draggingId: $draggingId,
                                    dragStartCenter: $dragStartCenter,
                                    rowCenters: $rowCenters,
                                    onReorder: { orderStore.move($0, before: $1) }
                                )
                        }
                        .onPreferenceChange(RowCenterKey.self) { changes in
                            for change in changes { rowCenters[change.key] = change.value }
                        }
                    }
                }
            } else if !recommendationService.isLoading,
                      let message = recommendationService.errorMessage {
                VStack(alignment: .leading, spacing: 4) {
                    Divider()
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    private func recommendedRow(_ item: RecommendedPart, for day: Date) -> some View {
        let isToday = calendar.isDateInToday(day)
        let remainingToday = remainingFreeMinutesToday()

        return HStack(spacing: 6) {
            Button {
                startRecommendedFocus(item)
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Start focus on \(displayTitle(item))")

            Button {
                if let task = taskService.tasks.first(where: { $0.id == item.taskId }) {
                    selectedTask = task
                }
            } label: {
                HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(priorityColor(item.priority))
                    .frame(width: 4, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle(item))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    if let category = item.category, !category.isEmpty {
                        Text(category)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    if let block = item.timeBlockText {
                        Label(block, systemImage: "clock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if !item.reason.isEmpty {
                        Text(item.reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if item.isOverdue {
                        Label("Overdue", systemImage: "exclamationmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                Spacer()
                if isToday && remainingToday < item.minutes {
                    Label(
                        "Needs \(formatMinutes(item.minutes - remainingToday)) more free time",
                        systemImage: "clock"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Text(formatMinutes(item.minutes))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var unscheduledSection: some View {
        let parts = recommendationService.unscheduled
        return Group {
            if !parts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .foregroundStyle(.orange)
                        Text("Doesn't fit this window")
                            .font(.subheadline.weight(.semibold))
                    }
                    Text("These tasks genuinely can't be fit before their deadlines within this window. Extend work hours in Preferences, free up calendar time, or break them into smaller pieces.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(parts) { part in
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(priorityColor(part.priority))
                                .frame(width: 4, height: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(displayTitle(taskTitle: part.taskTitle, partTitle: part.partTitle))
                                    .font(.subheadline)
                                    .lineLimit(2)
                                if let category = part.category, !category.isEmpty {
                                    Text(category)
                                        .font(.caption2)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                }
                            }
                            Spacer()
                            Text(formatMinutes(part.minutes))
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(
                            Color.orange.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(.separator), lineWidth: 0.5)
                )
            }
        }
    }

    // MARK: - Review fixed events

    private var scheduledTasks: [TaskItem] {
        taskService.tasks
            .filter {
                $0.startAt != nil && $0.status != .completed && !$0.isArchived
            }
            .sorted { ($0.startAt ?? .distantPast) < ($1.startAt ?? .distantPast) }
    }

    private var pendingReviews: [TaskItem] {
        scheduledTasks.filter { !confirmedReviewKeys.contains(reviewStore.key(for: $0)) }
    }

    private var reviewContent: some View {
        Group {
            if pendingReviews.isEmpty {
                ContentUnavailableView(
                    "All caught up",
                    systemImage: "checkmark.seal.fill",
                    description: Text(
                        "Fixed-event tasks you schedule appear here so you can confirm their times. Confirming just marks them as reviewed here on your device."
                    )
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 48)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(pendingReviews.count) event\(pendingReviews.count == 1 ? "" : "s") to confirm")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    ForEach(orderStore.reorder(pendingReviews, id: \.id.uuidString)) { task in
                        reviewRow(task)
                            .opacity(draggingId == task.id.uuidString ? 0.4 : 1)
                            .overlay {
                                if draggingId == task.id.uuidString {
                                    reviewRow(task)
                                        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12))
                                }
                            }
                            .background(
                                GeometryReader { proxy in
                                    Color.clear
                                        .preference(
                                            key: RowCenterKey.self,
                                            value: [task.id.uuidString: proxy.frame(in: .named("schedule")).midY]
                                        )
                                }
                            )
                            .draggableReorder(
                                id: task.id.uuidString,
                                draggingId: $draggingId,
                                dragStartCenter: $dragStartCenter,
                                rowCenters: $rowCenters,
                                onReorder: { orderStore.move($0, before: $1) }
                            )
                    }
                    .onPreferenceChange(RowCenterKey.self) { changes in
                        for change in changes { rowCenters[change.key] = change.value }
                    }
                }
            }
        }
        .task(id: viewMode) {
            if viewMode == .review {
                await taskService.loadTasks()
                confirmedReviewKeys = Set(
                    scheduledTasks
                        .filter { reviewStore.isConfirmed($0) }
                        .map { reviewStore.key(for: $0) }
                )
            }
        }
    }

    private func reviewRow(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(priorityColor(task.priority))
                    .frame(width: 4, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    if let start = task.startAt, let end = task.endAt {
                        Text("\(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let start = task.startAt {
                        Text(start.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    confirmReview(task)
                } label: {
                    Label("Looks good", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            HStack(spacing: 8) {
                if let duration = reviewDuration(task) {
                    Label(formatMinutes(duration), systemImage: "clock")
                }
                if let deadline = task.deadline {
                    Label(deadline.formatted(date: .abbreviated, time: .omitted), systemImage: "flag")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }

    private func reviewDuration(_ task: TaskItem) -> Int? {
        if let start = task.startAt, let end = task.endAt {
            let minutes = Int(end.timeIntervalSince(start) / 60)
            return minutes > 0 ? minutes : nil
        }
        return task.estimatedDuration
    }

    private func confirmReview(_ task: TaskItem) {
        reviewStore.confirm(task)
        confirmedReviewKeys.insert(reviewStore.key(for: task))
    }

    private func displayTitle(_ item: RecommendedPart) -> String {
        displayTitle(taskTitle: item.taskTitle, partTitle: item.partTitle)
    }

    private func displayTitle(taskTitle: String, partTitle: String?) -> String {
        guard let partTitle else { return taskTitle }
        if partTitle == taskTitle || partTitle.hasPrefix(taskTitle) {
            return partTitle
        }
        return "\(taskTitle) — \(partTitle)"
    }

    private func priorityColor(_ priority: TaskPriority) -> Color {
        switch priority {
        case .high: .red
        case .medium: .orange
        case .low: .gray
        }
    }

    private func formatMinutes(_ minutes: Int) -> String {
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        let mins = minutes % 60
        return mins == 0 ? "\(hours)h" : "\(hours)h \(mins)m"
    }

    // MARK: - Remaining free time (today)

    /// End of today's working window (honoring work-hours preference).
    private func workEndToday() -> Date? {
        let cal = Calendar.current
        let now = Date()
        let hour = scheduleService.preference?.workHoursEnd ?? 17
        let endHour = min(max(Int(hour), 0), 23)
        var components = cal.dateComponents([.year, .month, .day], from: now)
        components.hour = endHour
        components.minute = 0
        let end = cal.date(from: components) ?? now
        return end > now ? end : nil
    }

    /// Busy intervals that haven't ended by now today, within the working window.
    /// Combines external calendar events, app schedule blocks, and fixed tasks.
    private func busyIntervalsToday() -> [(Date, Date)] {
        let now = Date()
        guard let workEnd = workEndToday() else { return [] }

        var intervals: [(Date, Date)] = []

        for event in busyEvents where !calendarService.isIgnored(event) && !event.isAllDay {
            let start = max(event.start, now)
            let end = min(event.end, workEnd)
            if end > start { intervals.append((start, end)) }
        }

        for block in scheduleService.blocks {
            let start = max(block.startAt, now)
            let end = min(block.endAt, workEnd)
            if end > start { intervals.append((start, end)) }
        }

        for task in taskService.tasks
        where task.startAt != nil && task.endAt != nil
            && task.status != .completed && !task.isArchived {
            let start = max(task.startAt!, now)
            let end = min(task.endAt!, workEnd)
            if end > start { intervals.append((start, end)) }
        }

        intervals.sort { $0.0 < $1.0 }
        var merged: [(Date, Date)] = []
        for interval in intervals {
            if let last = merged.last, interval.0 <= last.1 {
                merged[merged.count - 1] = (last.0, max(last.1, interval.1))
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    /// Free minutes remaining between now and the end of the work day, minus
    /// calendar events that haven't ended yet. Used to decide which recommended
    /// tasks can still be completed today.
    private func remainingFreeMinutesToday() -> Int {
        guard let workEnd = workEndToday() else { return 0 }
        var free = Int(workEnd.timeIntervalSince(Date()) / 60)
        for interval in busyIntervalsToday() {
            free -= Int(interval.1.timeIntervalSince(interval.0) / 60)
        }
        return max(free, 0)
    }

    // MARK: - Events

    private func events(for day: Date) -> [CalendarEventItem] {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? day
        let external = busyEvents.filter { $0.start < dayEnd && $0.end > dayStart }
        return (external + appEvents(for: day)).sorted { $0.start < $1.start }
    }

    /// Events that come from the app itself: scheduled blocks plus fixed and
    /// repeating tasks expanded into one event per scheduled day.
    private func appEvents(for day: Date) -> [CalendarEventItem] {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? day

        let dayBlocks = scheduleService.blocks.filter {
            $0.startAt < dayEnd && $0.endAt > dayStart
        }
        let blockItems = dayBlocks.map { block in
            CalendarEventItem(
                id: "app-block-\(block.id.uuidString)",
                title: block.title,
                start: block.startAt,
                end: block.endAt,
                isAllDay: false
            )
        }
        let blockTaskIds = Set(dayBlocks.map(\.taskId))

        let taskItems = taskService.tasks.flatMap { task -> [CalendarEventItem] in
            guard
                !task.isArchived,
                task.status != .completed,
                let start = task.startAt,
                task.endAt != nil
            else { return [] }
            if blockTaskIds.contains(task.id) { return [] }
            let weekdays = task.repeatWeekdays ?? []
            if weekdays.isEmpty {
                guard let end = task.endAt, start < dayEnd, end > dayStart else { return [] }
                return [CalendarEventItem(
                    id: "app-task-\(task.id.uuidString)-\(Int(start.timeIntervalSince1970))",
                    title: task.title, start: start, end: end, isAllDay: false
                )]
            }
            return CalendarEventItem.repeatingEvents(for: task, on: day)
        }

        return blockItems + taskItems
    }

    private func isAppEvent(_ event: CalendarEventItem) -> Bool {
        event.id.hasPrefix("app-block-") || event.id.hasPrefix("app-task-")
    }

    private func groupExactOverlap(_ items: [CalendarEventItem]) -> [[CalendarEventItem]] {
        let sorted = items.sorted { $0.start < $1.start }
        var groups: [[CalendarEventItem]] = []
        for item in sorted {
            var merged = false
            for i in groups.indices {
                if groups[i].contains(where: { $0.start == item.start && $0.end == item.end }) {
                    groups[i].append(item)
                    merged = true
                    break
                }
            }
            if !merged {
                groups.append([item])
            }
        }
        return groups
    }

    private func slotKey(_ day: Date, slotIndex: Int) -> String {
        "\(Int(day.timeIntervalSince1970))_\(slotIndex)"
    }

    private func eventSlot(_ items: [CalendarEventItem], day: Date, slotIndex: Int) -> some View {
        let key = slotKey(day, slotIndex: slotIndex)
        let isExpanded = expandedSlots.contains(key)

        return VStack(spacing: 0) {
            if isExpanded {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    if idx > 0 {
                        Divider().padding(.horizontal, 8)
                    }
                    eventRow(item)
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        _ = expandedSlots.remove(key)
                    }
                } label: {
                    Label("Collapse", systemImage: "chevron.up")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            } else {
                let first = items[0]
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        _ = expandedSlots.insert(key)
                    }
                } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.gray)
                            .frame(width: 4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(first.title)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text("\(first.start.formatted(date: .omitted, time: .shortened)) – \(first.end.formatted(date: .omitted, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(items.count - 1) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)
                    .background(
                        Color(UIColor.quaternarySystemFill),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func eventRow(_ event: CalendarEventItem) -> some View {
        let isAppBlock = event.id.hasPrefix("app-block-")
        let isApp = isAppEvent(event)
        let ignored = isApp ? false : calendarService.isIgnored(event)
        let completed = occurrenceCompleted(event)

        let content = eventRowContent(
            event,
            ignored: ignored,
            completed: completed,
            isApp: isApp,
            isAppBlock: isAppBlock
        )

        if isApp && !isAppBlock {
            if let task = task(for: event) {
                return AnyView(
                    Button {
                        editingOccurrence = OccurrenceEditContext(
                            task: task,
                            date: event.occurrenceDate ?? calendar.startOfDay(for: event.start)
                        )
                    } label: {
                        content
                    }
                    .buttonStyle(.plain)
                )
            }
            return AnyView(content)
        } else {
            return AnyView(
                Button {
                    if let block = block(for: event) {
                        editingBlock = block
                    } else if !isApp {
                        calendarService.toggleIgnored(event)
                    }
                } label: {
                    content
                }
                .buttonStyle(.plain)
            )
        }
    }

    private func block(for event: CalendarEventItem) -> CalendarBlock? {
        guard event.id.hasPrefix("app-block-") else { return nil }
        let uuidString = String(event.id.dropFirst("app-block-".count))
        guard let id = UUID(uuidString: uuidString) else { return nil }
        return scheduleService.blocks.first { $0.id == id }
    }

    private func task(for event: CalendarEventItem) -> TaskItem? {
        guard event.id.hasPrefix("app-task-") else { return nil }
        let remainder = event.id.dropFirst("app-task-".count)
        guard let separator = remainder.range(of: "-", options: .backwards) else {
            return nil
        }
        let uuidString = String(remainder[remainder.startIndex..<separator.lowerBound])
        guard let id = UUID(uuidString: uuidString) else { return nil }
        return taskService.tasks.first { $0.id == id }
    }

    private func occurrenceCompleted(_ event: CalendarEventItem) -> Bool {
        guard let task = task(for: event) else { return false }
        guard let override = task.repeatOverrides?[OccurrenceDateKey.key(for: event.occurrenceDate ?? event.start)] else {
            return false
        }
        return override.completed == true
    }

    private func eventRowContent(
        _ event: CalendarEventItem,
        ignored: Bool,
        completed: Bool,
        isApp: Bool,
        isAppBlock: Bool
    ) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(completed ? Color.green : (isApp ? Color.accentColor : .gray))
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .strikethrough(ignored || completed)
                Text("\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if ignored {
                Image(systemName: "nosign")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isAppBlock {
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isApp {
                if completed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "checklist")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Ignore")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(
            (ignored ? Color.secondary.opacity(0.12) : Color(UIColor.quaternarySystemFill)),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    // MARK: - Data loading

    /// End of the recommended-plan window: at least ~a month out so upcoming
    /// days share one coherent, spread-out plan instead of replanning a fresh
    /// single-day window every time the user toggles days (which repeated the
    /// same urgent tasks and dumped the rest in "doesn't fit"). Tasks with
    /// deadlines beyond the window are still placed within it (before their
    /// deadline), so we keep the horizon bounded.
    private var planningEnd: Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let horizon = calendar.date(byAdding: .day, value: 30, to: today) ?? today
        return max(visibleEnd, horizon)
    }

    private func loadData(force: Bool = false) async {
        errorDismissed = false
        await scheduleService.loadPreferences()

        await scheduleService.loadBlocks()
        await taskService.loadTasks()

        if await calendarService.requestPermission() == .granted {
            busyEvents = calendarService.fetchEvents(from: visibleStart, to: visibleEnd)
        } else {
            busyEvents = []
        }

        // Keep recommendations static while a focus session is running, but
        // always fetch them when the visible day has none so the section is
        // never left permanently empty (e.g. after a session outlives a launch).
        let focusTimerRunning = focusTimerStartedAt > 0
        let hasVisibleRecommendation =
            recommendationService.recommendations(for: visibleStart) != nil
        if !focusTimerRunning || !hasVisibleRecommendation {
            await recommendationService.load(
                from: visibleStart,
                to: planningEnd,
                excluding: Set(busyEvents.filter { calendarService.isIgnored($0) }.map(\.id)),
                force: force
            )
        }

        rescheduleNotifications()
    }

    private func rescheduleNotifications() {
        let workStart = scheduleService.preference?.workHoursStart ?? 9
        let workEnd = scheduleService.preference?.workHoursEnd ?? 17
        notificationService.scheduleAll(
            tasks: taskService.tasks,
            events: [],
            blocks: scheduleService.blocks,
            workHoursStart: workStart,
            workHoursEnd: workEnd,
            hasOngoingFocus: focusTimerStartedAt > 0,
            morningMessage: focusService.morningMessage?.message
        )
    }

    private func startRecommendedFocus(_ item: RecommendedPart) {
        let category = taskService.tasks.first(where: { $0.id == item.taskId })?.category
        FocusTimerStarter.startFocus(
            taskID: item.taskId,
            title: displayTitle(item),
            category: category
        )
    }
}

#Preview {
    WeeklyScheduleView()
        .environment(ScheduleService())
        .environment(CalendarService())
        .environment(TaskService())
        .environment(RecommendationService())
}

struct RowCenterKey: PreferenceKey {
    typealias Value = [String: CGFloat]
    static var defaultValue: [String: CGFloat] { [:] }
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    /// Long-press to "pick up" a row, then drag up/down to reorder. No visible
    /// handle or drag affordance is shown.
    func draggableReorder(
        id: String,
        draggingId: Binding<String?>,
        dragStartCenter: Binding<CGFloat?>,
        rowCenters: Binding<[String: CGFloat]>,
        onReorder: @escaping (String, String) -> Void
    ) -> some View {
        self.gesture(
            LongPressGesture(minimumDuration: 0.25)
                .onEnded { _ in
                    draggingId.wrappedValue = id
                    dragStartCenter.wrappedValue = rowCenters.wrappedValue[id]
                }
                .sequenced(
                    before: DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            guard draggingId.wrappedValue == id,
                                  let base = dragStartCenter.wrappedValue
                            else { return }
                            let currentY = base + value.translation.height
                            if let target = rowCenters.wrappedValue
                                .min(by: { abs($0.value - currentY) < abs($1.value - currentY) })?
                                .key,
                               target != id
                            {
                                onReorder(id, target)
                            }
                        }
                        .onEnded { _ in
                            draggingId.wrappedValue = nil
                            dragStartCenter.wrappedValue = nil
                        }
                )
        )
    }
}
