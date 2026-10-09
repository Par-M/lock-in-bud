import SwiftUI

struct TaskRow: View {
    let task: TaskItem
    var isBusy = false
    var issue: String? = nil
    var onChangeStatus: (TaskStatus) -> Void = { _ in }
    var onStartFocus: (TaskItem) -> Void = { _ in }

    private var statusColor: Color {
        switch task.status {
        case .pending: .gray
        case .inProgress: .blue
        case .completed: .green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if isBusy { ProgressView().accessibilityLabel("Saving task") }
                PriorityBadge(priority: task.priority)
                Text(task.title)
                    .font(.body.weight(.medium))
                    .strikethrough(task.status == .completed, color: .secondary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if task.status != .completed {
                    Button {
                        onStartFocus(task)
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Start focus on \(task.title)")
                }
                if let estimated = task.estimatedDuration {
                    TimeFractionLabel(actual: task.actualDuration ?? 0, estimated: estimated)
                }
            }

            HStack(spacing: 12) {
                if let deadline = task.deadline {
                    Label(monthDay(deadline), systemImage: "calendar")
                }
                if let category = task.category, !category.isEmpty {
                    Text(category)
                        .padding(.horizontal, 8)
                        .disabled(isBusy)
        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer(minLength: 8)
                statusMenu
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let issue { Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
        }
        .padding(.vertical, 2)
    }

    private func monthDay(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    private var statusMenu: some View {
        Menu {
            ForEach(TaskStatus.allCases) { status in
                Button {
                    onChangeStatus(status)
                } label: {
                    if status == task.status {
                        Label(status.label, systemImage: "checkmark")
                    } else {
                        Text(status.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Text(task.status.label)
                    .font(.caption2.weight(.medium))
                    .lineLimit(2)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8).weight(.semibold))
            }
            .foregroundStyle(statusColor)
            .fixedSize()
        }
    }
}

struct DeferredTaskRow: View {
    let task: TaskItem
    var onChangeStatus: (TaskStatus) -> Void = { _ in }
    var onStartFocus: (TaskItem) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    PriorityBadge(priority: task.priority)
                    Text(task.title)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button {
                        onStartFocus(task)
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Start focus on \(task.title)")
                    if let estimated = task.estimatedDuration {
                        TimeFractionLabel(actual: task.actualDuration ?? 0, estimated: estimated)
                    }
                }
                HStack(spacing: 12) {
                    if let deadline = task.deadline {
                        Label(
                            "Missed \(monthDay(deadline))",
                            systemImage: "calendar.badge.exclamationmark"
                        )
                    } else if let start = task.startAt {
                        Label(
                            "Was scheduled \(start.formatted(date: .omitted, time: .shortened))",
                            systemImage: "clock.badge.exclamationmark"
                        )
                    } else {
                        Text("Behind schedule")
                    }
                    Spacer(minLength: 8)
                    Menu {
                        ForEach(TaskStatus.allCases) { status in
                            Button {
                                onChangeStatus(status)
                            } label: {
                                if status == task.status {
                                    Label(status.label, systemImage: "checkmark")
                                } else {
                                    Text(status.label)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Text(task.status.label)
                                .font(.caption2.weight(.medium))
                                .lineLimit(2)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8).weight(.semibold))
                        }
                        .foregroundStyle(.orange)
                        .fixedSize()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func monthDay(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }
}

struct TimeFractionLabel: View {
    let actual: Int
    let estimated: Int

    var body: some View {
        Text("\(actual) of \(estimated) min tracked")
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}

struct PriorityBadge: View {
    let priority: TaskPriority

    private var color: Color {
        switch priority {
        case .low: .green
        case .medium: .orange
        case .high: .red
        }
    }

    var body: some View {
        Image(systemName: "flag.fill")
            .font(.caption)
            .foregroundStyle(color)
            .accessibilityLabel("\(priority.label) priority")
    }
}

struct TaskListView: View {
    @Environment(TaskService.self) private var taskService
    @Environment(AuthenticationService.self) private var authService
    @Environment(NotificationService.self) private var notificationService

    @State private var searchText = ""
    @State private var sortOption: TaskService.SortOption = .created
    @State private var sortAscending = false
    @State private var showAddTask = false
    @State private var showNotificationSettings = false
    @State private var showSettings = false
    @State private var showOverdue = false
    @State private var quickTaskTitle = ""
    @State private var isAddingQuickTask = false
    @State private var quickAddError: String?
    @State private var rowError: String?
    @State private var savingRows = Set<UUID>()
    @State private var rowIssues: [UUID: String] = [:]
    @State private var reschedulingTask: TaskItem?
    @State private var errorDismissed = false
    @State private var isCompletedExpanded = false
    @State private var confirmSignOut = false

    private struct LoadKey: Hashable {
        let search: String
        let archived: Bool
        let sort: TaskService.SortOption
        let order: String
        let dataVersion: Int
    }

    private var loadKey: LoadKey {
        LoadKey(
            search: searchText,
            archived: taskService.showingArchived,
            sort: sortOption,
            order: sortAscending ? "asc" : "desc",
            dataVersion: taskService.dataVersion
        )
    }

    private var quickAddSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.secondary)
                    TextField("Quick add a task…", text: $quickTaskTitle)
                        .submitLabel(.done)
                        .onSubmit {
                            Task { await addQuickTask() }
                        }
                    if isAddingQuickTask {
                        ProgressView()
                    }
                }
                .padding(.vertical, 4)
                if let quickAddError {
                    Label(quickAddError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func addQuickTask() async {
        let title = quickTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !isAddingQuickTask else { return }
        isAddingQuickTask = true
        quickAddError = nil
        defer { isAddingQuickTask = false }
        do {
            _ = try await taskService.quickAdd(text: title)
            quickTaskTitle = ""
        } catch {
            quickAddError = "Couldn't add task. Try again."
        }
    }

    private func changeStatus(_ status: TaskStatus, task: TaskItem) {
        guard !savingRows.contains(task.id) else { return }
        savingRows.insert(task.id)
        rowIssues[task.id] = nil
        Task {
            defer { savingRows.remove(task.id) }
            do { _ = try await taskService.setStatus(status, for: task) }
            catch { rowIssues[task.id] = "Couldn’t update this task. Your changes were not confirmed; retry the action." }
        }
    }

    private func startFocus(_ task: TaskItem) {
        let wasRunning = FocusTimerStarter.startedAt > 0
        FocusTimerStarter.startFocus(
            taskID: task.id,
            title: task.title,
            category: task.category
        )
        if !wasRunning, task.status == .pending {
            Task { do { _ = try await taskService.startTask(id: task.id) } catch { rowError = "Timer started. Task status could not be updated; check the task when online." } }
        }
        NotificationCenter.default.post(name: .openFocus, object: nil)
    }

    private var activeTasks: [TaskItem] {
        taskService.tasks.filter { $0.status != .completed }
    }

    private var completedTasks: [TaskItem] {
        taskService.tasks.filter { $0.status == .completed }
    }

    private var deferredTasks: [TaskItem] {
        let deferredIDs = Set(taskService.overdueTasks.map(\.id))
        return activeTasks.filter { deferredIDs.contains($0.id) }
    }

    private var schedulableTasks: [TaskItem] {
        let deferredIDs = Set(taskService.overdueTasks.map(\.id))
        return activeTasks.filter { !deferredIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if taskService.isLoading && taskService.tasks.isEmpty {
                    ProgressView("Loading tasks…")
                } else if taskService.tasks.isEmpty {
                    if !searchText.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else {
                        VStack {
                        ContentUnavailableView(
                            taskService.showingArchived ? "No Archived Tasks" : "No Tasks Yet",
                            systemImage: "checklist",
                            description: Text(
                                taskService.showingArchived
                                    ? "Tasks you archive will appear here."
                                    : "Tap + to create your first task."
                            )
                        )
                        Button("Add your first task") { showAddTask = true }.buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    List {
                        quickAddSection
                        ForEach(["Overdue", "Today", "Upcoming", "Unscheduled"], id: \.self) { group in
                            let items = activeTasks.filter { $0.todayGroup == group }
                            if !items.isEmpty {
                                Section(group) {
                                    ForEach(items) { task in
                                        NavigationLink(value: task) {
                                            TaskRow(task: task, isBusy: savingRows.contains(task.id), issue: rowIssues[task.id]) { status in
                                                changeStatus(status, task: task)
                                            } onStartFocus: { task in startFocus(task) }
                                        }
                                    }
                                }
                            }
                        }

                        if !completedTasks.isEmpty {
                            Section {
                                DisclosureGroup(isExpanded: $isCompletedExpanded) {
                                    ForEach(completedTasks) { task in
                                        NavigationLink(value: task) {
                                            TaskRow(task: task, isBusy: savingRows.contains(task.id), issue: rowIssues[task.id]) { status in
                                                changeStatus(status, task: task)
                                            }
                                        }
                                    }
                                } label: {
                                    HStack {
                                        Text("Completed")
                                            .font(.caption)
                                        Spacer()
                                        Text("\(completedTasks.count)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .searchable(text: $searchText, prompt: "Search tasks")
                }
            }
            .navigationTitle(taskService.showingArchived ? "Archived" : "Tasks")
            .safeAreaInset(edge: .bottom) { if let rowError { HStack { Text(rowError).font(.caption); Button("Dismiss") { self.rowError = nil } }.padding().background(.regularMaterial) } }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        if let name = authService.user?.name {
                            Text(name)
                        }
                        if let email = authService.user?.email {
                            Text(email)
                        }
                        Divider()
                        Button {
                            showSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        Button {
                            showNotificationSettings = true
                        } label: {
                            Label("Notifications", systemImage: "bell")
                        }
                        Button("Log Out", role: .destructive) {
                            confirmSignOut = true
                        }
                    } label: {
                        Image(systemName: "person.crop.circle")
                            .accessibilityLabel("Account")
                    }
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    if !taskService.overdueTasks.isEmpty {
                        Button {
                            showOverdue = true
                        } label: {
                            Label("Overdue", systemImage: "exclamationmark.triangle")
                                .badge(taskService.overdueTasks.count)
                        }
                        .accessibilityIdentifier("overdueBadgeButton")
                    }

                    Button {
                        showAddTask = true
                    } label: {
                        Label("Add Task", systemImage: "plus")
                    }
                    .accessibilityIdentifier("addTaskButton")

                    Menu {
                        ForEach(TaskService.SortOption.allCases) { option in
                            Button {
                                if sortOption == option {
                                    sortAscending.toggle()
                                } else {
                                    sortOption = option
                                    sortAscending = option != .deadline
                                }
                            } label: {
                                if sortOption == option {
                                    Label(
                                        option.label,
                                        systemImage: sortAscending ? "arrow.up" : "arrow.down"
                                    )
                                } else {
                                    Text(option.label)
                                }
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }

                    Button {
                        taskService.setShowingArchived(!taskService.showingArchived)
                    } label: {
                        Label(
                            taskService.showingArchived ? "Active" : "Archived",
                            systemImage: "archivebox"
                        )
                    }
                    .accessibilityIdentifier("archiveToggleButton")
                }
            }
            .navigationDestination(for: TaskItem.self) { task in
                TaskDetailView(task: task)
            }
            .sheet(isPresented: $showAddTask) {
                TaskFormView(mode: .add)
            }
            .sheet(isPresented: $showNotificationSettings) {
                NavigationStack {
                    NotificationSettingsView()
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showOverdue) {
                OverdueListSheet { task in
                    showOverdue = false
                    reschedulingTask = task
                }
            }
            .sheet(item: $reschedulingTask) { task in
                RescheduleSheet(task: task) { minutes, deadline, reason in
                    Task {
                        await reschedule(
                            task,
                            minutes: minutes,
                            deadline: deadline,
                            reason: reason
                        )
                    }
                }
            }
            .confirmationDialog(
                "Log out?",
                isPresented: $confirmSignOut,
                titleVisibility: .visible
            ) {
                Button("Log Out", role: .destructive) {
                    authService.signOut()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You can sign back in anytime. Your data is synced to your account.")
            }
.task(id: loadKey) {
                        await taskService.loadTasks(
                            search: searchText,
                            sort: sortOption,
                            order: sortAscending ? "asc" : "desc"
                        )
                    }
.task {
                        await taskService.loadOverdue()
                    }
                    .onChange(of: taskService.tasks) { _, tasks in
                        notificationService.scheduleLocalNotifications(tasks: tasks)
                    }
                    .overlay(alignment: .bottom) {
                if let errorMessage = taskService.errorMessage, !errorDismissed {
                    VStack {
                        HStack {
                            Text(errorMessage)
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
                        .padding()
                    }
                }
            }
        }
    }

    private func reschedule(
        _ task: TaskItem,
        minutes: Int,
        deadline: Date?,
        reason: String?
    ) async {
        do {
            _ = try await taskService.rescheduleTask(
                task,
                minutesRemaining: minutes,
                deadline: deadline,
                reason: reason
            )
            await taskService.loadOverdue()
        } catch {
            taskService.presentError(error.localizedDescription)
        }
    }
}

private struct OverdueListSheet: View {
    @Environment(TaskService.self) private var taskService
    @Environment(\.dismiss) private var dismiss
    let onReschedule: (TaskItem) -> Void

    var body: some View {
        NavigationStack {
            List {
                if taskService.overdueTasks.isEmpty {
                    ContentUnavailableView(
                        "No overdue tasks",
                        systemImage: "checkmark.circle",
                        description: Text("You're all caught up.")
                    )
                } else {
                    ForEach(taskService.overdueTasks) { task in
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title)
                                    .font(.body.weight(.medium))
                                if let deadline = task.deadline {
                                    Text("Missed \(deadline.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if let start = task.startAt {
                                    Text("Was scheduled at \(start.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Behind schedule")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Reschedule") {
                                onReschedule(task)
                            }
                            .font(.caption.weight(.semibold))
                        }
                    }
                }
            }
            .navigationTitle("Overdue Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    TaskListView()
        .environment(TaskService())
        .environment(AuthenticationService())
        .environment(NotificationService.shared)
}


extension TaskItem {
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
