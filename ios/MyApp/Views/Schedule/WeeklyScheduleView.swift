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
    @State private var showAddTask = false
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
                VStack(alignment: .leading, spacing: 20) {
                    scheduleHeader

                    encouragementCard

                    if recommendationService.isLoading {
                        HStack {
                            Spacer()
                            ProgressView("Finding recommendations…")
                            Spacer()
                        }
                        .font(DesignPalette.body(12))
                        .foregroundStyle(DesignPalette.secondary)
                        .padding(.vertical, 4)
                    }

                    if let message = activeErrorMessage, !errorDismissed {
                        errorBanner(message)
                    }

                    if calendarService.permission == .denied {
                        permissionDeniedBanner
                    }

                    viewModePicker

                    switch viewMode {
                    case .calendar:
                        monthGrid
                        dayContent
                        recommendationsSection(selectedDate)
                        unscheduledSection
                    case .review:
                        reviewContent
                    }
                }
                .padding(.horizontal, DesignPalette.pagePadding)
                .padding(.vertical, 16)
                .coordinateSpace(name: "schedule")
            }
            .appBackdrop()
            .refreshable {
                await loadData(force: true)
            }
            .navigationTitle("Schedule")
            .navigationBarTitleDisplayMode(.inline)
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

                    Menu {
                        Button {
                            showPreferences = true
                        } label: {
                            Label("Scheduling preferences", systemImage: "slider.horizontal.3")
                        }
                        Button {
                            showSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        Divider()
                        Button {
                            Task { await loadData(force: true) }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
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
            .sheet(isPresented: $showAddTask) {
                TaskFormView(mode: .add)
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

    private var scheduleSegmentTrack: Color {
        Color(.sRGB, red: 228.0 / 255.0, green: 231.0 / 255.0, blue: 220.0 / 255.0)
    }

    private var dayPlanCount: Int {
        groupExactOverlap(events(for: selectedDate)).count
    }

    private var scheduleHeader: some View {
        AppHeader(eyebrow: "Schedule", title: "Big plans.\nPanda-sized steps.") {
            Button {
                showSettings = true
            } label: {
                Image("settings-icon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .foregroundStyle(DesignPalette.primary)
                    .frame(width: 44, height: 44)
                    .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
    }

    private var encouragementCard: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Less chaos. More bamboo.")
                    .font(DesignPalette.body(21).weight(.bold))
                    .foregroundStyle(DesignPalette.ink)
                    .minimumScaleFactor(0.8)

                Text("One thing at a time. Snacks later.")
                    .font(DesignPalette.body(11))
                    .foregroundStyle(DesignPalette.secondary)

                Text("\(dayPlanCount) thing\(dayPlanCount == 1 ? "" : "s") in your day")
                    .font(DesignPalette.body(10).weight(.bold))
                    .foregroundStyle(DesignPalette.primary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(DesignPalette.card, in: Capsule())
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            schedulePanda
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignPalette.sage, in: RoundedRectangle(cornerRadius: 22))
    }

    /// Schedule frame panda, assembled from its own seven exported layers.
    private var schedulePanda: some View {
        ZStack(alignment: .topLeading) {
            Image("body")
                .resizable().scaledToFit()
                .frame(width: 52, height: 42)
                .offset(x: 20.7, y: 41.1)
            Image("feet-8609182e")
                .resizable().scaledToFit()
                .frame(width: 58.6, height: 15.2)
                .offset(x: 16.1, y: 68.4)
            Image("ears-fe715ffd")
                .resizable().scaledToFit()
                .frame(width: 51.7, height: 14)
                .offset(x: 20.6, y: 8.6)
            Image("head-f1986076")
                .resizable().scaledToFit()
                .frame(width: 51.1, height: 41.9)
                .offset(x: 20.3, y: 11.2)
            Image("thumbs-up-ac6f73fb")
                .resizable().scaledToFit()
                .frame(width: 21.5, height: 25.1)
                .offset(x: 8, y: 37.5)
            Image("bamboo-b836da48")
                .resizable().scaledToFit()
                .frame(width: 19.4, height: 38.5)
                .offset(x: 64.7, y: 36)
            Image("holding-paw")
                .resizable().scaledToFit()
                .frame(width: 15.1, height: 13.5)
                .offset(x: 62.4, y: 51.3)
        }
        .frame(width: 92, height: 92)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Panda giving a thumbs up")
    }

    private var viewModePicker: some View {
        HStack(spacing: 4) {
            ForEach(ScheduleViewMode.allCases) { mode in
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        viewMode = mode
                    }
                } label: {
                    Text(mode.label)
                        .font(DesignPalette.body(12).weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(viewMode == mode ? DesignPalette.primary : DesignPalette.secondary)
                .background(
                    viewMode == mode ? DesignPalette.card : Color.clear,
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .accessibilityLabel("\(mode.label) view")
                .accessibilityAddTraits(viewMode == mode ? AccessibilityTraits.isSelected : [])
            }
        }
        .padding(4)
        .background(scheduleSegmentTrack, in: RoundedRectangle(cornerRadius: 12))
    }

    private var dayContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(selectedDate, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(DesignPalette.body(17).weight(.bold))
                    .foregroundStyle(DesignPalette.ink)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 8)

                if calendar.isDateInToday(selectedDate) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text("Now · \(context.date.formatted(date: .omitted, time: .shortened))")
                    }
                    .font(DesignPalette.body(10))
                    .foregroundStyle(DesignPalette.secondary)
                }
            }

            daySection(selectedDate)
        }
    }

    private var baseWeekStart: Date {
        calendar.dateInterval(of: .weekOfYear, for: Date())?.start
            ?? calendar.startOfDay(for: Date())
    }

    private func weekStart(at offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset * 7, to: baseWeekStart) ?? baseWeekStart
    }

    private func weekDays(at offset: Int) -> [Date] {
        let start = weekStart(at: offset)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private func weekOffset(for date: Date) -> Int {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start
            ?? calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: baseWeekStart, to: start).day ?? 0
        return days / 7
    }

    private var weekOffsets: [Int] {
        let center = weekOffset(for: selectedDate)
        return Array((center - 8)...(center + 8))
    }

    private var pagedWeekSelection: Binding<Int?> {
        Binding(
            get: { self.weekOffset(for: self.selectedDate) },
            set: { newValue in
                guard let newValue else { return }
                let delta = newValue - self.weekOffset(for: self.selectedDate)
                guard delta != 0 else { return }
                guard let date = self.calendar.date(
                    byAdding: .day,
                    value: delta * 7,
                    to: self.selectedDate
                ) else { return }
                self.selectedDate = date
                self.calendarMonth = date
            }
        )
    }

    private var monthGrid: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        calendarExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(calendarExpanded
                            ? calendarMonth.formatted(.dateTime.month(.wide).year())
                            : "View calendar")
                            .font(DesignPalette.body(15).weight(.bold))
                        Image("down-icon")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 15, height: 15)
                            .rotationEffect(.degrees(calendarExpanded ? 180 : 0))
                    }
                    .foregroundStyle(DesignPalette.ink)
                    .contentTransition(.opacity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(calendarExpanded ? "Collapse calendar" : "Expand calendar")

                Spacer(minLength: 4)

                Button {
                    selectedDate = Date()
                    calendarMonth = Date()
                } label: {
                    Text("Today")
                        .font(DesignPalette.body(10).weight(.bold))
                        .foregroundStyle(DesignPalette.ink)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(DesignPalette.cream, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Jump to today")

                calendarArrow(image: "left-icon", label: "Previous month") {
                    stepMonth(-1)
                }
                calendarArrow(image: "right-icon", label: "Next month") {
                    stepMonth(1)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(weekOffsets, id: \.self) { offset in
                        HStack(spacing: 5) {
                            ForEach(weekDays(at: offset), id: \.self) { day in
                                weekCell(day)
                            }
                        }
                        .containerRelativeFrame(.horizontal)
                        .padding(.horizontal, 2)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: pagedWeekSelection)
            .frame(height: 76)

            if calendarExpanded {
                HStack(spacing: 0) {
                    ForEach(Array(orderedWeekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                        Text(symbol)
                            .font(DesignPalette.body(10).weight(.semibold))
                            .foregroundStyle(DesignPalette.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                    ForEach(Array(monthCells.enumerated()), id: \.offset) { _, day in
                        if let day {
                            monthCell(day)
                        } else {
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private func calendarArrow(image: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .foregroundStyle(DesignPalette.primary)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func weekCell(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDate)
        let weekdayIndex = calendar.component(.weekday, from: day) - 1
        let veryShortSymbols = calendar.veryShortWeekdaySymbols
        let symbol = veryShortSymbols[max(0, min(weekdayIndex, veryShortSymbols.count - 1))]
        let hasEvents = !events(for: day).isEmpty
        let dateLabel = day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())

        return Button {
            selectedDate = day
            calendarMonth = day
        } label: {
            VStack(spacing: 6) {
                Text(symbol)
                    .font(DesignPalette.body(10).weight(.semibold))
                Text("\(calendar.component(.day, from: day))")
                    .font(DesignPalette.body(16).weight(.bold))
                if hasEvents {
                    Image(isSelected ? "scheduled-activity-1" : "scheduled-activity")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 4, height: 4)
                } else {
                    Color.clear.frame(width: 4, height: 4)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(isSelected ? Color.white : DesignPalette.ink)
            .background(isSelected ? DesignPalette.primary : DesignPalette.card, in: RoundedRectangle(cornerRadius: 13))
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .stroke(isSelected ? Color.clear : DesignPalette.background, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hasEvents ? "\(dateLabel), scheduled activity" : dateLabel)
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
            calendarMonth = day
        } label: {
            VStack(spacing: 4) {
                Text("\(calendar.component(.day, from: day))")
                    .font(DesignPalette.body(16).weight(isToday ? .bold : .semibold))
                if hasEvents {
                    Image(isSelected ? "scheduled-activity-1" : "scheduled-activity")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 4, height: 4)
                } else {
                    Color.clear.frame(width: 4, height: 4)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .foregroundStyle(isSelected ? Color.white : DesignPalette.ink)
            .background(isSelected ? DesignPalette.primary : DesignPalette.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isToday && !isSelected ? DesignPalette.primary : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Text(message)
                .font(DesignPalette.body(12))
                .foregroundStyle(DesignPalette.ink)
            Spacer()
            Button {
                errorDismissed = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(DesignPalette.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignPalette.cream, in: RoundedRectangle(cornerRadius: 15))
    }

    private var permissionDeniedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark")
                .foregroundStyle(DesignPalette.primary)
            Text("Calendar access is off. Enable it in Settings to see your events.")
                .font(DesignPalette.body(12))
                .foregroundStyle(DesignPalette.ink)
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignPalette.sage, in: RoundedRectangle(cornerRadius: 15))
    }

    // MARK: - Day section (calendar events + recommendations)

    private func daySection(_ day: Date) -> some View {
        let groups = groupExactOverlap(events(for: day))

        return VStack(alignment: .leading, spacing: 9) {
            if groups.isEmpty {
                Text("No events")
                    .font(DesignPalette.body(12))
                    .foregroundStyle(DesignPalette.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 15))
            } else {
                ForEach(Array(groups.enumerated()), id: \.offset) { slotIndex, group in
                    if group.count == 1 {
                        eventRow(group[0])
                    } else {
                        eventSlot(group, day: day, slotIndex: slotIndex)
                    }
                }
            }
        }
    }

    // MARK: - Recommendations

    private func recommendationsSection(_ day: Date) -> some View {
        let recommendation = recommendationService.recommendations(for: day)

        return Group {
            if let recommendation {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image("spark-icon")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 17, height: 17)
                            .foregroundStyle(DesignPalette.primary)

                        Text("Recommended")
                            .font(DesignPalette.body(14).weight(.bold))
                            .foregroundStyle(DesignPalette.ink)

                        Spacer(minLength: 4)

                        if calendar.isDateInToday(day) {
                            Text("\(formatMinutes(remainingFreeMinutesToday())) left today")
                                .font(DesignPalette.body(11).weight(.semibold))
                                .foregroundStyle(DesignPalette.secondary)
                        } else {
                            Text("\(formatMinutes(recommendation.availableMinutes)) free")
                                .font(DesignPalette.body(11).weight(.semibold))
                                .foregroundStyle(DesignPalette.secondary)
                        }
                    }

                    if !didSeeReorderTip && !recommendation.items.isEmpty {
                        Label("Long-press and drag a task to reorder", systemImage: "hand.draw")
                            .font(DesignPalette.body(11))
                            .foregroundStyle(DesignPalette.secondary)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DesignPalette.sage, in: RoundedRectangle(cornerRadius: 10))
                            .onAppear {
                                didSeeReorderTip = true
                            }
                    }

                    if recommendation.items.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Nothing recommended — no free time or no open tasks.")
                                .font(DesignPalette.body(12))
                                .foregroundStyle(DesignPalette.ink)
                            Button {
                                showAddTask = true
                            } label: {
                                Label("Add a task", systemImage: "plus")
                            }
                            .buttonStyle(.bordered)
                            .tint(DesignPalette.primary)
                            .controlSize(.small)
                        }
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
                                            .background(DesignPalette.card.opacity(0.9), in: RoundedRectangle(cornerRadius: 15))
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
                .padding(EdgeInsets(top: 17, leading: 18, bottom: 17, trailing: 18))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesignPalette.cream, in: RoundedRectangle(cornerRadius: 18))
            } else if !recommendationService.isLoading,
                      let message = recommendationService.errorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image("spark-icon")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 17, height: 17)
                            .foregroundStyle(DesignPalette.primary)
                        Text("Recommended")
                            .font(DesignPalette.body(14).weight(.bold))
                            .foregroundStyle(DesignPalette.ink)
                    }
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(DesignPalette.body(12))
                        .foregroundStyle(DesignPalette.secondary)
                }
                .padding(EdgeInsets(top: 17, leading: 18, bottom: 17, trailing: 18))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesignPalette.cream, in: RoundedRectangle(cornerRadius: 18))
            }
        }
    }

    private func recommendedRow(_ item: RecommendedPart, for day: Date) -> some View {
        let isToday = calendar.isDateInToday(day)
        let remainingToday = remainingFreeMinutesToday()

        return HStack(spacing: 10) {
            Button {
                startRecommendedFocus(item)
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(DesignPalette.primary)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
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
                            .font(DesignPalette.body(14).weight(.bold))
                            .foregroundStyle(DesignPalette.ink)
                            .lineLimit(2)
                        if let category = item.category, !category.isEmpty {
                            Text(category)
                                .font(DesignPalette.body(10))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(DesignPalette.sage, in: Capsule())
                                .foregroundStyle(DesignPalette.secondary)
                        }
                        if let block = item.timeBlockText {
                            Label(block, systemImage: "clock")
                                .font(DesignPalette.body(11))
                                .foregroundStyle(DesignPalette.secondary)
                        } else if !item.reason.isEmpty {
                            Text(item.reason)
                                .font(DesignPalette.body(11))
                                .foregroundStyle(DesignPalette.secondary)
                        }
                        if item.isOverdue {
                            Label("Overdue", systemImage: "exclamationmark.circle.fill")
                                .font(DesignPalette.body(11))
                                .foregroundStyle(.red)
                        }
                    }

                    Spacer(minLength: 4)

                    if isToday && remainingToday < item.minutes {
                        Label(
                            "Needs \(formatMinutes(item.minutes - remainingToday)) more free time",
                            systemImage: "clock"
                        )
                        .font(DesignPalette.body(10))
                        .foregroundStyle(DesignPalette.secondary)
                    }

                    VStack(spacing: 4) {
                        Text(formatMinutes(item.minutes))
                            .font(DesignPalette.body(11).weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(DesignPalette.ink)
                        Image("right-icon-1")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 14, height: 14)
                            .foregroundStyle(DesignPalette.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 15))
    }

    private var unscheduledSection: some View {
        let parts = recommendationService.unscheduled
        return Group {
            if !parts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .foregroundStyle(DesignPalette.primary)
                        Text("Doesn't fit this window")
                            .font(DesignPalette.body(14).weight(.bold))
                            .foregroundStyle(DesignPalette.ink)
                    }
                    Text("These tasks can't fit before their deadlines within this window. Adjust your work hours, free up calendar time, or break them into smaller pieces.")
                        .font(DesignPalette.body(12))
                        .foregroundStyle(DesignPalette.secondary)
                    ForEach(parts) { part in
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(priorityColor(part.priority))
                                .frame(width: 4, height: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(displayTitle(taskTitle: part.taskTitle, partTitle: part.partTitle))
                                    .font(DesignPalette.body(13).weight(.semibold))
                                    .lineLimit(2)
                                if let category = part.category, !category.isEmpty {
                                    Text(category)
                                        .font(DesignPalette.body(10))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(DesignPalette.sage, in: Capsule())
                                        .foregroundStyle(DesignPalette.secondary)
                                }
                            }
                            Spacer()
                            Text(formatMinutes(part.minutes))
                                .font(DesignPalette.body(11).weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(DesignPalette.secondary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .background(DesignPalette.cream, in: RoundedRectangle(cornerRadius: 12))
                    }
                    Button {
                        showPreferences = true
                    } label: {
                        Label("Adjust work hours", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                    .tint(DesignPalette.primary)
                    .controlSize(.small)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 18))
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
                .tint(DesignPalette.primary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(pendingReviews.count) event\(pendingReviews.count == 1 ? "" : "s") to confirm")
                        .font(DesignPalette.body(14).weight(.bold))
                        .foregroundStyle(DesignPalette.secondary)
                        .padding(.horizontal, 4)

                    ForEach(orderStore.reorder(pendingReviews, id: \.id.uuidString)) { task in
                        reviewRow(task)
                            .opacity(draggingId == task.id.uuidString ? 0.4 : 1)
                            .overlay {
                                if draggingId == task.id.uuidString {
                                    reviewRow(task)
                                        .background(DesignPalette.card.opacity(0.9), in: RoundedRectangle(cornerRadius: 15))
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(priorityColor(task.priority))
                    .frame(width: 4, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(DesignPalette.body(14).weight(.bold))
                        .foregroundStyle(DesignPalette.ink)
                        .lineLimit(2)
                    if let start = task.startAt, let end = task.endAt {
                        Text("\(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))")
                            .font(DesignPalette.body(11))
                            .foregroundStyle(DesignPalette.secondary)
                    } else if let start = task.startAt {
                        Text(start.formatted(date: .abbreviated, time: .shortened))
                            .font(DesignPalette.body(11))
                            .foregroundStyle(DesignPalette.secondary)
                    }
                }
                Spacer(minLength: 4)
                Button {
                    confirmReview(task)
                } label: {
                    Label("Looks good", systemImage: "checkmark.circle.fill")
                        .font(DesignPalette.body(12).weight(.bold))
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignPalette.primary)
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
            .font(DesignPalette.body(11))
            .foregroundStyle(DesignPalette.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 15))
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

        return VStack(alignment: .leading, spacing: 9) {
            if isExpanded {
                ForEach(Array(items.enumerated()), id: \.element.id) { _, item in
                    eventRow(item)
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        _ = expandedSlots.remove(key)
                    }
                } label: {
                    Label("Collapse", systemImage: "chevron.up")
                        .font(DesignPalette.body(11).weight(.semibold))
                        .foregroundStyle(DesignPalette.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(DesignPalette.cream, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                let first = items[0]
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        _ = expandedSlots.insert(key)
                    }
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(DesignPalette.cream)
                            Image("event-icon")
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 19, height: 19)
                                .foregroundStyle(DesignPalette.secondary)
                        }
                        .frame(width: 36, height: 36)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(first.title)
                                .font(DesignPalette.body(14).weight(.bold))
                                .foregroundStyle(DesignPalette.ink)
                                .lineLimit(2)
                            Text("\(first.start.formatted(date: .omitted, time: .shortened)) – \(first.end.formatted(date: .omitted, time: .shortened))")
                                .font(DesignPalette.body(11))
                                .foregroundStyle(DesignPalette.secondary)
                        }
                        Spacer(minLength: 4)
                        Text("\(items.count - 1) more")
                            .font(DesignPalette.body(11).weight(.semibold))
                            .foregroundStyle(DesignPalette.secondary)
                        Image("right-icon-1")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 17, height: 17)
                            .foregroundStyle(DesignPalette.secondary)
                    }
                    .padding(14)
                    .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 15))
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
            isApp: isApp
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
        isApp: Bool
    ) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(isApp ? DesignPalette.sage : DesignPalette.cream)
                Image(isApp ? "check-icon" : "event-icon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 19, height: 19)
                    .foregroundStyle(isApp ? DesignPalette.primary : DesignPalette.secondary)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(DesignPalette.body(14).weight(.bold))
                    .foregroundStyle(DesignPalette.ink)
                    .lineLimit(2)
                    .strikethrough(ignored || completed)
                Text("\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))")
                    .font(DesignPalette.body(11))
                    .foregroundStyle(DesignPalette.secondary)
            }

            Spacer(minLength: 4)

            if isApp {
                if completed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DesignPalette.primary)
                } else {
                    Image("right-icon-1")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 17, height: 17)
                        .foregroundStyle(DesignPalette.secondary)
                }
            } else {
                VStack(spacing: 4) {
                    Text("Ignore")
                        .font(DesignPalette.body(10).weight(.semibold))
                        .foregroundStyle(DesignPalette.secondary)
                    if ignored {
                        Image(systemName: "nosign")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DesignPalette.secondary)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ignored ? DesignPalette.background : DesignPalette.card, in: RoundedRectangle(cornerRadius: 15))
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
