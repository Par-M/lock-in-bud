import SwiftUI

private enum TabBarColor {
    static let lime = Color(red: 184 / 255, green: 217 / 255, blue: 109 / 255)
    static let inactiveLabel = Color(red: 199 / 255, green: 208 / 255, blue: 191 / 255)
}

struct DashboardView: View {
    private enum Tab: Hashable {
        case schedule
        case tasks
        case habits
        case focus
    }

    @AppStorage("focusTimerPausedAt") private var pausedAt = 0.0
    @AppStorage("focusTimerStartedAt") private var timerStart = 0.0
    @Environment(SyncManager.self) private var sync
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(NotificationService.self) private var notificationService
    @State private var selectedTab: Tab = .schedule
    @ScaledMetric(relativeTo: .caption2) private var tabIconSize: CGFloat = 21

    var body: some View {
        TabView(selection: $selectedTab) {
            WeeklyScheduleView()
                .tabItem {
                    Label("Schedule", systemImage: "calendar")
                }
                .tag(Tab.schedule)

            TaskListView()
                .tabItem {
                    Label("Tasks", systemImage: "checklist")
                }
                .tag(Tab.tasks)

            HabitsView()
                .tabItem {
                    Label("Habits", systemImage: "checkmark.circle")
                }
                .tag(Tab.habits)

            FocusDashboardView()
                .tabItem {
                    Label("Focus", systemImage: "timer")
                }
                .tag(Tab.focus)
        }
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 0) {
                    tabButton(title: "Schedule", icon: "calendar-icon-9bfd7acb", tab: .schedule)
                    tabButton(title: "Tasks", icon: "tasks-icon", tab: .tasks)
                    tabButton(title: "Habits", icon: "habit-icon-e48140e1", tab: .habits)
                    tabButton(title: "Focus", icon: "focus-icon-b6adf5d7", tab: .focus)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                .frame(maxWidth: 370, minHeight: 70)
                .background(DesignPalette.ink, in: RoundedRectangle(cornerRadius: 24))
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 4) {
                if !connectivity.isConnected || sync.pendingCount > 0 || sync.isSyncing || sync.lastSyncError != nil {
                    HStack { Text(!connectivity.isConnected ? "Saved on device · offline" : sync.lastSyncError != nil ? "Couldn’t sync" : sync.isSyncing ? "Syncing…" : "Saved on device · changes pending").font(.caption); Spacer(); if connectivity.isConnected && !sync.isSyncing { Button("Retry sync") { Task { await sync.syncNow() } } } }.padding(.horizontal)
                }
                if timerStart > 0 && selectedTab != .focus {
                    VStack(alignment: .leading, spacing: 8) { HStack { Image(systemName: "timer"); Text(FocusTimerStarter.activeTaskTitle ?? "Focus session").lineLimit(2); Spacer(); TimelineView(.periodic(from: .now, by: 1)) { _ in Text(Duration.seconds(FocusTimerStarter.elapsedSeconds()).formatted(.time(pattern: .minuteSecond))).monospacedDigit() } }; HStack { Button(pausedAt > 0 ? "Resume" : "Pause") { FocusTimerStarter.togglePause() }; Button("Open timer") { selectedTab = .focus } } }.padding().background(.regularMaterial)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFocus)) { _ in
            selectedTab = .focus
        }
        .onChange(of: timerStart) { _, _ in
            notificationService.syncForFocusTimer()
        }
    }

    private func tabButton(title: String, icon: String, tab: Tab) -> some View {
        let isSelected = selectedTab == tab

        return Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 4) {
                Image(icon)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: tabIconSize, height: tabIconSize)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? DesignPalette.ink : TabBarColor.inactiveLabel)
            .frame(maxWidth: .infinity, minHeight: 56, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isSelected ? TabBarColor.lime : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
