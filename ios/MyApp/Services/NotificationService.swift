import Foundation
import Observation
import UIKit
import UserNotifications

enum TimeOfDay {
    static func date(from string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.date(from: string)
    }

    static func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

@MainActor
@Observable
final class NotificationService {
    enum AuthorizationStatus: Sendable {
        case unknown
        case notDetermined
        case denied
        case authorized
        case provisional
    }

    @MainActor static let shared = NotificationService()

    private(set) var preference: NotificationPreference?
    private(set) var authorizationStatus: AuthorizationStatus = .unknown
    private(set) var deviceToken: String?
    private(set) var errorMessage: String?
    private(set) var lastDeepLink: Date?

    private struct RescheduleContext {
        var tasks: [TaskItem]
        var events: [CalendarEventItem]
        var workHoursStart: Double
        var workHoursEnd: Double
        var morningMessage: String?
        var blocks: [CalendarBlock]
    }

    /// Local reminders are quiet for the whole focus session, including pauses.
    /// Keeping this as a pure predicate makes the rule testable without scheduling
    /// real notifications.
    @MainActor static func notificationsAllowed() -> Bool {
        notificationsAllowed(timerStartedAt: FocusTimerStarter.startedAt)
    }

    @MainActor static func notificationsAllowed(timerStartedAt: TimeInterval) -> Bool {
        timerStartedAt <= 0
    }

    private var lastRescheduleContext: RescheduleContext?

    private let client: APIClient
    private let deviceId: String

    private init(client: APIClient? = nil) {
        self.client = client ?? APIClient()
        self.deviceId = UIDevice.current.identifierForVendor?.uuidString
            ?? UUID().uuidString
    }

    func load() async {
        do {
            preference = try await client.request(NotificationEndpoint.getPreferences)
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshAuthorizationStatus()
        if deviceToken != nil, authorizationStatus == .authorized {
            await registerDeviceIfNeeded()
        }
    }

    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = Self.map(settings.authorizationStatus)
    }

