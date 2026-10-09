import SwiftData
import SwiftUI

@main
struct MyAppApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var authService = AuthenticationService()
    @State private var localStore: LocalStore
    @State private var connectivity: ConnectivityMonitor
    @State private var syncManager: SyncManager
    @State private var taskService: TaskService
    @State private var plannerService = PlannerService()
    @State private var calendarService: CalendarService
    @State private var scheduleService: ScheduleService
    @State private var recommendationService: RecommendationService
    @State private var categoryStore = CategoryStore()
    @State private var appearance = AppearanceSettings()
    @State private var habitService = HabitService()
    @State private var focusService = FocusService()

    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = LocalStore()
        let connectivity = ConnectivityMonitor()
        let syncManager = SyncManager(store: store, connectivity: connectivity)
        let calendarService = CalendarService()

        _authService = State(
            initialValue: AuthenticationService(localStore: store)
        )
        _localStore = State(initialValue: store)
        _connectivity = State(initialValue: connectivity)
        _syncManager = State(initialValue: syncManager)
        _calendarService = State(initialValue: calendarService)
        _recommendationService = State(
            initialValue: RecommendationService(calendarService: calendarService)
        )
        _scheduleService = State(
            initialValue: ScheduleService(
                store: store,
                connectivity: connectivity
            )
        )
        _taskService = State(
            initialValue: TaskService(store: store, connectivity: connectivity)
        )
    }

    @State private var chatService = ChatService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(authService)
                .environment(taskService)
                .environment(plannerService)
                .environment(NotificationService.shared)
                .environment(calendarService)
                .environment(scheduleService)
                .environment(recommendationService)
                .environment(syncManager)
                .environment(connectivity)
                .environment(categoryStore)
                .environment(appearance)
                .environment(habitService)
                .environment(focusService)
                .environment(chatService)
                .onChange(of: authService.user?.id) { _, _ in chatService.synchronizeAccount() }
                .preferredColorScheme(appearance.theme.colorScheme)
                .task {
                    await authService.restoreSession()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .active else { return }
                    Task {
                        // The access token is short-lived, so returning to the
                        // app after a while needs a silent revalidation.
                        await authService.revalidateSession()
                        // Replay any focus sessions that could not upload.
                        await focusService.flushPendingSessions()
                    }
                }
                .onOpenURL { url in
                    guard url.scheme == "app" else { return }
                    switch url.host {
                    case "focus":
                        NotificationCenter.default.post(name: .openFocus, object: nil)
                    default:
                        break
                    }
                }
        }
        .modelContainer(localStore.container)
    }
}

import Observation
extension ChatService: Observable {}
