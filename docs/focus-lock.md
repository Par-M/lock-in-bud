# Focus Lock (iOS)

Open Focus → Focus Lock, authorize Screen Time access, enable the feature, choose Study, Work, or Workout, and select individual apps to block. Each profile has its own app selection. Leave essential tools unselected. Category and website selections are deliberately discarded: category shields would prevent an individual app exception.

Starting the existing timer also starts Focus Lock when enabled and configured. Starting from a task uses the same path. An existing timer can activate blocking from Focus Lock settings. Pausing keeps apps blocked. Stopping the timer releases apps before the logging/upload flow. Emergency exit releases apps and leaves the timer running. Sessions have a two-hour safety expiry; the timer can continue beyond it, and blocking can be activated again.

A short exception requires selecting a blocked app and entering a reason. Flexible mode adds a 10-second countdown; strict mode adds 30 seconds and permits two exceptions per session. Unlock windows are two or five minutes. Only one app can be temporarily allowed at a time. Reasons are not persisted or uploaded. Messages access unlocks the entire app; the app cannot restrict access to one conversation or judge urgency.

The app and embedded FocusLockMonitor extension share a named ManagedSettings store and an atomic Codable session file in the existing App Group. State changes and shield updates are serialized across processes using an App Group file lock. UUID-based activity names prevent old monitor callbacks from changing a newer session. State is removed before stopping monitoring on exit. Account changes remove selections, disable blocking, and clear the active session.

Device Activity monitors handle expiry when the host app is suspended. Short windows use the end-warning callback of a 15-minute monitoring interval, with interval-end as a fallback. iOS controls callback delivery; reblocking is not a guaranteed wall-clock deadline. Foreground activation reconciles expired state as well. Monitoring failures leave apps blocked for exception requests, and leave apps available for failed initial activation; the UI explains failures.

## Signing and release gate

Both `com.AM29.MyApp` and `com.AM29.MyApp.FocusLockMonitor` require Family Controls distribution approval and provisioning profiles that include `com.apple.developer.family-controls`. Both targets require the existing `group.com.AM29.MyApp` App Group. Request the capability in the Apple Developer account, then regenerate provisioning profiles. A successful unsigned simulator build does not establish entitlement approval or physical-device shielding.

Apple documentation:
- https://developer.apple.com/documentation/familycontrols/requesting-the-family-controls-entitlement
- https://developer.apple.com/documentation/deviceactivity/deviceactivityschedule
- https://developer.apple.com/documentation/deviceactivity/deviceactivitymonitor/intervalwillendwarning(for:)

## Physical-device acceptance checks before release

1. Grant and deny individual Screen Time authorization; denial must leave the timer usable and show that blocking is off.
2. Select apps separately for Study and Workout; verify profile persistence and no category/website blocking.
3. Start a task timer and open a selected app; verify the system shield. An unselected app remains available.
4. Pause the timer and verify shields remain. Stop it and verify all Focus Lock shields are removed, even if session upload fails.
5. Request a two-minute exception, open that app, and keep the host app suspended through expiry. Verify reblocking and measure actual callback delay. Repeat for five minutes, app termination, and device reboot.
6. Verify strict mode limits, countdown cancellation when changing inputs, return-to-focus, emergency exit, two-hour expiry, and authorization revocation.
7. Sign out/switch accounts and verify shields and profile selections are cleared. Check accessibility with VoiceOver and large text on a physical device.

App blocking is native iOS functionality; mobile web does not block other phone apps. No backend migration or server upload is involved.