    func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorizationStatus()
            if authorizationStatus == .authorized || authorizationStatus == .provisional {
                UIApplication.shared.registerForRemoteNotifications()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func handleDeviceToken(_ data: Data) {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        Task {
            await registerDeviceIfNeeded()
        }
    }

    func handleRegistrationFailure(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    func registerDeviceIfNeeded() async {
        guard let token = deviceToken else { return }
        do {
            _ = try await client.request(
                NotificationEndpoint.registerDevice(
                    DeviceRegisterRequest(
                        deviceId: deviceId,
                        token: token,
                        platform: "ios",
                        timezone: TimeZone.current.identifier
                    )
                )
            ) as DeviceTokenResponse
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unregisterDevice() async {
        do {
            _ = try await client.request(
                NotificationEndpoint.unregisterDevice(deviceId)
            ) as MessageResponse
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updatePreferences(_ update: NotificationPreferenceUpdate) async {
        do {
            preference = try await client.request(
                NotificationEndpoint.updatePreferences(update)
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func scheduleLocalNotifications(tasks: [TaskItem]) {
        let context = lastRescheduleContext
        scheduleAll(
            tasks: tasks,
            events: [],
            blocks: context?.blocks ?? [],
            workHoursStart: context?.workHoursStart ?? 9,
            workHoursEnd: context?.workHoursEnd ?? 17,
            hasOngoingFocus: false,
            morningMessage: context?.morningMessage
        )
    }

    func scheduleAll(
        tasks: [TaskItem],
        events: [CalendarEventItem],
        blocks: [CalendarBlock],
        workHoursStart: Double,
        workHoursEnd: Double,
        hasOngoingFocus: Bool,
        morningMessage: String?
    ) {
        lastRescheduleContext = RescheduleContext(
            tasks: tasks,
            events: events,
            workHoursStart: workHoursStart,
            workHoursEnd: workHoursEnd,
            morningMessage: morningMessage,
            blocks: blocks
        )
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        guard Self.notificationsAllowed() else { return }
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else {
            return
        }

        scheduleTaskReminders(tasks: tasks)
        scheduleGoodMorning(workHoursStart: workHoursStart, message: morningMessage)
        scheduleEventReminders(events: events)
        scheduleFocusNudges(blocks: blocks, hasOngoingFocus: hasOngoingFocus)
        scheduleBlockCompletionReminders(blocks: blocks)
        scheduleHourlyNudges(workHoursStart: workHoursStart, workHoursEnd: workHoursEnd)
    }

    /// Called when the focus timer starts or stops. Clears anything already
    /// scheduled when the session begins and rebuilds reminders once it ends.
    func syncForFocusTimer() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        guard Self.notificationsAllowed(), let context = lastRescheduleContext else { return }
        scheduleAll(
            tasks: context.tasks,
            events: context.events,
            blocks: context.blocks,
            workHoursStart: context.workHoursStart,
            workHoursEnd: context.workHoursEnd,
            hasOngoingFocus: false,
            morningMessage: context.morningMessage
        )
    }

    private func scheduleTaskReminders(tasks: [TaskItem]) {
        if let preference {
            // 15-minute before deadline reminder
            if preference.fifteenMinuteReminderEnabled {
                let now = Date()
                for task in tasks where !task.isArchived && task.status != .completed && task.deadline != nil && task.deadline! > now {
                    let deadline = task.deadline!
                    let leadDate = deadline.addingTimeInterval(-15 * 60)
                    if leadDate > now {
                        addAlert(
                            identifier: "fifteen-min-\(task.id)",
                            date: leadDate,
                            title: "Deadline reminder",
                            body: "\(task.title) is due in 15 minutes.",
                            taskId: task.id
                        )
                    }
                }
            }

            // Lead hours before deadline reminder
            if preference.deadlineReminderEnabled {
                let now = Date()
                // Collect tasks needing lead-hour reminders into an array
                var leadTasks: [TaskItem] = []
                for task in tasks where !task.isArchived && task.status != .completed && task.deadline != nil && task.deadline! > now {
                    leadTasks.append(task)
                }
                for task in leadTasks {
                    let deadline = task.deadline!
                    let leadHours = max(preference.deadlineReminderLeadHours, 1)
                    let leadDate = deadline.addingTimeInterval(-TimeInterval(leadHours) * 3600)
                    if leadDate > now {
                        addAlert(
                            identifier: "deadline-\(task.id)-lead",
                            date: leadDate,
                            title: "Deadline reminder",
                            body: "\(task.title) is due in \(leadHours)h.",
                            taskId: task.id
                        )
                    }

                    if leadHours > 1 {
                        let hourBefore = deadline.addingTimeInterval(-3600)
                        if hourBefore > now {
                            addAlert(
                                identifier: "deadline-\(task.id)-1h",
                                date: hourBefore,
                                title: "Due soon",
                                body: "\(task.title) is due in 1 hour.",
                                taskId: task.id
                            )
                        }
                    }
                }

                // Overdue reminder - use the task with the earliest deadline
                var earliestTask: TaskItem?
                var earliestDeadline: Date?
                for task in tasks where !task.isArchived && task.status != .completed && task.deadline != nil {
                    if earliestDeadline == nil || task.deadline! < earliestDeadline! {
                        earliestTask = task
                        earliestDeadline = task.deadline!
                    }
                }
                if let task = earliestTask, let deadline = earliestDeadline {
                    addAlert(
                        identifier: "overdue-\(task.id)",
                        date: deadline,
                        title: "Task overdue",
                        body: "\(task.title) is due now.",
                        taskId: task.id
                    )
                }
            }
        }
    }

    private func scheduleGoodMorning(workHoursStart: Double, message: String?) {
        guard let message, !message.isEmpty else { return }
        let calendar = Calendar.current
        let now = Date()
        let wholeHours = Int(workHoursStart)
        let minutes = Int((workHoursStart - Double(wholeHours)) * 60)
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        components.hour = min(max(wholeHours, 0), 23)
        components.minute = minutes
        guard let startOfToday = calendar.date(from: components) else { return }
        // Only fire in the future; otherwise wait until tomorrow at work start.
        var fireAt = startOfToday
        if fireAt <= now {
            fireAt = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
        }
        addAlert(
            identifier: "good-morning",
            date: fireAt,
            title: "Good morning",
            body: message,
            taskId: nil,
            url: "app://today"
        )
    }

    private func scheduleEventReminders(events: [CalendarEventItem]) {
        let now = Date()
        let horizon = now.addingTimeInterval(48 * 3600)
        for event in events where !event.isAllDay && event.start > now && event.start <= horizon {
            let fireAt = event.start.addingTimeInterval(-30 * 60)
            guard fireAt > now else { continue }
            addAlert(
                identifier: "event-\(event.id)",
                date: fireAt,
                title: "Upcoming event",
                body: "\"\(event.title)\" starts \(event.start.formatted(date: .omitted, time: .shortened)).",
                taskId: nil,
                url: "app://today"
            )
        }
    }

    private func scheduleFocusNudges(blocks: [CalendarBlock], hasOngoingFocus: Bool) {
        guard !hasOngoingFocus else { return }
        let now = Date()
        let horizon = now.addingTimeInterval(12 * 3600)
        for block in blocks where block.completedAt == nil && block.startAt > now && block.startAt <= horizon {
            addAlert(
                identifier: "focus-nudge-\(block.id)",
                date: block.startAt,
                title: "Time to focus",
                body: "\"\(block.title)\" is starting now — start your focus timer or mark it done.",
                taskId: block.taskId,
                url: "app://today"
            )
        }
    }

    private func scheduleBlockCompletionReminders(blocks: [CalendarBlock]) {
        let now = Date()
        let endFormatter = DateFormatter()
        endFormatter.timeStyle = .short
        endFormatter.dateStyle = .none
        for block in blocks where block.completedAt == nil && block.endAt > now {
            let fireAt = block.endAt.addingTimeInterval(5 * 60)
            guard fireAt > now else { continue }
            addAlert(
                identifier: "block-done-\(block.id)",
                date: fireAt,
                title: "Did you finish?",
                body: "\"\(block.title)\" ended at \(endFormatter.string(from: block.endAt)) — mark it complete if you did.",
                taskId: block.taskId,
                url: "app://today"
            )
        }
    }

    private func scheduleHourlyNudges(workHoursStart: Double, workHoursEnd: Double) {
        let startHour = min(max(Int(workHoursStart), 0), 23)
        let endHour = min(max(Int(workHoursEnd), startHour + 1), 24)
        guard endHour > startHour else { return }
        for hour in startHour..<min(endHour, 24) {
            var components = DateComponents()
            components.hour = hour
            components.minute = 0
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            let content = UNMutableNotificationContent()
            content.title = "To-do check-in"
            content.body = "How's your to-do list? Make progress on something now."
            content.sound = .default
            content.userInfo = ["url": "app://today"]
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "hourly-nudge-\(hour)", content: content, trigger: trigger)
            )
        }
    }

    func handle(_ response: UNNotificationResponse) {
        if response.notification.request.content.userInfo["url"] as? String == "app://today" {
            lastDeepLink = Date()
        }
    }

    func clearLocalState() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        preference = nil
        deviceToken = nil
    }

    // MARK: - Private

    private func addAlert(
        identifier: String,
        date: Date,
        title: String,
        body: String,
        taskId: UUID? = nil,
        url: String = "app://today"
    ) {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["url": url, "task_id": taskId?.uuidString ?? ""]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        )
    }

    private static func map(_ status: UNAuthorizationStatus) -> AuthorizationStatus {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        case .provisional:
            return .provisional
        case .ephemeral:
            return .authorized
        @unknown default:
            return .unknown
        }
    }
}

