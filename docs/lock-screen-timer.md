# Lock-screen focus timer

Starting a focus session automatically requests a local Live Activity with the task title and elapsed time. The card remains visible with a frozen duration while paused, resumes without counting breaks, and disappears when the timer stops or the account changes. Tapping the card or Dynamic Island opens Focus.

The system renders elapsed time from an effective start date, so the app does not need a background polling loop or push notifications. App and widget share the ActivityAttributes definition. Foreground reconciliation reconnects to the saved timer, removes orphaned/duplicate activities, and updates an existing card. Start/update/end operations run in order to handle rapid pause/resume/stop changes.

If Live Activities are disabled or a request fails, Focus shows an explanation and retry button; time tracking continues. Enable Live Activities for Lock In Bud in iPhone Settings if needed. iOS controls appearance, dismissal, lifetime, and display sleep. Brightness is unchanged.

## Local testing

Use the `codex/lock-screen-focus-timer` branch, choose the MyApp scheme and your iPhone, then run from Xcode with development signing. No Family Controls capability or new paid capability is introduced; local ActivityKit requests use no push entitlement. Existing project signing still needs to be valid for both app and widget targets. Free-team device provisioning must be verified on the actual phone.

1. Start a focus session, lock the phone, and verify that task title and elapsed time appear and advance.
2. Pause from the app: the card should remain, say Paused, and stop advancing. Wait, resume, and verify the break is excluded.
3. Tap the card and verify it opens Focus. Stop the timer and verify the card disappears.
4. Start from a task and from Focus. Switch tabs/background/reopen; verify there is only one card.
5. Disable Live Activities in Settings, start a session, and verify the timer still works with an explanation. Re-enable, return to the app, and retry.
6. Sign out/switch accounts and verify the old session card is removed. Test Dynamic Island on a supported iPhone and large accessibility text.

Automated checks exercise timer projection, single-activity reconciliation, queued transitions, permission/request failure handling, and the installed app's Live Activities setting. Actual device display and free-team signing remain physical-device checks.

Reference: https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities
