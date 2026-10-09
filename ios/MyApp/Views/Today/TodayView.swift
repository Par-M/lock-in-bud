import SwiftUI
import Combine

struct TodayView: View {
    @Environment(TaskService.self) private var tasks
    @Environment(ScheduleService.self) private var schedule
    @State private var showAdd = false
    @State private var selectedTask: TaskItem?
    @State private var issue: String?
    @State private var now = Date()
    @State private var saving = Set<UUID>()
    @State private var lastCompletion: (task: TaskItem, date: Date)?
    @AppStorage("focusTimerStartedAt") private var timerStart = 0.0

    private var active: [TaskItem] {
        tasks.tasks.filter { !$0.isArchived && !$0.isCompleteToday }.sorted {
            ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture)
        }
    }
    private var todayTasks: [TaskItem] { active.filter { $0.todayGroup != "Upcoming" && $0.todayGroup != "Unscheduled" } }
    private var next: TaskItem? { (todayTasks + active).first { $0.startAt == nil } }
    private var nextEvent: (title: String, start: Date, end: Date)? {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: .now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? .now
        let visibleBlocks = schedule.blocks.filter { $0.completedAt == nil && $0.startAt < dayEnd && $0.endAt > .now }
        let blockIDs = Set(visibleBlocks.map(\.taskId))
        let blocks = visibleBlocks.map { (title: $0.title, start: $0.startAt, end: $0.endAt) }
        let events = tasks.tasks.flatMap { task -> [(title: String, start: Date, end: Date)] in
            guard !task.isArchived, task.status != .completed, !blockIDs.contains(task.id), let start = task.startAt, let end = task.endAt else { return [] }
            if task.repeatWeekdays?.isEmpty == false {
                return CalendarEventItem.repeatingEvents(for: task, on: .now).filter { event in
                    task.repeatOverrides?[OccurrenceDateKey.key(for: event.occurrenceDate ?? event.start)]?.completed != true
                }.map { ($0.title, $0.start, $0.end) }
            }
            return [(task.title, start, end)]
        }
        return (blocks + events).filter { $0.start < dayEnd && $0.end > .now }.sorted { $0.start < $1.start }.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(now.formatted(date: .complete, time: .omitted)).font(.subheadline).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("One thing at a time").font(.subheadline).foregroundStyle(.secondary)
                        Text(timerStart > 0 ? FocusTimerStarter.activeTaskTitle ?? "Focus session in progress" : next?.title ?? "Make room for what matters").font(.title2.bold())
                        if let estimate = next?.estimatedDuration, timerStart <= 0 { Text("\(estimate) minutes estimated").foregroundStyle(.secondary) }
                        Button(timerStart > 0 ? "Return to focus" : "Start focus", systemImage: "play.fill") { startFocus(next) }.buttonStyle(.borderedProminent)
                    }.padding().frame(maxWidth: .infinity, alignment: .leading).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    if let error = tasks.errorMessage ?? schedule.errorMessage { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange); Button("Retry loading your day") { Task { await tasks.loadTasks(); await schedule.loadBlocks() } } }
                    if let issue { Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityAddTraits(.updatesFrequently) }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Next event").font(.headline)
                        if let event = nextEvent {
                            Text(event.title)
                            Text("\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                        } else { Text("No more events today. Your time is yours.").foregroundStyle(.secondary) }
                    }
                    Text("Today’s tasks").font(.headline)
                    if tasks.isLoading && tasks.tasks.isEmpty { ProgressView("Loading your day…") }
                    else if todayTasks.isEmpty {
                        ContentUnavailableView { Label("You’re clear for today", systemImage: "checkmark.circle") } actions: { Button("Add a task") { showAdd = true } }
                    }
                    ForEach(todayTasks) { task in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Button { complete(task) } label: { Image(systemName: "circle").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel(task.repeatWeekdays?.isEmpty == false ? "Complete \(task.title) for today" : "Complete \(task.title)").disabled(saving.contains(task.id))
                                Button(task.title) { selectedTask = task }.font(.headline).foregroundStyle(.primary)
                            }
                            if saving.contains(task.id) { ProgressView("Saving…") }
                            if task.todayGroup == "Overdue" { Label("Overdue", systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                            Button("Start focus", systemImage: "play.fill") { startFocus(task) }.buttonStyle(.bordered)
                        }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }
                    ChatButton()
                }.padding()
            }
            .navigationTitle("Today")
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
            .safeAreaInset(edge: .bottom) {
                if let lastCompletion { HStack { Text("Task completed"); Button("Undo") { undoCompletion(lastCompletion) }; Button("Dismiss") { self.lastCompletion = nil } }.padding().background(.regularMaterial) }
            }
            .toolbar { Button("New task", systemImage: "plus") { showAdd = true } }
            .sheet(isPresented: $showAdd) { TaskFormView(mode: .add) }
            .sheet(item: $selectedTask) { task in NavigationStack { TaskDetailView(task: task) } }
            .task { await tasks.loadTasks(); await schedule.loadBlocks() }
            .refreshable { await tasks.loadTasks(); await schedule.loadBlocks() }
        }
    }
    private func complete(_ task: TaskItem) {
        guard !saving.contains(task.id) else { return }
        saving.insert(task.id)
        let date = Date()
        Task {
            defer { saving.remove(task.id) }
            do { _ = try await tasks.completeOccurrence(task, on: date); lastCompletion = (task, date) }
            catch { issue = "Couldn’t complete \(task.title). Retry the action." }
        }
    }
    private func undoCompletion(_ completion: (task: TaskItem, date: Date)) {
        lastCompletion = nil
        Task {
            do {
                if completion.task.repeatWeekdays?.isEmpty == false { _ = try await tasks.reopenOccurrence(completion.task, on: completion.date) }
                else if let saved = tasks.tasks.first(where: { $0.id == completion.task.id }) { _ = try await tasks.setStatus(completion.task.status, for: saved) }
            } catch { lastCompletion = completion; issue = "Couldn’t undo completion. Your completed task is still saved; retry Undo." }
        }
    }
    private func startFocus(_ task: TaskItem?) {
        if timerStart <= 0 {
            FocusTimerStarter.startFocus(taskID: task?.id, title: task?.title, category: task?.category)
            if let task, task.status == .pending {
                Task { do { _ = try await tasks.startTask(id: task.id) } catch { issue = "Timer started. Task status could not be updated; retry from task details." } }
            }
        }
        NotificationCenter.default.post(name: .openFocus, object: nil)
    }
}

extension TaskItem {
    var isCompleteToday: Bool {
        if status == .completed { return true }
        let date = OccurrenceDateKey.key(for: .now)
        return repeatWeekdays?.isEmpty == false && repeatOverrides?[date]?.completed == true
    }
    var todayGroup: String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        if let days = repeatWeekdays, !days.isEmpty {
            let weekday = calendar.component(.weekday, from: .now) - 1
            if days.contains(weekday), startAt.map({ calendar.startOfDay(for: $0) <= today }) ?? true, repeatEndsOn.map({ $0 >= today }) ?? true { return "Today" }
            return "Upcoming"
        }
        if let deadline, deadline < .now { return "Overdue" }
        if let date = deadline ?? startAt { return date < today ? "Overdue" : calendar.isDateInToday(date) ? "Today" : "Upcoming" }
        return "Unscheduled"
    }
}
