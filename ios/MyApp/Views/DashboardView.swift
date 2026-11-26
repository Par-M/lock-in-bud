import SwiftUI
import UIKit

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

    init() {
        let background = UIColor(red: 0xF3 / 255, green: 0xF3 / 255, blue: 0xEB / 255, alpha: 1)
        let primary = UIColor(red: 0x3E / 255, green: 0x66 / 255, blue: 0x3C / 255, alpha: 1)
        let secondary = UIColor(red: 0x66 / 255, green: 0x70 / 255, blue: 0x60 / 255, alpha: 1)

        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = background
        appearance.shadowColor = UIColor.black.withAlphaComponent(0.08)

        let item = UITabBarItemAppearance()
        item.normal.iconColor = secondary
        item.normal.titleTextAttributes = [.foregroundColor: secondary]
        item.selected.iconColor = primary
        item.selected.titleTextAttributes = [.foregroundColor: primary]

        appearance.stackedLayoutAppearance = item
        appearance.inlineLayoutAppearance = item
        appearance.compactInlineLayoutAppearance = item

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

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
}
