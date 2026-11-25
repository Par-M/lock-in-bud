import SwiftUI
import WidgetKit

extension Notification.Name {
    static let openFocus = Notification.Name("openFocus")
}

/// Dark-surface palette from the Focus frame (not part of the shared light tokens).
private enum FocusPalette {
    static let setup = Color(red: 32 / 255, green: 41 / 255, blue: 35 / 255)
    static let segmentTrack = Color(red: 53 / 255, green: 67 / 255, blue: 51 / 255)
    static let segmentSelected = Color(red: 90 / 255, green: 112 / 255, blue: 80 / 255)
    static let onDark = Color(red: 213 / 255, green: 222 / 255, blue: 205 / 255)
    static let lime = Color(red: 184 / 255, green: 217 / 255, blue: 109 / 255)
}

struct FocusDashboardView: View {
    @Environment(FocusService.self) private var focus
    @Environment(TaskService.self) private var taskService
    @Environment(CategoryStore.self) private var categoryStore
    @Environment(NotificationService.self) private var notificationService
    @Environment(ScheduleService.self) private var scheduleService

    private enum RangeOption: String, CaseIterable, Identifiable {
        case day = "1D"
        case threeDays = "3D"
        case fiveDays = "5D"
        case week = "1W"
        case twoWeeks = "2W"
        case month = "4W"
        var id: String { rawValue }
        var days: Int {
            switch self {
            case .day: return 1
            case .threeDays: return 3
            case .fiveDays: return 5
            case .week: return 7
            case .twoWeeks: return 14
            case .month: return 28
            }
        }
        var dateStart: Date {
            Calendar.current.date(byAdding: .day, value: -(days - 1), to: .now) ?? .now
        }
        var periodLabel: String {
            switch self {
            case .day: return "today"
            case .threeDays: return "past 3 days"
            case .fiveDays: return "past 5 days"
            case .week: return "this week (7 days)"
            case .twoWeeks: return "past 14 days"
            case .month: return "past 4 weeks"
            }
        }
    }

    /// Presentation-only choices from the Focus frame; the app-wide timer
    /// start/stop behaviour below is unchanged.
    private enum SessionMode: String, CaseIterable {
        case focus = "Focus"
        case shortBreak = "Short break"
    }

    @State private var range: RangeOption = .week
    @State private var showingStats = false
    @State private var pendingSessionStop: SessionStop?
    @AppStorage("focusTimerStartedAt") private var timerStartedAtRef = 0.0
    @AppStorage("focusTimerPausedAt") private var pausedAt = 0.0
    @State private var elapsedSeconds = 0
    @State private var timer: Timer?

    @State private var sessionMode: SessionMode = .focus
    @State private var durationMinutes = 25

