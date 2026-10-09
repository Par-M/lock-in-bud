import Foundation

enum TaskPriority: String, Codable, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
}

enum TaskStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pending: "Pending"
        case .inProgress: "In Progress"
        case .completed: "Completed"
        }
    }
}

enum TaskProductivity: String, Codable, CaseIterable, Identifiable, Sendable {
    case fast
    case moderate
    case slow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fast: "Fast"
        case .moderate: "Moderate"
        case .slow: "Slow"
        }
    }
}

struct ChecklistItem: Codable, Hashable, Sendable {
    var text: String
    var done: Bool

    init(text: String, done: Bool = false) {
        self.text = text
        self.done = done
    }
}

/// A time override and/or completion marker for a single occurrence of a
/// repeating task. An occurrence may carry a time override, a per-date
/// completion marker, or both.
struct RepeatOverride: Codable, Hashable, Sendable {
    var startAt: Date?
    var endAt: Date?
    var completed: Bool? = nil

    private enum CodingKeys: String, CodingKey {
        case startAt = "start_at"
        case endAt = "end_at"
        case completed
    }
}

enum OccurrenceScope: String, Sendable {
    case thisEventOnly = "this_event_only"
    case fromNowOnwards = "from_now_onwards"
}

/// Formats dates into the `yyyy-MM-dd` keys used by the backend's
/// `repeat_overrides` map. Uses the device's calendar day so an override lines
/// up with the occurrence the user tapped, regardless of UTC offset.
enum OccurrenceDateKey {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func key(for date: Date) -> String {
        formatter.string(from: date)
    }

    static func date(for key: String) -> Date? {
        guard let date = formatter.date(from: key), self.key(for: date) == key else { return nil }
        return date
    }
}

struct TaskItem: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let userId: UUID
    var title: String
    var description: String?
    var deadline: Date?
    var startAt: Date?
    var endAt: Date?
    var priority: TaskPriority
    var status: TaskStatus
    var estimatedDuration: Int?
    var actualDuration: Int?
    var productivity: TaskProductivity?
    var startedAt: Date?
    var completedAt: Date?
    var category: String?
    var notes: String?
    var checklist: [ChecklistItem]?
    var repeatWeekdays: [Int]?
    var repeatEndsOn: Date?
    var repeatOverrides: [String: RepeatOverride]? = nil
    var beforeTaskIds: [UUID]?
    var afterTaskIds: [UUID]?
    var isArchived: Bool
    var progressPercent: Int
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case title
        case description
        case deadline
        case startAt = "start_at"
        case endAt = "end_at"
        case priority
        case status
        case estimatedDuration = "estimated_duration"
        case actualDuration = "actual_duration"
        case productivity
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case category
        case notes
        case checklist
        case repeatWeekdays = "repeat_weekdays"
        case repeatEndsOn = "repeat_ends_on"
        case repeatOverrides = "repeat_overrides"
        case beforeTaskIds = "before_task_ids"
        case afterTaskIds = "after_task_ids"
        case isArchived = "is_archived"
        case progressPercent = "progress_percent"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct TaskListResponse: Codable, Sendable {
    let items: [TaskItem]
    let total: Int
}

struct TaskParseRequest: Encodable, Sendable {
    let text: String
    let timezone: String
}

struct TaskCreateRequest: Codable, Sendable {
    let title: String
    let description: String?
    let deadline: Date?
    let startAt: Date?
    let endAt: Date?
    let priority: TaskPriority
    let status: TaskStatus
    let estimatedDuration: Int?
    let category: String?
    let notes: String?
    let checklist: [ChecklistItem]?
    let repeatWeekdays: [Int]?
    let repeatEndsOn: Date?
    let beforeTaskIds: [UUID]?
    let afterTaskIds: [UUID]?

    init(
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
    ) {
        self.title = title
        self.description = description
        self.deadline = deadline
        self.startAt = startAt
        self.endAt = endAt
        self.priority = priority
        self.status = status
        self.estimatedDuration = estimatedDuration
        self.category = category
        self.notes = notes
        self.checklist = checklist
        self.repeatWeekdays = repeatWeekdays
        self.beforeTaskIds = beforeTaskIds
        self.afterTaskIds = afterTaskIds
        self.repeatEndsOn = repeatEndsOn
    }

    init(from local: LocalTask) {
        title = local.title
        description = local.taskDescription
        deadline = local.deadline
        startAt = local.startAt
        endAt = local.endAt
        priority = TaskPriority(rawValue: local.priorityRaw) ?? .medium
        status = TaskStatus(rawValue: local.statusRaw) ?? .pending
        estimatedDuration = local.estimatedDuration
        category = local.category
        notes = local.notes
        checklist = local.checklist
        repeatWeekdays = local.repeatWeekdays
        beforeTaskIds = local.beforeTaskIds
        afterTaskIds = local.afterTaskIds
        repeatEndsOn = local.repeatEndsOn
    }

    enum CodingKeys: String, CodingKey {
        case title
        case description
        case deadline
        case startAt = "start_at"
        case endAt = "end_at"
        case priority
        case status
        case estimatedDuration = "estimated_duration"
        case category
        case notes
        case checklist
        case repeatWeekdays = "repeat_weekdays"
        case repeatEndsOn = "repeat_ends_on"
        case beforeTaskIds = "before_task_ids"
        case afterTaskIds = "after_task_ids"
    }
}

