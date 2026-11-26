import SwiftUI

// MARK: - Row components

struct TaskRow: View {
    let task: TaskItem
    var isBusy = false
    var issue: String? = nil
    var onChangeStatus: (TaskStatus) -> Void = { _ in }
    var onStartFocus: (TaskItem) -> Void = { _ in }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if isBusy { ProgressView().accessibilityLabel("Saving task") }

            Image("mark-wednesday-upper-complete")
                .resizable()
                .scaledToFit()
                .frame(width: 21, height: 21)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(task.title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignPalette.ink)
                    .strikethrough(task.status == .completed, color: DesignPalette.secondary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Image("flag-icon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 11, height: 11)
                        .accessibilityHidden(true)
                    Text(metadata)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(DesignPalette.secondary)
                        .lineLimit(1)
                }

                if let estimated = task.estimatedDuration {
                    TimeFractionLabel(actual: task.actualDuration ?? 0, estimated: estimated)
                }
                if let issue {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 6)

            VStack(spacing: 5) {
                if task.status != .completed {
                    focusButton
                }
                TaskStatusMenu(status: task.status, onChange: onChangeStatus)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: DesignPalette.ink.opacity(0.05), radius: 8, y: 3)
    }

    private var metadata: String {
        var parts = ["\(task.priority.label) priority"]
        if let category = task.category, !category.isEmpty { parts.append(category) }
        if let deadline = task.deadline {
            parts.append(deadline.formatted(.dateTime.month(.abbreviated).day()))
        }
        return parts.joined(separator: " · ")
    }

