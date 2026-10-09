import Foundation
import Observation
import WidgetKit

@MainActor
@Observable
final class TaskService {
    enum SortOption: String, CaseIterable, Identifiable {
        case created = "created_at"
        case deadline = "deadline"
        case priority = "priority"
        case updated = "updated_at"
        case category = "category"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .created: "Created Date"
            case .deadline: "Deadline"
            case .priority: "Priority"
            case .updated: "Last Updated"
            case .category: "Category"
            }
        }
    }

    private(set) var tasks: [TaskItem] = []
    private(set) var overdueTasks: [TaskItem] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var dataVersion = 0 {
        didSet { refreshWidgetTasks() }
    }
    private(set) var isOfflineMode = false

    var showingArchived = false

    private let client: APIClient
    private let store: LocalStore?
    private let connectivity: ConnectivityMonitor

    init(
        client: APIClient? = nil,
        store: LocalStore? = nil,
        connectivity: ConnectivityMonitor? = nil
    ) {
        self.client = client ?? APIClient()
        self.store = store
        self.connectivity = connectivity ?? ConnectivityMonitor()
    }

    func loadTasks(
        search: String? = nil,
        priority: TaskPriority? = nil,
        status: TaskStatus? = nil,
        category: String? = nil,
        sort: SortOption? = nil,
        order: String = "asc"
    ) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let response: TaskListResponse = try await client.request(
                TaskEndpoint.list(
                    search: search,
                    priority: priority,
                    status: status,
                    category: category,
                    archived: showingArchived,
                    sort: sort?.rawValue,
                    order: order
                )
            )
            tasks = response.items
            store?.upsertServerTasks(response.items)
            isOfflineMode = false
            refreshWidgetTasks()
        } catch {
            if let store, isNetworkUnavailable(error) || !connectivity.isConnected {
                tasks = store.tasks()
                isOfflineMode = true
                errorMessage = "Offline — showing saved tasks. Changes will sync when you're back online."
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    func setShowingArchived(_ archived: Bool) {
        showingArchived = archived
    }

    func createTask(
        title: String,
        description: String?,
        deadline: Date?,
        startAt: Date?,
        endAt: Date?,
        priority: TaskPriority,
        status: TaskStatus,
        estimatedDuration: Int?,
        category: String?,
        notes: String?,
        repeatWeekdays: [Int]?,
        beforeTaskIds: [UUID]? = nil,
        afterTaskIds: [UUID]? = nil,
        repeatEndsOn: Date? = nil,
        checklist: [ChecklistItem]? = nil
    ) async throws -> TaskItem {
        guard let userID = client.userID else { throw NetworkError.unauthorized }
        let request = TaskCreateRequest(
            title: title,
            description: description,
            deadline: deadline,
            startAt: startAt,
            endAt: endAt,
            priority: priority,
            status: status,
            estimatedDuration: estimatedDuration,
            category: category,
            notes: notes,
            repeatWeekdays: repeatWeekdays,
            beforeTaskIds: beforeTaskIds,
            afterTaskIds: afterTaskIds,
            repeatEndsOn: repeatEndsOn,
            checklist: checklist
        )

        if !connectivity.isConnected, let store {
            let now = Date()
            let local = TaskItem(
                id: UUID(),
                userId: userID,
                title: request.title,
                description: request.description,
                deadline: request.deadline,
                startAt: request.startAt,
                endAt: request.endAt,
                priority: request.priority,
                status: request.status,
                estimatedDuration: request.estimatedDuration,
                actualDuration: nil,
                productivity: nil,
                startedAt: nil,
                completedAt: nil,
                category: request.category,
                notes: request.notes,
                checklist: request.checklist,
                repeatWeekdays: request.repeatWeekdays,
                repeatEndsOn: request.repeatEndsOn,
                beforeTaskIds: request.beforeTaskIds,
                afterTaskIds: request.afterTaskIds,
                isArchived: false,
                progressPercent: 0,
                createdAt: now,
                updatedAt: now
            )
            store.upsert(local, dirty: true)
            tasks.insert(local, at: 0)
            isOfflineMode = true
            dataVersion += 1
            return local
        }

        do {
            let created: TaskItem = try await client.request(TaskEndpoint.create(request))
            store?.upsert(created)
            tasks.insert(created, at: 0)
            isOfflineMode = false
            dataVersion += 1
            return created
        } catch {
            if let store, isNetworkUnavailable(error) {
                guard client.userID == userID else { throw NetworkError.unauthorized }
                let now = Date()
                let local = TaskItem(
                    id: UUID(),
                    userId: userID,
                    title: request.title,
                    description: request.description,
                    deadline: request.deadline,
                    startAt: request.startAt,
                    endAt: request.endAt,
                    priority: request.priority,
                    status: request.status,
                    estimatedDuration: request.estimatedDuration,
                    actualDuration: nil,
                    productivity: nil,
                    startedAt: nil,
                    completedAt: nil,
                    category: request.category,
                    notes: request.notes,
                    repeatWeekdays: request.repeatWeekdays,
                    beforeTaskIds: request.beforeTaskIds,
                    afterTaskIds: request.afterTaskIds,
                    isArchived: false,
                    progressPercent: 0,
                    createdAt: now,
                    updatedAt: now
                )
                store.upsert(local, dirty: true)
                tasks.insert(local, at: 0)
                isOfflineMode = true
                dataVersion += 1
                return local
            }
            throw error
        }
    }

    /// Parse a natural-language text string locally and create the task.
    func quickAdd(text: String) async throws -> TaskItem {
        let parsed = TaskNaturalLanguageParser.parse(text)
        return try await createTask(
            title: parsed.title,
            description: nil,
            deadline: parsed.deadline,
            startAt: nil,
            endAt: nil,
            priority: parsed.priority,
            status: .pending,
            estimatedDuration: parsed.estimatedDuration,
            category: parsed.category,
            notes: nil,
            repeatWeekdays: nil
        )
    }

    func updateTask(_ task: TaskItem) async throws -> TaskItem {
        if !connectivity.isConnected, let store {
            let local = bump(task)
            store.upsert(local, dirty: true)
            replace(local)
            isOfflineMode = true
            dataVersion += 1
            return local
        }

        do {
            let updated: TaskItem = try await client.request(
                TaskEndpoint.update(id: task.id, request: TaskUpdateRequest(task: task))
            )
            store?.upsert(updated)
            replace(updated)
            isOfflineMode = false
            dataVersion += 1
            return updated
        } catch {
            if let store, isNetworkUnavailable(error) {
                let local = bump(task)
                store.upsert(local, dirty: true)
                replace(local)
                isOfflineMode = true
                dataVersion += 1
                return local
            }
            throw error
        }
    }

    func setStatus(_ status: TaskStatus, for task: TaskItem) async throws -> TaskItem {
        if status == task.status {
            return task
        }
        switch status {
        case .pending:
            var updated = task
            updated.status = .pending
            return try await updateTask(updated)
        case .inProgress:
            if task.status == .completed {
                var updated = task
                updated.status = .inProgress
                return try await updateTask(updated)
            }
            return try await startTask(id: task.id)
        case .completed:
            return try await completeTask(id: task.id, minutes: nil, productivity: task.productivity)
        }
    }

    func deleteTask(_ task: TaskItem) async throws {        if !connectivity.isConnected, let store {
            store.markDeleted(taskId: task.id)
            isOfflineMode = true
        } else {
            do {
                _ = try await client.request(TaskEndpoint.delete(task.id)) as MessageResponse
                store?.purgeTask(id: task.id)
                isOfflineMode = false
            } catch NetworkError.httpStatus(404) {
                store?.purgeTask(id: task.id)
                isOfflineMode = false
            } catch {
                if let store, isNetworkUnavailable(error) {
                    store.markDeleted(taskId: task.id)
                    isOfflineMode = true
                } else {
                    throw error
                }
            }
        }
        tasks.removeAll { $0.id == task.id }
        dataVersion += 1
    }

    func archiveTask(_ task: TaskItem) async throws -> TaskItem {
        try await toggleArchived(task, archived: true)
    }

    func restoreTask(_ task: TaskItem) async throws -> TaskItem {
        try await toggleArchived(task, archived: false)
    }

    private func toggleArchived(_ task: TaskItem, archived: Bool) async throws -> TaskItem {
        var updated = task
        updated.isArchived = archived

        if !connectivity.isConnected, let store {
            let local = bump(updated)
            store.upsert(local, dirty: true)
            replace(local)
            isOfflineMode = true
            dataVersion += 1
            return local
        }

        do {
            let server: TaskItem = try await client.request(
                archived ? TaskEndpoint.archive(task.id) : TaskEndpoint.restore(task.id)
            )
            store?.upsert(server)
            replace(server)
            isOfflineMode = false
            dataVersion += 1
            return server
        } catch {
            if let store, isNetworkUnavailable(error) {
                let local = bump(updated)
                store.upsert(local, dirty: true)
                replace(local)
                isOfflineMode = true
                dataVersion += 1
                return local
            }
            throw error
        }
    }

    func startTask(id: UUID) async throws -> TaskItem {
        if !connectivity.isConnected, let store, let current = tasks.first(where: { $0.id == id }) {
            var updated = current
            updated.status = .inProgress
            updated.startedAt = Date()
            let local = bump(updated)
            store.upsert(local, dirty: true)
            replace(local)
            isOfflineMode = true
            dataVersion += 1
            return local
        }

        do {
            let updated: TaskItem = try await client.request(TaskEndpoint.start(id))
            store?.upsert(updated)
            replace(updated)
            isOfflineMode = false
            dataVersion += 1
            return updated
        } catch {
            if let store, isNetworkUnavailable(error), let current = tasks.first(where: { $0.id == id }) {
                var updated = current
                updated.status = .inProgress
                updated.startedAt = Date()
                let local = bump(updated)
                store.upsert(local, dirty: true)
                replace(local)
                isOfflineMode = true
                dataVersion += 1
                return local
            }
            throw error
        }
    }

    func completeTask(
        id: UUID,
        minutes: Int?,
        productivity: TaskProductivity? = nil,
        occurrenceDate: Date? = nil
    ) async throws -> TaskItem {
        let current = tasks.first(where: { $0.id == id })
        let isRepeating = !((current?.repeatWeekdays ?? []).isEmpty)
        let completionDate = occurrenceDate ?? Date()

        if !connectivity.isConnected, let store, let current {
            let local = bump(
                completeLocally(
                    current,
                    minutes: minutes,
                    productivity: productivity,
                    occurrenceDate: completionDate
                )
            )
            store.upsert(local, dirty: true)
            replace(local)
            isOfflineMode = true
            dataVersion += 1
            return local
        }

        do {
            let updated: TaskItem = try await client.request(
                TaskEndpoint.complete(
                    id: id,
                    minutes: minutes,
                    productivity: productivity,
                    occurrenceDate: isRepeating ? OccurrenceDateKey.key(for: completionDate) : nil,
                    timezone: TimeZone.current.identifier
                )
            )
            store?.upsert(updated)
            replace(updated)
            isOfflineMode = false
            dataVersion += 1
            return updated
        } catch {
            if let store, isNetworkUnavailable(error), let current {
                let local = bump(
                    completeLocally(
                        current,
                        minutes: minutes,
                        productivity: productivity,
                        occurrenceDate: completionDate
                    )
                )
                store.upsert(local, dirty: true)
                replace(local)
                isOfflineMode = true
                dataVersion += 1
                return local
            }
            throw error
        }
    }

    private func completeLocally(
        _ current: TaskItem,
        minutes: Int?,
        productivity: TaskProductivity?,
        occurrenceDate: Date
    ) -> TaskItem {
        var updated = current
        if !((current.repeatWeekdays ?? []).isEmpty) {
            // Complete this occurrence only so the repeated series keeps going.
            // The backend picks this up on the next sync.
            var overrides = updated.repeatOverrides ?? [:]
            let key = OccurrenceDateKey.key(for: occurrenceDate)
            var entry = overrides[key] ?? RepeatOverride(startAt: nil, endAt: nil)
            entry.completed = true
            overrides[key] = entry
            updated.repeatOverrides = overrides
        } else {
            updated.status = .completed
            updated.completedAt = Date()
            updated.productivity = productivity
            if let minutes {
                updated.actualDuration = minutes
            }
        }
        return updated
    }

    /// Mark a task shown in the calendar as done for the tapped day.
    ///
    /// A repeating task records a per-occurrence completion so the rest of the
    /// series keeps running; a one-off task is completed as a whole.
    func completeOccurrence(_ task: TaskItem, on date: Date) async throws -> TaskItem {
        try await completeTask(
            id: task.id,
            minutes: nil,
            productivity: task.productivity,
            occurrenceDate: date
        )
    }

    /// Reopen a single occurrence of a repeating task so it stops showing as
    /// completed in the calendar. Hits the occurrence-completion endpoint so
    /// the server clears both the override marker and that day's block.
    func reopenOccurrence(
        _ task: TaskItem,
        on date: Date
    ) async throws -> TaskItem {
        if !connectivity.isConnected, let store {
            let local = bump(reopenOccurrenceLocally(task, on: date))
            store.upsert(local, dirty: true)
            replace(local)
            isOfflineMode = true
            dataVersion += 1
            return local
        }

        do {
            let updated: TaskItem = try await client.request(
                TaskEndpoint.occurrenceCompletion(
                    id: task.id,
                    request: OccurrenceCompletionRequest(
                        date: OccurrenceDateKey.key(for: date),
                        completed: false,
                        timezone: TimeZone.current.identifier
                    )
                )
            )
            store?.upsert(updated)
            replace(updated)
            isOfflineMode = false
            dataVersion += 1
            return updated
        } catch {
            if let store, isNetworkUnavailable(error) {
                let local = bump(reopenOccurrenceLocally(task, on: date))
                store.upsert(local, dirty: true)
                replace(local)
                isOfflineMode = true
                dataVersion += 1
                return local
            }
            throw error
        }
    }

    private func reopenOccurrenceLocally(
        _ current: TaskItem,
        on date: Date
    ) -> TaskItem {
        var updated = current
        var overrides = updated.repeatOverrides ?? [:]
        let key = OccurrenceDateKey.key(for: date)
        var entry = overrides[key] ?? RepeatOverride(startAt: nil, endAt: nil)
        entry.completed = false
        overrides[key] = entry
        updated.repeatOverrides = overrides
        return updated
    }

    func recordTime(id: UUID, minutes: Int) async throws -> TaskItem {
        if !connectivity.isConnected, let store, let current = tasks.first(where: { $0.id == id }) {
            var updated = current
            updated.actualDuration = (updated.actualDuration ?? 0) + minutes
            let local = bump(updated)
            store.upsert(local, dirty: true)
            replace(local)
            isOfflineMode = true
            dataVersion += 1
            return local
        }

        do {
            let updated: TaskItem = try await client.request(
                TaskEndpoint.recordTime(id: id, minutes: minutes)
            )
            store?.upsert(updated)
            replace(updated)
            isOfflineMode = false
            dataVersion += 1
            return updated
        } catch {
            if let store, isNetworkUnavailable(error), let current = tasks.first(where: { $0.id == id }) {
                var updated = current
                updated.actualDuration = (updated.actualDuration ?? 0) + minutes
                let local = bump(updated)
                store.upsert(local, dirty: true)
                replace(local)
                isOfflineMode = true
                dataVersion += 1
                return local
            }
            throw error
        }
    }

    func setCompletedMinutes(id: UUID, minutes: Int) async throws -> TaskItem {
        guard let current = tasks.first(where: { $0.id == id }) else {
            throw NetworkError.httpStatus(404)
        }
        var updated = current
        updated.actualDuration = max(0, minutes)
        return try await updateTask(updated)
    }

    func presentError(_ message: String) {
        errorMessage = message
    }

    func loadOverdue() async {
        do {
            let response: TaskListResponse = try await client.request(TaskEndpoint.overdue)
            overdueTasks = response.items
            isOfflineMode = false
        } catch {
            if isNetworkUnavailable(error) {
                isOfflineMode = true
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    func rescheduleTask(
        _ task: TaskItem,
        minutesRemaining: Int,
        deadline: Date?,
        reason: String?
    ) async throws -> RescheduleResponse {
        let response: RescheduleResponse = try await client.request(
            TaskEndpoint.reschedule(
                id: task.id,
                minutes: minutesRemaining,
                reason: reason,
                timezone: TimeZone.current.identifier,
                deadline: deadline
            )
        )
        store?.upsert(response.task)
        replace(response.task)
        overdueTasks.removeAll { $0.id == task.id }
        store?.upsertServerBlocks(response.blocks)
        isOfflineMode = false
        dataVersion += 1
        return response
    }

    func updateOccurrence(
        _ task: TaskItem,
        date: Date,
        scope: OccurrenceScope,
        startAt: Date,
        endAt: Date
    ) async throws -> OccurrenceUpdateResponse {
        let request = OccurrenceUpdateRequest(
            date: OccurrenceDateKey.key(for: date),
            scope: scope.rawValue,
            startAt: startAt,
            endAt: endAt,
            timezone: TimeZone.current.identifier
        )
        let response: OccurrenceUpdateResponse = try await client.request(
            TaskEndpoint.occurrence(id: task.id, request: request)
        )
        store?.upsert(response.task)
        replace(response.task)
        if let newTask = response.newTask {
            store?.upsert(newTask)
            replace(newTask)
        }
        isOfflineMode = false
        dataVersion += 1
        return response
    }

    private func bump(_ task: TaskItem) -> TaskItem {
        var updated = task
        updated.updatedAt = Date()
        return updated
    }

    private func replace(_ task: TaskItem) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else {
            tasks.insert(task, at: 0)
            return
        }
        tasks[index] = task
    }

    private func refreshWidgetTasks() {
        let active = tasks.filter { $0.status != .completed && !$0.isArchived }
        let rank: [TaskPriority: Int] = [.high: 0, .medium: 1, .low: 2]
        let ranked = active.sorted {
            (rank[$0.priority] ?? 1) < (rank[$1.priority] ?? 1)
        }
        let topTitles = Array(ranked.prefix(15).map(\.title))
        let existing = WidgetDataStore.read()
        WidgetDataStore.write(
            currentTaskTitle: ranked.first?.title,
            nextTaskTitle: ranked.dropFirst().first?.title,
            tasksRemaining: active.count,
            habitsRemaining: existing.habitsRemaining,
            topTaskTitles: topTitles,
            habitTitles: existing.habitTitles
        )
        WidgetCenter.shared.reloadTimelines(ofKind: "CurrentTaskWidget")
        WidgetCenter.shared.reloadTimelines(ofKind: "TasksRemainingWidget")
    }
}
