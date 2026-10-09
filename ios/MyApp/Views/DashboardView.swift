import SwiftUI

struct DashboardView: View {
    private enum Tab: Hashable {
        case today
        case schedule
        case tasks
        case habits
        case focus
    }

    @AppStorage("focusTimerPausedAt") private var pausedAt = 0.0
    @AppStorage("focusTimerStartedAt") private var timerStart = 0.0
    @Environment(SyncManager.self) private var sync
    @Environment(ConnectivityMonitor.self) private var connectivity
    @State private var selectedTab: Tab = .today

    var body: some View {
        TabView(selection: $selectedTab) {
            TodayView().tabItem { Label("Today", systemImage: "sun.max") }.tag(Tab.today)
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
    }
}