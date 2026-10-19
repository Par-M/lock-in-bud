import WidgetKit
import SwiftUI

@main
struct MyAppWidgetBundle: WidgetBundle {
    var body: some Widget {
        CurrentTaskWidget()
        TasksRemainingWidget()
        FocusTimerWidget()
        #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
        FocusLiveActivity()
        #endif
    }
}
