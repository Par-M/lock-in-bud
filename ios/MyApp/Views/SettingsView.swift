import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AuthenticationService.self) private var authService
    @Environment(CalendarService.self) private var calendarService
    @Environment(NotificationService.self) private var notificationService
    @Environment(ScheduleService.self) private var scheduleService
    @Environment(TaskService.self) private var taskService
    @Environment(SyncManager.self) private var syncManager
    @Environment(CategoryStore.self) private var categoryStore
    @Environment(AppearanceSettings.self) private var appearance

    @State private var showNotificationSettings = false
    @State private var showPreferences = false
    @State private var newCategory = ""
    @State private var syncedMessage = false
    @State private var confirmSignOut = false
    @State private var categoryToRemove: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AppHeader(eyebrow: "SETTINGS", title: "Make it yours.")

                    settingsSection("ACCOUNT") {
                        accountSection
                    }

                    settingsSection("SCHEDULING") {
                        schedulingSection
                    }

                    settingsSection("CALENDAR") {
                        calendarSection
                    }

                    settingsSection("NOTIFICATIONS") {
                        notificationSection
                    }

                    settingsSection("APPEARANCE") {
                        appearanceSection
                    }

                    settingsSection("CATEGORIES") {
                        categoriesSection
                    }

                    settingsSection("PRIVACY") {
                        privacySection
                    }
                }
                .padding(.horizontal, DesignPalette.pagePadding)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .appBackdrop()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DesignPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(DesignPalette.primary)
            .confirmationDialog(
                categoryToRemove == nil ? "" : "Remove \"\(categoryToRemove!)\"?",
                isPresented: Binding(
                    get: { categoryToRemove != nil },
                    set: { if !$0 { categoryToRemove = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    if let category = categoryToRemove {
                        categoryStore.remove(category)
                    }
                    categoryToRemove = nil
                }
                Button("Cancel", role: .cancel) {
                    categoryToRemove = nil
                }
            } message: {
                Text("Tasks in this category will keep their label but it won't be suggested as a category anymore.")
            }
        }
    }

    // MARK: - Styling helpers

    @ViewBuilder
    private func settingsSection<Content: View>(
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

    private func valueRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(DesignPalette.body(14))
                .foregroundStyle(DesignPalette.ink)
            Spacer(minLength: 8)
            Text(value)
                .font(DesignPalette.body(13))
                .foregroundStyle(DesignPalette.mutedInk)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func disclosureRow(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(DesignPalette.body(15).weight(.semibold))
                .foregroundStyle(DesignPalette.primary)
                .frame(width: 22)
            Text(title)
                .font(DesignPalette.body(14).weight(.medium))
                .foregroundStyle(DesignPalette.ink)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(DesignPalette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func divider() -> some View {
        Divider()
            .background(DesignPalette.cream)
            .padding(.vertical, 2)
    }

    // MARK: - Sections

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let user = authService.user {
                if let name = user.name {
                    valueRow("Name", name)
                }
                if let email = user.email {
                    valueRow("Email", email)
                }
            }
            divider()
            Button {
                confirmSignOut = true
            } label: {
                HStack {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(DesignPalette.body(14).weight(.semibold))
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.red)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            "Sign out?",
            isPresented: $confirmSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                authService.signOut()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can sign back in anytime. Your data is synced to your account.")
        }
    }

    private var schedulingSection: some View {
        Button {
            showPreferences = true
        } label: {
            disclosureRow("Schedule Preferences", systemImage: "slider.horizontal.3")
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showPreferences) {
            PreferencesView()
        }
    }

    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch calendarService.permission {
            case .granted:
                HStack {
                    Label("Calendar connected", systemImage: "checkmark.circle.fill")
                        .font(DesignPalette.body(14))
                        .foregroundStyle(DesignPalette.primary)
                    Spacer()
                }
                NavigationLink {
                    CalendarSelectionView()
                } label: {
                    disclosureRow("Choose Calendars", systemImage: "checklist")
                }
                .buttonStyle(.plain)
            case .denied:
                HStack {
                    Label("Calendar access disabled", systemImage: "calendar.badge.exclamationmark")
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
            case .notDetermined:
                Button {
                    Task { await calendarService.requestPermission() }
                } label: {
                    HStack {
                        Label("Connect Calendar", systemImage: "calendar.badge.plus")
                            .font(DesignPalette.body(14).weight(.medium))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            divider()

            Button {
                Task { await syncNow() }
            } label: {
                HStack {
                    if syncManager.isSyncing {
                        ProgressView()
                        Text("Syncing…")
                            .font(DesignPalette.body(14))
                    } else {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                            .font(DesignPalette.body(14).weight(.medium))
                        Spacer()
                        if syncManager.pendingCount > 0 {
                            Text("\(syncManager.pendingCount) pending")
                                .font(DesignPalette.body(11))
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(syncManager.isSyncing)

            if let lastSync = syncManager.lastSyncDate {
                valueRow("Last synced", lastSync.formatted(date: .abbreviated, time: .shortened))
            }
            if syncedMessage, syncManager.lastSyncError == nil {
                Label("Sync complete", systemImage: "checkmark.circle.fill")
                    .font(DesignPalette.body(12))
                    .foregroundStyle(DesignPalette.primary)
            }
            if let error = syncManager.lastSyncError {
                Text(error)
                    .font(DesignPalette.body(12))
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var notificationSection: some View {
        Button {
            showNotificationSettings = true
        } label: {
            disclosureRow("Notification Settings", systemImage: "bell")
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showNotificationSettings) {
            NavigationStack {
                NotificationSettingsView()
            }
        }
    }

    private var appearanceSection: some View {
        Picker("Theme", selection: Bindable(appearance).theme) {
            ForEach(AppTheme.allCases) { theme in
                Text(theme.label).tag(theme)
            }
        }
        .pickerStyle(.segmented)
        .tint(DesignPalette.primary)
    }

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(categoryStore.categories(from: taskService.tasks), id: \.self) { category in
                HStack {
                    Text(category)
                        .font(DesignPalette.body(14))
                        .foregroundStyle(DesignPalette.ink)
                    Spacer()
                    Button {
                        categoryToRemove = category
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !categoryStore.categories(from: taskService.tasks).isEmpty {
                divider()
            }

            HStack(spacing: 10) {
                AppTextField(
                    placeholder: "New category",
                    text: $newCategory,
                    font: DesignPalette.body(14)
                )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(DesignPalette.background, in: RoundedRectangle(cornerRadius: DesignPalette.compactRadius))
                Button("Add") {
                    categoryStore.add(newCategory)
                    newCategory = ""
                }
                .font(DesignPalette.body(13).weight(.semibold))
                .foregroundStyle(DesignPalette.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(DesignPalette.sage, in: Capsule())
                .buttonStyle(.plain)
                .disabled(newCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var privacySection: some View {
        Text("Schedule generation is powered by Google's Gemini AI. Task details you create are sent to the scheduler to plan your day. Calendar events are never uploaded — only busy-time blocks you choose to share.")
            .font(DesignPalette.body(11))
            .foregroundStyle(DesignPalette.mutedInk)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func syncNow() async {
        syncedMessage = false
        await syncManager.syncNow()
        if syncManager.lastSyncError == nil {
            syncedMessage = true
        }
    }
}

#Preview {
    SettingsView()
        .environment(AuthenticationService())
        .environment(CalendarService())
        .environment(NotificationService.shared)
        .environment(ScheduleService())
        .environment(TaskService())
        .environment(SyncManager(store: LocalStore(inMemory: true), connectivity: ConnectivityMonitor()))
        .environment(CategoryStore())
        .environment(AppearanceSettings())
}
