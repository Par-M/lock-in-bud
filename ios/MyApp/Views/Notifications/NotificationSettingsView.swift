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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                AppHeader(eyebrow: "NOTIFICATIONS", title: "Stay on time.")

                settingSection("PERMISSION") {
                    permissionRow
                }

                settingSection("MORNING BRIEFING") {
                    Toggle("Daily briefing", isOn: $briefingEnabled)
                        .font(DesignPalette.body(14))
                        .tint(DesignPalette.primary)
                    if briefingEnabled {
                        Divider().background(DesignPalette.cream)
                        DatePicker(
                            "Briefing time",
                            selection: $briefingTime,
                            displayedComponents: .hourAndMinute
                        )
                        .font(DesignPalette.body(14))
                        .tint(DesignPalette.primary)
                    }
                }

                settingSection("DEADLINE REMINDERS") {
                    Toggle("Deadline reminders", isOn: $deadlineEnabled)
                        .font(DesignPalette.body(14))
                        .tint(DesignPalette.primary)
                    if deadlineEnabled {
                        Divider().background(DesignPalette.cream)
                        Stepper(
                            "Remind \(leadHours) hour\(leadHours == 1 ? "" : "s") before",
                            value: $leadHours,
                            in: 1...168
                        )
                        .font(DesignPalette.body(14))
                        .tint(DesignPalette.primary)
                    }
                }

                settingSection("ALERTS") {
                    Toggle("Overdue alerts", isOn: $overdueEnabled)
                        .font(DesignPalette.body(14))
                        .tint(DesignPalette.primary)
                    Divider().background(DesignPalette.cream)
                    Toggle("Schedule change alerts", isOn: $rescheduleEnabled)
                        .font(DesignPalette.body(14))
                        .tint(DesignPalette.primary)
                }

                AppCard(padding: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            save()
                        } label: {
                            Text("Save")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AppPrimaryButtonStyle())
                        .disabled(!didLoad)

                        if saved {
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .font(DesignPalette.body(12))
                                .foregroundStyle(DesignPalette.primary)
                        }
                        if let saveError {
                            Text(saveError)
                                .font(DesignPalette.body(12))
                                .foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, DesignPalette.pagePadding)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .appBackdrop()
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(DesignPalette.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .tint(DesignPalette.primary)
        .task { await loadInitial() }
    }

    @ViewBuilder
    private func settingSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            AppEyebrow(text: title)
            AppCard(padding: 14) {
                content()
            }
        }
    }

    @ViewBuilder
    private var permissionRow: some View {
        switch notificationService.authorizationStatus {
        case .authorized, .provisional:
            Label("Notifications enabled", systemImage: "checkmark.circle.fill")
                .font(DesignPalette.body(14))
                .foregroundStyle(DesignPalette.primary)
        case .denied:
            HStack {
                Label("Notifications disabled", systemImage: "bell.slash")
                    .font(DesignPalette.body(14))
                    .foregroundStyle(DesignPalette.secondary)
                Spacer()
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(DesignPalette.body(12).weight(.semibold))
                .foregroundStyle(DesignPalette.primary)
                .buttonStyle(.plain)
            }
        case .unknown:
            ProgressView()
                .tint(DesignPalette.primary)
                .task {
                    await notificationService.refreshAuthorizationStatus()
                }
        default:
            Button {
                Task { await notificationService.requestPermission() }
            } label: {
                HStack {
                    Label("Enable notifications", systemImage: "bell.badge")
                        .font(DesignPalette.body(14).weight(.medium))
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