    private var focusButton: some View {
        Button {
            onStartFocus(task)
        } label: {
            Image("play-icon-6ec17d81")
                .resizable()
                .scaledToFit()
                .frame(width: 17, height: 17)
                .frame(width: 30, height: 30)
                .background(DesignPalette.sage, in: RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start focus on \(task.title)")
    }
}

struct DeferredTaskRow: View {
    let task: TaskItem
    var onChangeStatus: (TaskStatus) -> Void = { _ in }
    var onStartFocus: (TaskItem) -> Void = { _ in }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(task.title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignPalette.ink)
                    .lineLimit(2)
                Text(lateness)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(DesignPalette.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            VStack(spacing: 5) {
                Button {
                    onStartFocus(task)
                } label: {
                    Image("play-icon-6ec17d81")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 17, height: 17)
                        .frame(width: 30, height: 30)
                        .background(DesignPalette.sage, in: RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Start focus on \(task.title)")
                TaskStatusMenu(status: task.status, onChange: onChangeStatus)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignPalette.cream, in: RoundedRectangle(cornerRadius: 16))
    }

    private var lateness: String {
        if let deadline = task.deadline {
            return "Missed \(deadline.formatted(.dateTime.month(.abbreviated).day()))"
        } else if let start = task.startAt {
            return "Was scheduled \(start.formatted(date: .omitted, time: .shortened))"
        }
        return "Behind schedule"
    }
}

private struct TaskStatusMenu: View {
    let status: TaskStatus
    var onChange: (TaskStatus) -> Void
    var tint: Color? = nil

    private var statusColor: Color {
        if let tint { return tint }
        switch status {
        case .pending: return DesignPalette.secondary
        case .inProgress: return DesignPalette.primary
        case .completed: return DesignPalette.primary
        }
    }

    var body: some View {
        Menu {
            ForEach(TaskStatus.allCases) { option in
                Button {
                    onChange(option)
                } label: {
                    if option == status {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(status.label)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                Image("down-icon-897a3303")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 10, height: 10)
            }
            .foregroundStyle(statusColor)
            .fixedSize()
        }
    }
}

private struct UpcomingTaskCard: View {
    let task: TaskItem
    var onChangeStatus: (TaskStatus) -> Void
    var onStartFocus: (TaskItem) -> Void

    private var upcomingInk: Color {
        Color(red: 98 / 255, green: 99 / 255, blue: 62 / 255)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image("calendar-icon-c6be802d")
                .resizable()
                .scaledToFit()
                .frame(width: 17, height: 17)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(task.title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignPalette.ink)
                    .lineLimit(2)
                if let category = task.category, !category.isEmpty {
                    Text(category)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(DesignPalette.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            VStack(spacing: 5) {
                Button {
                    onStartFocus(task)
                } label: {
                    Image("play-icon-6ec17d81")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 17, height: 17)
                        .frame(width: 30, height: 30)
                        .background(DesignPalette.sage, in: RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Start focus on \(task.title)")
                HStack(spacing: 4) {
                    Image("flag-icon-1")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    TaskStatusMenu(status: task.status, onChange: onChangeStatus, tint: upcomingInk)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignPalette.cream, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct TimeFractionLabel: View {
    let actual: Int
    let estimated: Int

    var body: some View {
        Text("\(actual) of \(estimated) min tracked")
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(DesignPalette.secondary)
            .lineLimit(2)
    }
}

struct PriorityBadge: View {
    let priority: TaskPriority

    var body: some View {
        Image(systemName: "flag.fill")
            .font(.caption)
            .foregroundStyle(DesignPalette.primary)
            .accessibilityLabel("\(priority.label) priority")
    }
}

// MARK: - Screen-specific panda (Tasks frame layers)

private struct TasksPanda: View {
    var size: CGFloat = 72

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
            layer("body-ea3db0de", x: 19.78, y: 32.91, width: 33.90, height: 26.68)
            layer("feet-818e443b", x: 16.83, y: 50.32, width: 38.19, height: 9.70)
            layer("ears-64675a98", x: 19.70, y: 12.19, width: 33.75, height: 8.94)
            layer("head-c9079bf4", x: 19.55, y: 13.79, width: 33.30, height: 26.70)
            layer("thumbs-up-519cbb76", x: 11.55, y: 30.63, width: 14.04, height: 16.00)
            layer("bamboo-e9a069b1", x: 49.80, y: 29.70, width: 11.75, height: 23.72)
            layer("holding-paw-a9a42eee", x: 47.00, y: 39.42, width: 9.82, height: 8.62)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Tasks screen

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

    private var onDarkText: Color {
        Color(red: 213 / 255, green: 227 / 255, blue: 202 / 255)
    }

    private var progressTrack: Color {
        Color(red: 74 / 255, green: 87 / 255, blue: 71 / 255)
    }

    // MARK: Derived state

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

    // MARK: Actions

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
            catch { rowIssues[task.id] = "Couldn’t update this task. Try again." }
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
            Task { do { _ = try await taskService.startTask(id: task.id) } catch { rowError = "Timer started. Couldn’t update the task status; try again when online." } }
        }
        NotificationCenter.default.post(name: .openFocus, object: nil)
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

    // MARK: Screen sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 10) {
                Text("TASKS")
                    .font(DesignPalette.eyebrow())
                    .kerning(1.6)
                    .foregroundStyle(DesignPalette.primary)

                Spacer(minLength: 8)

                Menu {
                    if let name = authService.user?.name { Text(name) }
                    if let email = authService.user?.email { Text(email) }
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
                    Image(systemName: "person.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(DesignPalette.primary)
                        .frame(width: 44, height: 44)
                        .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityLabel("Account")

                Button {
                    showAddTask = true
                } label: {
                    Image("plus-icon-eb73ee1e")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .frame(width: 44, height: 44)
                        .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add Task")
                .accessibilityIdentifier("addTaskButton")
            }

            Text(taskService.showingArchived ? "Archived tasks." : "Time to bear down.")
                .font(DesignPalette.screenTitle())
                .kerning(-1)
                .foregroundStyle(DesignPalette.ink)
                .minimumScaleFactor(0.8)
        }
    }

    private var heroCard: some View {
        let total = taskService.tasks.count
        let done = completedTasks.count
        let progress = total == 0 ? 0 : min(1, CGFloat(done) / CGFloat(total))

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("One task first.")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer(minLength: 8)
                    Text("\(done) / \(total)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(onDarkText)
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(progressTrack)
                        Capsule()
                            .fill(DesignPalette.primary)
                            .frame(width: geometry.size.width * progress)
                    }
                }
                .frame(height: 6)

                Text("Progress beats panic. Pick one and roll.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(onDarkText)
            }

            TasksPanda(size: 72)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignPalette.ink, in: RoundedRectangle(cornerRadius: 21))
    }

    private var quickAddCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Image("plus-icon-1-1ec53dff")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)

                AppTextField(
                    placeholder: "Quick add a task…",
                    text: $quickTaskTitle,
                    font: .system(size: 14, weight: .medium, design: .rounded)
                )
                    .submitLabel(.done)
                    .onSubmit {
                        Task { await addQuickTask() }
                    }

                if isAddingQuickTask {
                    ProgressView()
                }
            }
            .padding(.vertical, 2)

            if let quickAddError {
                Label(quickAddError, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: DesignPalette.ink.opacity(0.05), radius: 8, y: 3)
    }

    private var filterRow: some View {
        HStack(spacing: 10) {
            Text("Today · \(activeTasks.count)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(DesignPalette.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(DesignPalette.sage, in: RoundedRectangle(cornerRadius: 12))

            Text("All pending")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(DesignPalette.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(DesignPalette.sage, in: RoundedRectangle(cornerRadius: 12))

            Spacer(minLength: 4)

            if !taskService.overdueTasks.isEmpty {
                Button {
                    showOverdue = true
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 19, height: 19)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Overdue")
                .accessibilityIdentifier("overdueBadgeButton")
            }

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
                            Label(option.label, systemImage: sortAscending ? "arrow.up" : "arrow.down")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
                Image("sort-icon-d399a188")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 19, height: 19)
            }
            .accessibilityLabel("Sort")

            Button {
                taskService.setShowingArchived(!taskService.showingArchived)
            } label: {
                Image("archive-icon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 19, height: 19)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(taskService.showingArchived ? "Active" : "Archived")
            .accessibilityIdentifier("archiveToggleButton")
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignPalette.secondary)
            AppTextField(
                placeholder: "Search tasks",
                text: $searchText,
                font: .system(size: 13, weight: .medium, design: .rounded)
            )
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DesignPalette.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private var taskGroups: some View {
        ForEach(["Overdue", "Today", "Upcoming", "Unscheduled"], id: \.self) { group in
            let items = activeTasks.filter { $0.todayGroup == group }
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    if group != "Today" {
                        Text(group == "Upcoming" ? "Up next" : group)
                            .font(DesignPalette.sectionTitle(15))
                            .foregroundStyle(DesignPalette.ink)
                    }

                    ForEach(items) { task in
                        NavigationLink(value: task) {
                            if group == "Upcoming" {
                                UpcomingTaskCard(task: task) { status in
                                    changeStatus(status, task: task)
                                } onStartFocus: { item in
                                    startFocus(item)
                                }
                            } else {
                                TaskRow(
                                    task: task,
                                    isBusy: savingRows.contains(task.id),
                                    issue: rowIssues[task.id]
                                ) { status in
                                    changeStatus(status, task: task)
                                } onStartFocus: { item in
                                    startFocus(item)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var completedSection: some View {
        Group {
            if !completedTasks.isEmpty {
                DisclosureGroup(isExpanded: $isCompletedExpanded) {
                    VStack(spacing: 9) {
                        ForEach(completedTasks) { task in
                            NavigationLink(value: task) {
                                TaskRow(
                                    task: task,
                                    isBusy: savingRows.contains(task.id),
                                    issue: rowIssues[task.id]
                                ) { status in
                                    changeStatus(status, task: task)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } label: {
                    HStack {
                        Text("Completed")
                            .font(DesignPalette.sectionTitle(15))
                            .foregroundStyle(DesignPalette.ink)
                        Spacer()
                        Text("\(completedTasks.count)")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(DesignPalette.secondary)
                    }
                }
                .padding(14)
                .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            VStack(spacing: 16) {
                ContentUnavailableView(
                    taskService.showingArchived ? "No Archived Tasks" : "No Tasks Yet",
                    systemImage: "checklist",
                    description: Text(
                        taskService.showingArchived
                            ? "Tasks you archive will appear here."
                            : "Tap + to create your first task."
                    )
                )
                Button("Add your first task") { showAddTask = true }
                    .buttonStyle(AppSecondaryButtonStyle())
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if taskService.isLoading && taskService.tasks.isEmpty {
                    ProgressView("Loading tasks…")
                } else if taskService.tasks.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            header
                            heroCard
                            quickAddCard
                            filterRow
                            searchField
                            taskGroups
                            completedSection
                        }
                        .padding(.horizontal, DesignPalette.pagePadding)
                        .padding(.top, 22)
                        .padding(.bottom, 24)
                    }
                    .searchable(text: $searchText, prompt: "Search tasks")
                }
            }
            .appBackdrop()
            .navigationTitle(taskService.showingArchived ? "Archived" : "Tasks")
            .navigationBarHidden(true)
            .safeAreaInset(edge: .bottom) {
                if let rowError {
                    HStack {
                        Text(rowError).font(.system(size: 11, weight: .medium, design: .rounded))
                        Spacer()
                        Button("Dismiss") { self.rowError = nil }
                    }
                    .padding()
                    .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, DesignPalette.pagePadding)
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
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                            Spacer()
                            Button {
                                errorDismissed = true
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                        }
                        .padding()
                        .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 14))
                        .padding()
                    }
                }
            }
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
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                if let deadline = task.deadline {
                                    Text("Missed \(deadline.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.system(size: 10, weight: .medium, design: .rounded))
                                        .foregroundStyle(DesignPalette.secondary)
                                } else if let start = task.startAt {
                                    Text("Was scheduled at \(start.formatted(date: .omitted, time: .shortened))")
                                        .font(.system(size: 10, weight: .medium, design: .rounded))
                                        .foregroundStyle(DesignPalette.secondary)
                                } else {
                                    Text("Behind schedule")
                                        .font(.system(size: 10, weight: .medium, design: .rounded))
                                        .foregroundStyle(DesignPalette.secondary)
                                }
                            }
                            Spacer()
                            Button("Reschedule") {
                                onReschedule(task)
                            }
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .foregroundStyle(DesignPalette.ink)
            .appBackdrop()
            .navigationTitle("Overdue Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DesignPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(DesignPalette.primary)
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
