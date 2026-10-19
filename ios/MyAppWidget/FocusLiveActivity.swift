#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
import SwiftUI
import WidgetKit

struct FocusLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusActivityAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: context.state.isPaused ? "pause.circle.fill" : "timer")
                    .font(.title).foregroundStyle(.blue).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Lock In Bud · \(context.state.isPaused ? "Paused" : "Focusing")")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(context.attributes.taskTitle).font(.headline).lineLimit(2)
                    Text("Tap to return to your session").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                FocusActivityTime(state: context.state)
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .frame(maxWidth: 145, alignment: .trailing)
            }
            .padding(16)
            .activityBackgroundTint(Color(.secondarySystemBackground))
            .activitySystemActionForegroundColor(.primary)
            .widgetURL(URL(string: "app://focus"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.isPaused ? "Paused" : "Focusing", systemImage: context.state.isPaused ? "pause.fill" : "timer")
                        .font(.caption).foregroundStyle(.blue)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    FocusActivityTime(state: context.state).font(.title2.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.attributes.taskTitle).font(.headline).lineLimit(2)
                }
            } compactLeading: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "timer").foregroundStyle(.blue)
            } compactTrailing: {
                FocusActivityTime(state: context.state).font(.caption2).frame(width: 52)
            } minimal: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "timer").foregroundStyle(.blue)
            }
            .widgetURL(URL(string: "app://focus"))
            .keylineTint(.blue)
        }
    }
}

private struct FocusActivityTime: View {
    let state: FocusActivityAttributes.ContentState
    var body: some View {
        Group {
            if state.isPaused {
                Text(Duration.seconds(state.elapsedSeconds).formatted(.time(pattern: .hourMinuteSecond)))
            } else {
                Text(timerInterval: state.timerStartedAt...state.timerStartedAt.addingTimeInterval(86400 * 365), countsDown: false)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityLabel(state.isPaused ? "Paused focus time" : "Focus time")
    }
}

#Preview("Running", as: .content, using: FocusActivityAttributes(sessionID: "preview", taskTitle: "Study for your exam")) {
    FocusLiveActivity()
} contentStates: {
    FocusActivityAttributes.ContentState(elapsedSeconds: 125, isPaused: false, timerStartedAt: .now.addingTimeInterval(-125))
    FocusActivityAttributes.ContentState(elapsedSeconds: 125, isPaused: true, timerStartedAt: .now.addingTimeInterval(-125))
}

#endif