struct TaskUpdateRequest: Encodable, Sendable {
    let title: String
    let description: String?
    let deadline: Date?
    let startAt: Date?
    let endAt: Date?
    let priority: TaskPriority
    let status: TaskStatus
    let estimatedDuration: Int?
    let actualDuration: Int?
    let category: String?
    let notes: String?
    let checklist: [ChecklistItem]?
    let repeatWeekdays: [Int]?
    let repeatEndsOn: Date?
    let repeatOverrides: [String: RepeatOverride]?
    let beforeTaskIds: [UUID]?
    let afterTaskIds: [UUID]?

    init(task: TaskItem) {
        title = task.title
        description = task.description
        deadline = task.deadline
        startAt = task.startAt
        endAt = task.endAt
        priority = task.priority
        status = task.status
        estimatedDuration = task.estimatedDuration
        actualDuration = task.actualDuration
        category = task.category
        notes = task.notes
        checklist = task.checklist
        repeatWeekdays = task.repeatWeekdays
        repeatEndsOn = task.repeatEndsOn
        repeatOverrides = task.repeatOverrides
        beforeTaskIds = task.beforeTaskIds
        afterTaskIds = task.afterTaskIds
    }

    init(from local: LocalTask) {
        title = local.title
        description = local.taskDescription
        deadline = local.deadline
        startAt = local.startAt
        endAt = local.endAt
        priority = TaskPriority(rawValue: local.priorityRaw) ?? .medium
        status = TaskStatus(rawValue: local.statusRaw) ?? .pending
        estimatedDuration = local.estimatedDuration
        actualDuration = local.actualDuration
        category = local.category
        notes = local.notes
        checklist = local.checklist
        repeatWeekdays = local.repeatWeekdays
        repeatEndsOn = local.repeatEndsOn
        repeatOverrides = local.repeatOverridesData.flatMap {
            try? JSONCoding.decoder.decode(
                [String: RepeatOverride].self,
                from: $0
            )
        }
        beforeTaskIds = local.beforeTaskIds
        afterTaskIds = local.afterTaskIds
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(description, forKey: .description)
        try container.encode(deadline, forKey: .deadline)
        try container.encode(startAt, forKey: .startAt)
        try container.encode(endAt, forKey: .endAt)
        try container.encode(priority, forKey: .priority)
        try container.encode(status, forKey: .status)
        try container.encode(estimatedDuration, forKey: .estimatedDuration)
        try container.encode(actualDuration, forKey: .actualDuration)
        try container.encode(category, forKey: .category)
        try container.encode(notes, forKey: .notes)
        try container.encode(checklist, forKey: .checklist)
        try container.encode(repeatWeekdays, forKey: .repeatWeekdays)
        try container.encode(repeatEndsOn, forKey: .repeatEndsOn)
        try container.encodeIfPresent(repeatOverrides, forKey: .repeatOverrides)
        try container.encodeIfPresent(beforeTaskIds, forKey: .beforeTaskIds)
        try container.encodeIfPresent(afterTaskIds, forKey: .afterTaskIds)
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case description
        case deadline
        case startAt = "start_at"
        case endAt = "end_at"
        case priority
        case status
        case estimatedDuration = "estimated_duration"
        case actualDuration = "actual_duration"
        case category
        case notes
        case checklist
        case repeatWeekdays = "repeat_weekdays"
        case repeatEndsOn = "repeat_ends_on"
        case repeatOverrides = "repeat_overrides"
        case beforeTaskIds = "before_task_ids"
        case afterTaskIds = "after_task_ids"
    }
}

struct CompleteTaskRequest: Encodable, Sendable {
    let actualMinutes: Int?
    let productivity: TaskProductivity?
    let occurrenceDate: String?
    let timezone: String?

    private enum CodingKeys: String, CodingKey {
        case actualMinutes = "actual_minutes"
        case productivity
        case occurrenceDate = "occurrence_date"
        case timezone
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(actualMinutes, forKey: .actualMinutes)
        try container.encodeIfPresent(productivity, forKey: .productivity)
        try container.encodeIfPresent(occurrenceDate, forKey: .occurrenceDate)
        try container.encodeIfPresent(timezone, forKey: .timezone)
    }
}

struct RecordTimeRequest: Encodable, Sendable {
    let minutes: Int
}

struct RescheduleRequest: Encodable, Sendable {
    let minutesRemaining: Int
    let reason: String?
    let timezone: String
    let deadline: Date?

    private enum CodingKeys: String, CodingKey {
        case minutesRemaining = "minutes_remaining"
        case reason
        case timezone
        case deadline
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(minutesRemaining, forKey: .minutesRemaining)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encode(timezone, forKey: .timezone)
        try container.encodeIfPresent(deadline, forKey: .deadline)
    }
}

struct RescheduleResponse: Codable, Sendable {
    let task: TaskItem
    let blocks: [CalendarBlock]
}

struct OccurrenceUpdateRequest: Encodable, Sendable {
    let date: String
    let scope: String
    let startAt: Date
    let endAt: Date
    let timezone: String

    private enum CodingKeys: String, CodingKey {
        case date
        case scope
        case startAt = "start_at"
        case endAt = "end_at"
        case timezone
    }
}

struct OccurrenceCompletionRequest: Encodable, Sendable {
    let date: String
    let completed: Bool
    let timezone: String

    private enum CodingKeys: String, CodingKey {
        case date
        case completed
        case timezone
    }
}

struct OccurrenceUpdateResponse: Codable, Sendable {
    let task: TaskItem
    let newTask: TaskItem?

    private enum CodingKeys: String, CodingKey {
        case task
        case newTask = "new_task"
    }
}
