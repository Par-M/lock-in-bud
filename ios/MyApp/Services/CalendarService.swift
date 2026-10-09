import EventKit
import Foundation
import Observation

enum CalendarPermission: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
}

struct CalendarEventItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    var occurrenceDate: Date? = nil

    static func repeatingEvents(for task: TaskItem, on day: Date) -> [CalendarEventItem] {
        let calendar = Calendar.current
        guard let start = task.startAt, let end = task.endAt else { return [] }
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let previousDay = calendar.date(byAdding: .day, value: -1, to: dayStart) ?? dayStart
        var candidates = [OccurrenceDateKey.key(for: previousDay): previousDay,
                          OccurrenceDateKey.key(for: dayStart): dayStart]
        // Overrides may move an occurrence from any original date into this day.
        for (key, override) in task.repeatOverrides ?? [:] where override.startAt != nil || override.endAt != nil {
            if let date = OccurrenceDateKey.date(for: key) { candidates[key] = date }
        }
        return candidates.compactMap { key, occurrenceDay in
            let weekday = (calendar.component(.weekday, from: occurrenceDay) - 1 + 7) % 7
            guard (task.repeatWeekdays ?? []).contains(weekday),
                  occurrenceDay >= calendar.startOfDay(for: start),
                  task.repeatEndsOn.map({ occurrenceDay <= calendar.startOfDay(for: $0) }) ?? true else { return nil }
            let interval = occurrenceInterval(start: start, end: end, on: occurrenceDay)
            let override = task.repeatOverrides?[key]
            let actualStart = override?.startAt ?? interval.start
            let actualEnd = override?.endAt ?? interval.end
            guard actualStart < dayEnd, actualEnd > dayStart else { return nil }
            return CalendarEventItem(
                id: "app-task-\(task.id.uuidString)-\(Int(occurrenceDay.timeIntervalSince1970))",
                title: task.title, start: actualStart, end: actualEnd,
                isAllDay: false, occurrenceDate: occurrenceDay
            )
        }.sorted { $0.start < $1.start }
    }

    static func occurrenceInterval(start: Date, end: Date, on day: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let startTime = calendar.dateComponents([.hour, .minute, .second], from: start)
        let endTime = calendar.dateComponents([.hour, .minute, .second], from: end)
        let dayOffset = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0
        let endDay = calendar.date(byAdding: .day, value: dayOffset, to: day) ?? day
        let occurrenceStart = calendar.date(bySettingHour: startTime.hour ?? 0, minute: startTime.minute ?? 0, second: startTime.second ?? 0, of: day) ?? day
        let occurrenceEnd = calendar.date(bySettingHour: endTime.hour ?? 0, minute: endTime.minute ?? 0, second: endTime.second ?? 0, of: endDay) ?? occurrenceStart
        return (occurrenceStart, occurrenceEnd)
    }
}

@MainActor
@Observable
final class CalendarService {
    private let store = EKEventStore()

    private static let selectedCalendarsKey = "selectedCalendarIDs"
    private static let hasSelectionKey = "hasCustomCalendarSelection"
    private static let ignoredEventsKey = "ignoredEventIDs"

    private(set) var permission: CalendarPermission

    private(set) var selectedCalendarIDs: Set<String> = []
    private(set) var hasCustomCalendarSelection = false
    private(set) var ignoredEventIDs: Set<String> = []

    init() {
        permission = Self.currentPermission()
        selectedCalendarIDs = Set(
            UserDefaults.standard.stringArray(forKey: Self.selectedCalendarsKey) ?? []
        )
        hasCustomCalendarSelection = UserDefaults.standard.bool(
            forKey: Self.hasSelectionKey
        )
        ignoredEventIDs = Set(
            UserDefaults.standard.stringArray(forKey: Self.ignoredEventsKey) ?? []
        )
    }

    var availableCalendars: [EKCalendar] {
        store.calendars(for: .event).sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    static func currentPermission() -> CalendarPermission {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized, .fullAccess:
            return .granted
        case .notDetermined:
            return .notDetermined
        default:
            return .denied
        }
    }

    @discardableResult
    func requestPermission() async -> CalendarPermission {
        do {
            let granted = try await store.requestFullAccessToEvents()
            permission = granted ? .granted : .denied
        } catch {
            permission = .denied
        }
        return permission
    }

    func isSelected(_ calendar: EKCalendar) -> Bool {
        !hasCustomCalendarSelection
            || selectedCalendarIDs.contains(calendar.calendarIdentifier)
    }

    func setCalendarSelected(_ calendar: EKCalendar, selected: Bool) {
        if !hasCustomCalendarSelection {
            selectedCalendarIDs = Set(availableCalendars.map { $0.calendarIdentifier })
            hasCustomCalendarSelection = true
        }
        if selected {
            selectedCalendarIDs.insert(calendar.calendarIdentifier)
        } else {
            selectedCalendarIDs.remove(calendar.calendarIdentifier)
        }
        UserDefaults.standard.set(
            hasCustomCalendarSelection,
            forKey: Self.hasSelectionKey
        )
        UserDefaults.standard.set(
            Array(selectedCalendarIDs),
            forKey: Self.selectedCalendarsKey
        )
    }

    func isIgnored(_ event: CalendarEventItem) -> Bool {
        ignoredEventIDs.contains(event.id)
    }

    func toggleIgnored(_ event: CalendarEventItem) {
        if ignoredEventIDs.contains(event.id) {
            ignoredEventIDs.remove(event.id)
        } else {
            ignoredEventIDs.insert(event.id)
        }
        UserDefaults.standard.set(Array(ignoredEventIDs), forKey: Self.ignoredEventsKey)
    }

    func fetchEvents(from start: Date, to end: Date) -> [CalendarEventItem] {
        let calendars: [EKCalendar]?
        if hasCustomCalendarSelection {
            let ids = selectedCalendarIDs
            calendars = availableCalendars.filter { ids.contains($0.calendarIdentifier) }
        } else {
            calendars = nil
        }
        let predicate = store.predicateForEvents(
            withStart: start,
            end: end,
            calendars: calendars
        )
        return store.events(matching: predicate).map { event in
            CalendarEventItem(
                id: event.eventIdentifier,
                title: event.title ?? "Untitled",
                start: event.startDate,
                end: event.endDate,
                isAllDay: event.isAllDay
            )
        }
    }
}
