import DeviceActivity
import Foundation

final class FocusLockMonitor: DeviceActivityMonitor {
    override func intervalWillEndWarning(for activity: DeviceActivityName) { finish(activity) }
    override func intervalDidEnd(for activity: DeviceActivityName) { finish(activity) }
    private func finish(_ activity: DeviceActivityName) {
        FocusLockState.update { session in
            session = session?.endingActivity(activity.rawValue)
        }
    }
}
