import SwiftUI
import WidgetKit

extension Notification.Name {
    static let openFocus = Notification.Name("openFocus")
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

    @State private var range: RangeOption = .week
    @State private var showingStats = false
    @State private var pendingSessionStop: SessionStop?
    @AppStorage("focusTimerStartedAt") private var timerStartedAtRef = 0.0
    @State private var elapsedSeconds = 0
    @State private var timer: Timer?

    private var isTimerRunning: Bool { timerStartedAtRef > 0 }
    private var timerStartedAt: Date? {
        timerStartedAtRef > 0 ? Date(timeIntervalSince1970: timerStartedAtRef) : nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let errorMessage = focus.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }

                    timerCard

                    statsButton
                    ChatButton()

                }
                .padding()
            }
            .navigationTitle("Focus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await focus.loadFocus(after: range.dateStart, before: .now) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("refreshFocusButton")
                }
            }
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
                        category: category
                    )
                }
            }
            .task {
                await focus.loadFocus(after: range.dateStart, before: .now)
                await focus.loadMorningMessage()
                await rescheduleNotifications()
                if isTimerRunning {
                    WidgetDataStore.writeFocus(startedAt: timerStartedAtRef, title: "Deep Work Session")
                    WidgetCenter.shared.reloadTimelines(ofKind: "FocusTimerWidget")
                }
            }
            .onChange(of: range) {
                Task { await focus.loadFocus(after: range.dateStart, before: .now) }
            }
        }
    }

    private var timerCard: some View {
        let minutes = Int(elapsedSeconds / 60)
        let seconds = elapsedSeconds % 60
        return VStack(spacing: 12) {
            if isTimerRunning {
                if let title = FocusTimerStarter.activeTaskTitle {
                    VStack(spacing: 2) {
                        Text(title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        if let task = taskService.tasks.first(where: { $0.id == FocusTimerStarter.activeTaskID }),
                           let remaining = remainingMinutes(for: task) {
                            Text("\(remaining) min left")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text(String(format: "%02d:%02d", minutes, seconds))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .accessibilityIdentifier("focusTimerLabel")

                Button(role: .destructive) {
                    stopTimer()
                } label: {
                    Label("Stop & log session", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button {
                    startTimer()
                } label: {
                    Label("Start focus session", systemImage: "timer")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("startFocusTimerButton")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .onAppear {
            resumeTickerIfRunning()
        }
        .onDisappear {
            timer?.invalidate()
        }
    }

    private func resumeTickerIfRunning() {
        guard isTimerRunning, let started = timerStartedAt else { return }
        elapsedSeconds = Int(Date().timeIntervalSince(started))
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
                self.elapsedSeconds = Int(Date().timeIntervalSince(self.timerStartedAt ?? .now))
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
        timerStartedAtRef = 0
        WidgetDataStore.writeFocus(startedAt: 0)
        WidgetCenter.shared.reloadTimelines(ofKind: "FocusTimerWidget")
        if FocusTimerStarter.activeTaskID != nil {
            Task {
                if #available(iOS 16.1, *) {
                    await FocusLiveActivityManager.endLiveActivity(elapsedSeconds: elapsedSeconds)
                }
                await logSession(startedAt: started, endedAt: ended, category: nil)
            }
        } else {
            pendingSessionStop = SessionStop(startedAt: started, endedAt: ended)
            Task {
                if #available(iOS 16.1, *) {
                    await FocusLiveActivityManager.endLiveActivity(elapsedSeconds: elapsedSeconds)
                }
            }
        }
    }

    private func logSession(startedAt: Date, endedAt: Date, category: String?) async {
        let activeTaskID = FocusTimerStarter.activeTaskID
        let activeCategory = FocusTimerStarter.activeCategory
        FocusTimerStarter.clearActiveTask()
        let resolvedCategory = category ?? activeCategory
        if let resolvedCategory, !resolvedCategory.isEmpty {
            categoryStore.add(resolvedCategory)
        }
        let seconds = max(1, Int(endedAt.timeIntervalSince(startedAt)))
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

    private var statsButton: some View {
        Button {
            showingStats = true
        } label: {
            HStack {
                Label("View stats", systemImage: "chart.bar.xaxis")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("viewFocusStatsButton")
    }

}

struct SessionStop: Identifiable {
    let id = UUID()
    let startedAt: Date
    let endedAt: Date
}
