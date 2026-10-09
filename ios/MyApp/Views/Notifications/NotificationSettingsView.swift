import SwiftUI
import UIKit

struct NotificationSettingsView: View {
    @Environment(NotificationService.self) private var notificationService
    @Environment(TaskService.self) private var taskService

    @State private var briefingEnabled = true
    @State private var briefingTime: Date
    @State private var deadlineEnabled = true
    @State private var leadHours = 24
    @State private var overdueEnabled = true
    @State private var rescheduleEnabled = true
    @State private var fifteenMinuteReminderEnabled = true
    @State private var fifteenMinuteReminderLeadMinutes = 15
    @State private var didLoad = false
    @State private var saved = false
    @State private var saveError: String?

    init() {
        let calendar = Calendar.current
        _briefingTime = State(
            initialValue: calendar.date(bySettingHour: 7, minute: 30, second: 0, of: Date())
                ?? Date()
        )
    }

    var body: some View {
        Form {
            Section {
                permissionRow
            } header: {
                Text("Permission")
            }

            Section {
                Toggle("Daily briefing", isOn: $briefingEnabled)
                if briefingEnabled {
                    DatePicker(
                        "Briefing time",
                        selection: $briefingTime,
                        displayedComponents: .hourAndMinute
                    )
                }
            } header: {
                Text("Morning Briefing")
            }

            Section {
                Toggle("Deadline reminders", isOn: $deadlineEnabled)
                if deadlineEnabled {
                    Stepper(
                        "Remind \(leadHours) hour\(leadHours == 1 ? "" : "s") before",
                        value: $leadHours,
                        in: 1...168
                    )
                }
            } header: {
                Text("Deadline Reminders")
            }

            Section {
                Toggle("Overdue alerts", isOn: $overdueEnabled)
                Toggle("Schedule change alerts", isOn: $rescheduleEnabled)
            } header: {
                Text("Alerts")
            }

            Section {
                Button("Save") {
                    save()
                }
                .disabled(!didLoad)
                if saved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if let saveError {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadInitial() }
    }

    @ViewBuilder
    private var permissionRow: some View {
        switch notificationService.authorizationStatus {
        case .authorized, .provisional:
            Label("Notifications enabled", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .denied:
            HStack {
                Label("Notifications disabled", systemImage: "bell.slash")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        case .unknown:
            ProgressView()
                .task {
                    await notificationService.refreshAuthorizationStatus()
                }
        default:
            Button {
                Task { await notificationService.requestPermission() }
            } label: {
                Label("Enable notifications", systemImage: "bell.badge")
            }
        }
    }

    private func loadInitial() async {
        if notificationService.preference == nil {
            await notificationService.load()
        }
        guard let preference = notificationService.preference else { return }
        briefingEnabled = preference.morningBriefingEnabled
        if let time = TimeOfDay.date(from: preference.morningBriefingTime) {
            briefingTime = time
        }
        deadlineEnabled = preference.deadlineReminderEnabled
        leadHours = max(preference.deadlineReminderLeadHours, 1)
        overdueEnabled = preference.overdueAlertsEnabled
        rescheduleEnabled = preference.rescheduleAlertsEnabled
        fifteenMinuteReminderEnabled = preference.fifteenMinuteReminderEnabled
        fifteenMinuteReminderLeadMinutes = preference.fifteenMinuteReminderLeadMinutes
        didLoad = true
    }

    private func save() {
        saved = false
        saveError = nil
        let update = NotificationPreferenceUpdate(
            morningBriefingEnabled: briefingEnabled,
            morningBriefingTime: TimeOfDay.string(from: briefingTime),
            deadlineReminderEnabled: deadlineEnabled,
            deadlineReminderLeadHours: leadHours,
            overdueAlertsEnabled: overdueEnabled,
            fifteenMinuteReminderEnabled: fifteenMinuteReminderEnabled,
            fifteenMinuteReminderLeadMinutes: fifteenMinuteReminderLeadMinutes,
            rescheduleAlertsEnabled: rescheduleEnabled
        )
        Task {
            await notificationService.updatePreferences(update)
            if notificationService.errorMessage == nil {
                saved = true
                notificationService.scheduleLocalNotifications(tasks: taskService.tasks)
            } else {
                saveError = notificationService.errorMessage
            }
        }
    }
}

#Preview {
    NavigationStack {
        NotificationSettingsView()
            .environment(NotificationService.shared)
            .environment(TaskService())
    }
}
