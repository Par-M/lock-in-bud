import Foundation

struct RecommendedPart: Codable, Identifiable, Hashable, Sendable {
    let taskId: UUID
    let taskTitle: String
    let partTitle: String?
    let partIndex: Int
    let partCount: Int
    let minutes: Int
    let priority: TaskPriority
    let category: String?
    let deadline: Date?
    let isOverdue: Bool
    let reason: String
    let startAt: Date?
    let endAt: Date?

    var id: String {
        "\(taskId.uuidString)-\(partIndex)"
    }

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case taskTitle = "task_title"
        case partTitle = "part_title"
        case partIndex = "part_index"
        case partCount = "part_count"
        case minutes
        case priority
        case category
        case deadline
        case isOverdue = "is_overdue"
        case reason
        case startAt = "start_at"
        case endAt = "end_at"
    }

    var timeBlockText: String? {
        guard let startAt, let endAt else { return nil }
        return "\(startAt.formatted(date: .omitted, time: .shortened)) – "
            + endAt.formatted(date: .omitted, time: .shortened)
    }
}

struct UnscheduledPart: Codable, Identifiable, Hashable, Sendable {
    let taskId: UUID
    let taskTitle: String
    let partTitle: String?
    let minutes: Int
    let priority: TaskPriority
    let category: String?

    var id: String { "\(taskId.uuidString)-\(partTitle ?? "")" }

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case taskTitle = "task_title"
        case partTitle = "part_title"
        case minutes
        case priority
        case category
    }
}

struct DayRecommendation: Codable, Identifiable, Hashable, Sendable {
    let date: Date
    let availableMinutes: Int
    let items: [RecommendedPart]

    var id: String { date.formatted(.iso8601.year().month().day()) }

    enum CodingKeys: String, CodingKey {
        case date
        case availableMinutes = "available_minutes"
        case items
    }

    init(date: Date, availableMinutes: Int, items: [RecommendedPart]) {
        self.date = date
        self.availableMinutes = availableMinutes
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let dateString = try container.decode(String.self, forKey: .date)
        // The backend sends a bare "YYYY-MM-DD" marking a CALENDAR day. The
        // shared ISO decoder anchors that to UTC midnight, which lands on the
        // previous local day west of UTC and breaks same-day matching. Anchor
        // to local midnight instead.
        if let localDate = Self.localCalendarDate(from: dateString) {
            self.date = localDate
        } else if let parsed = JSONCoding.parseISO8601(dateString) {
            self.date = parsed
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .date,
                in: container,
                debugDescription: "Unparseable date: \(dateString)"
            )
        }
        self.availableMinutes = try container.decode(
            Int.self, forKey: .availableMinutes
        )
        self.items = try container.decode(
            [RecommendedPart].self, forKey: .items
        )
    }

    private static func localCalendarDate(from dateString: String) -> Date? {
        let parts = dateString.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else { return nil }
        return Calendar.current.date(
            from: DateComponents(year: year, month: month, day: day)
        )
    }
}

struct DailyRecommendationsResponse: Codable, Sendable {
    let days: [DayRecommendation]
    let unscheduled: [UnscheduledPart]
}

struct DailyRecommendationsRequest: Encodable, Sendable {
    let timezone: String
    let startDate: Date?
    let endDate: Date?
    var busyTimes: [BusyTimeRequest]

    enum CodingKeys: String, CodingKey {
        case timezone
        case startDate = "start_date"
        case endDate = "end_date"
        case busyTimes = "busy_times"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timezone, forKey: .timezone)
        try container.encodeIfPresent(startDate.map { JSONCoding.calendarDay($0, timezone: timezone) }, forKey: .startDate)
        try container.encodeIfPresent(endDate.map { JSONCoding.calendarDay($0, timezone: timezone) }, forKey: .endDate)
        try container.encode(busyTimes, forKey: .busyTimes)
    }
}