    private var isTimerRunning: Bool { timerStartedAtRef > 0 }
    private var timerStartedAt: Date? {
        timerStartedAtRef > 0 ? Date(timeIntervalSince1970: timerStartedAtRef) : nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    if let errorMessage = focus.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 12))
                    }

                    focusSetupCard

                    if isTimerRunning, let message = FocusLiveActivityManager.shared.message {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(DesignPalette.secondary)
                            Button("Try lock-screen timer") { FocusLiveActivityManager.synchronize() }
                                .font(.footnote.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 15))
                    }

                    taskCard

                    HStack(alignment: .top, spacing: 10) {
                        statsButton
                        ChatButton()
                            .buttonStyle(
                                FocusToolCardStyle(
                                    icon: "chat-icon",
                                    title: "Ask Assistant",
                                    caption: "Find a starting point",
                                    background: DesignPalette.cream
                                )
                            )
                            .accessibilityLabel("Ask Assistant")
                    }
                }
                .padding(.horizontal, DesignPalette.pagePadding)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(DesignPalette.background)
            .navigationTitle("Focus")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
            .sheet(isPresented: $showingStats) {
                FocusStatsView()
            }
            .sheet(item: $pendingSessionStop) { stop in
                SessionCategorySheet(
                    categories: categoryStore.categories(from: taskService.tasks)
                ) { category in
                    await logSession(
                        startedAt: stop.startedAt,
                        endedAt: stop.endedAt,
                        category: category,
                        trackedSeconds: stop.trackedSeconds
                    )
                }
            }
            .task {
                await focus.loadFocus(after: range.dateStart, before: .now)
                await focus.loadMorningMessage()
                await rescheduleNotifications()
                if isTimerRunning {
                    WidgetDataStore.writeFocus(startedAt: FocusTimerStarter.isPaused ? 0 : Date().timeIntervalSince1970 - Double(FocusTimerStarter.elapsedSeconds()), title: FocusTimerStarter.isPaused ? "Paused · focus session" : FocusTimerStarter.activeTaskTitle ?? "Focus session")
                    WidgetCenter.shared.reloadTimelines(ofKind: "FocusTimerWidget")
                }
            }
            .onChange(of: range) {
                Task { await focus.loadFocus(after: range.dateStart, before: .now) }
            }
        }
        .appBackdrop()
    }

    private var header: some View {
        AppHeader(eyebrow: "FOCUS", title: "Enter panda mode.") {
            Button {
                Task { await focus.loadFocus(after: range.dateStart, before: .now) }
            } label: {
                Image("reset-icon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .foregroundStyle(DesignPalette.primary)
                    .frame(width: 44, height: 44)
                    .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reset focus")
            .accessibilityIdentifier("refreshFocusButton")
        }
    }

    private var focusSetupCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(SessionMode.allCases, id: \.self) { mode in
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { sessionMode = mode }
                    } label: {
                        Text(mode.rawValue)
                            .font(DesignPalette.body(11).weight(.bold))
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(sessionMode == mode ? .white : FocusPalette.onDark)
                    .background(
                        sessionMode == mode ? FocusPalette.segmentSelected : Color.clear,
                        in: RoundedRectangle(cornerRadius: 11)
                    )
                    .accessibilityLabel("\(mode.rawValue) mode")
                    .accessibilityAddTraits(sessionMode == mode ? .isSelected : [])
                }
            }
            .padding(4)
            .background(FocusPalette.segmentTrack, in: RoundedRectangle(cornerRadius: 12))

            VStack(spacing: 1) {
                focusPanda

                if isTimerRunning {
                    if let title = FocusTimerStarter.activeTaskTitle {
                        VStack(spacing: 2) {
                            Text(title)
                                .font(DesignPalette.body(12).weight(.medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            if let task = taskService.tasks.first(where: { $0.id == FocusTimerStarter.activeTaskID }),
                               let remaining = remainingMinutes(for: task) {
                                Text("\(remaining) min left")
                                    .font(DesignPalette.body(11))
                                    .foregroundStyle(FocusPalette.onDark)
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                Text(timerText)
                    .font(.system(size: 58, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("focusTimerLabel")

                Text("Quiet the noise. Do your thing.")
                    .font(DesignPalette.body(12))
                    .foregroundStyle(FocusPalette.onDark)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)

            HStack(spacing: 8) {
                ForEach([15, 25, 45], id: \.self) { minutes in
                    Button {
                        durationMinutes = minutes
                    } label: {
                        Text("\(minutes) min")
                            .font(DesignPalette.body(11).weight(.bold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(durationMinutes == minutes ? .white : FocusPalette.onDark)
                    .background(
                        durationMinutes == minutes ? FocusPalette.segmentSelected : FocusPalette.segmentTrack,
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .accessibilityLabel("\(minutes) minute session")
                    .accessibilityAddTraits(durationMinutes == minutes ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity)

            if isTimerRunning {
                HStack(spacing: 10) {
                    Button {
                        FocusTimerStarter.togglePause()
                    } label: {
                        Label(
                            pausedAt > 0 ? "Resume" : "Pause",
                            systemImage: pausedAt > 0 ? "play.fill" : "pause.fill"
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(FocusPalette.lime)

                    Button(role: .destructive) {
                        stopTimer()
                    } label: {
                        Label("Stop & log session", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            } else {
                Button {
                    startTimer()
                } label: {
                    HStack(spacing: 8) {
                        Image("play-icon")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 19, height: 19)
                        Text("Start focus session")
                            .font(DesignPalette.body(13).weight(.heavy))
                    }
                    .foregroundStyle(DesignPalette.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                }
                .buttonStyle(.plain)
                .background(FocusPalette.lime, in: RoundedRectangle(cornerRadius: 13))
                .accessibilityIdentifier("startFocusTimerButton")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FocusPalette.setup, in: RoundedRectangle(cornerRadius: 20))
        .onAppear {
            resumeTickerIfRunning()
        }
        .onDisappear {
            timer?.invalidate()
        }
    }

    /// Focus-frame panda: its own five exported layers, never shared with stats.
    private var focusPanda: some View {
        ZStack(alignment: .topLeading) {
            Image("body-af4c3524")
                .resizable().scaledToFit()
                .frame(width: 68.8, height: 45.3)
                .offset(x: 21.6, y: 55.5)
            Image("crossed-legs")
                .resizable().scaledToFit()
                .frame(width: 87.2, height: 20.2)
                .offset(x: 12.4, y: 81.8)
            Image("arms-and-paws")
                .resizable().scaledToFit()
                .frame(width: 79.1, height: 28.8)
                .offset(x: 16.4, y: 59.1)
            Image("head-cb85b101")
                .resizable().scaledToFit()
                .frame(width: 62.8, height: 54.9)
                .offset(x: 24.6, y: 10.0)
            Image("bamboo-sprout")
                .resizable().scaledToFit()
                .frame(width: 9.5, height: 19.6)
                .offset(x: 8.2, y: 83.1)
        }
        .frame(width: 112, height: 112)
        .background(DesignPalette.sage, in: Circle())
        .clipShape(Circle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Panda ready to focus")
    }

    private var timerText: String {
        if isTimerRunning {
            let minutes = Int(elapsedSeconds / 60)
            let seconds = elapsedSeconds % 60
            return String(format: "%02d:%02d", minutes, seconds)
        }
        return String(format: "%02d:00", durationMinutes)
    }

    private var taskCard: some View {
        HStack(spacing: 12) {
            Image("tasks-icon-9ef070ba")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 23, height: 23)
                .foregroundStyle(DesignPalette.ink)

            VStack(alignment: .leading, spacing: 4) {
                Text(FocusTimerStarter.activeTaskTitle ?? "What’s your one thing?")
                    .font(DesignPalette.body(13).weight(.bold))
                    .foregroundStyle(DesignPalette.ink)
                    .lineLimit(1)
                if FocusTimerStarter.activeTaskTitle != nil {
                    Text(FocusTimerStarter.activeCategory ?? "Active focus task")
                        .font(DesignPalette.body(11))
                        .foregroundStyle(DesignPalette.secondary)
                        .lineLimit(1)
                } else {
                    Text("Choose a task (optional)")
                        .font(DesignPalette.body(11))
                        .foregroundStyle(DesignPalette.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image("right-icon-e92a51ec")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 17, height: 17)
                .foregroundStyle(DesignPalette.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 15))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            FocusTimerStarter.activeTaskTitle ?? "What’s your one thing? Choose a task (optional)"
        )
    }

    private var statsButton: some View {
        Button {
            showingStats = true
        } label: {
            Text("View stats")
        }
        .buttonStyle(
            FocusToolCardStyle(
                icon: "chart-icon",
                title: "View stats",
                caption: "See your progress",
                background: DesignPalette.sage
            )
        )
        .accessibilityIdentifier("viewFocusStatsButton")
    }

    private func resumeTickerIfRunning() {
        guard isTimerRunning else { return }
        elapsedSeconds = FocusTimerStarter.elapsedSeconds()
        startTicker()
    }

    private func remainingMinutes(for task: TaskItem) -> Int? {
        guard let estimated = task.estimatedDuration else { return nil }
        let done = task.actualDuration ?? 0
        return max(0, estimated - done)
    }

    private func startTicker() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                self.elapsedSeconds = FocusTimerStarter.elapsedSeconds()
            }
        }
    }

    private func startTimer() {
        FocusTimerStarter.startFocus()
        timerStartedAtRef = FocusTimerStarter.startedAt
        resumeTickerIfRunning()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        guard let started = timerStartedAt else { return }
        let ended = Date()
        let trackedSeconds = max(1, FocusTimerStarter.elapsedSeconds())
        timerStartedAtRef = 0
        FocusLiveActivityManager.synchronize()
        WidgetDataStore.writeFocus(startedAt: 0)
        WidgetCenter.shared.reloadTimelines(ofKind: "FocusTimerWidget")
        if FocusTimerStarter.activeTaskID != nil {
            Task {
                await logSession(startedAt: started, endedAt: ended, category: nil, trackedSeconds: trackedSeconds)
            }
        } else {
            pendingSessionStop = SessionStop(startedAt: started, endedAt: ended, trackedSeconds: trackedSeconds)
        }
    }

    private func logSession(startedAt: Date, endedAt: Date, category: String?, trackedSeconds: Int? = nil) async {
        let activeTaskID = FocusTimerStarter.activeTaskID
        let activeCategory = FocusTimerStarter.activeCategory
        FocusTimerStarter.clearActiveTask()
        let resolvedCategory = category ?? activeCategory
        if let resolvedCategory, !resolvedCategory.isEmpty {
            categoryStore.add(resolvedCategory)
        }
        let seconds = trackedSeconds ?? max(1, Int(endedAt.timeIntervalSince(startedAt)))
        await focus.createSession(
            taskID: activeTaskID,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: seconds,
            category: resolvedCategory
        )
        await rescheduleNotifications()
    }

    private func rescheduleNotifications() async {
        guard notificationService.authorizationStatus == .authorized
            || notificationService.authorizationStatus == .provisional else { return }
        let workStart = scheduleService.preference?.workHoursStart ?? 9
        let workEnd = scheduleService.preference?.workHoursEnd ?? 17
        let hasOngoingFocus = isTimerRunning
        notificationService.scheduleAll(
            tasks: taskService.tasks,
            events: [],
            blocks: scheduleService.blocks,
            workHoursStart: workStart,
            workHoursEnd: workEnd,
            hasOngoingFocus: hasOngoingFocus,
            morningMessage: focus.morningMessage?.message
        )
    }
}

/// Icon-first tool tile used for "View stats" and "Ask Assistant".
private struct FocusToolCardStyle: ButtonStyle {
    let icon: String
    let title: String
    let caption: String
    let background: Color

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(icon)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .foregroundStyle(DesignPalette.ink)
            Text(title)
                .font(DesignPalette.body(13).weight(.bold))
                .foregroundStyle(DesignPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(caption)
                .font(DesignPalette.body(9))
                .foregroundStyle(DesignPalette.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
        .padding(16)
        .background(background, in: RoundedRectangle(cornerRadius: 17))
        .scaleEffect(configuration.isPressed ? 0.97 : 1)
        .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

struct SessionStop: Identifiable {
    let id = UUID()
    let startedAt: Date
    let endedAt: Date
    var trackedSeconds: Int? = nil
}
