# Client Functionality Parity

Web and iOS share the backend's scheduling and data contracts, not identical
implementation code. SwiftUI, browser APIs, authentication storage, and native
integrations necessarily differ. This checklist records actual coverage and
remaining gaps; it is not a claim that every platform capability is identical.

## Shared Core Operations

| Area | Coverage |
| --- | --- |
| Tasks | Create/edit/delete, notes/checklists, progress minutes, archive/restore, filters/sorts, task start/completion, focus launch |
| Schedule | Daily advice, stored proposal generation/review, item acceptance/redo, accept-all/reject, blocks, occurrence edits, reschedule/snooze |
| Habits | Create/edit/delete, reorder, daily counts, complete/reset, streaks and history |
| Focus | Persistent task/free timers, category attribution, range-filtered history, edit/delete, category totals |
| Assistant | Conversation creation/history/rename/delete, streaming, live planner context, read tools, confirmed actions, safe retries, offline history, citations and remembered preferences |
| Preferences | Work hours, buffers, default task settings, notification preferences, appearance and category suggestions |
| Authentication | Native/web OAuth allowlist, refresh, current-session logout, transient-error handling |
| Reliability | Account-isolated focus state, stable focus-save IDs, atomic whole-minute recording, durable local task mutations |

## Planning Rules

- Both clients use the same backend endpoints. Daily advice is not an accepted calendar plan; a saved proposal requires approval.
- Saved plans begin today, cover at least the next week, and extend to task deadlines. Navigating the calendar does not change this horizon.
- Daily advice honors the selected local dates. Offset-aware boundaries are converted into the requested timezone before extracting dates.
- Internal blocks and fixed/recurring occurrences reserve availability. Imported calendars contribute only busy start/end intervals.
- Flexible work must fit available slots, exact deadlines, remaining duration, buffers, and retained-work daily budgets. Fixed-event overlaps remain explicit exceptions.
- Split-task approvals preserve earlier approvals. Malformed AI output is rejected and can fall back to a validated deterministic schedule.
- Automatic proposals require previously saved user scheduling context; there is no background failed-plan retry worker.

## Remaining Differences

- Web external availability uses Google Calendar consent rather than EventKit. Live Google Calendar access requires Calendar API enablement and OAuth consent configuration. Imports are snapshots with bounded coverage and need explicit refresh.
- APNs/local notification delivery, widgets, Live Activities, native settings navigation, and haptics are native integrations. Web can edit account notification preferences but does not implement Web Push delivery.
- Web offline task CRUD uses revision-aware replication. Task transitions, parse, archive actions, occurrence completion, time adjustments, snooze, and reschedule remain online-only. Native task sync still uploads task snapshots and is not fully migrated to revision-aware replication.
- Category suggestions, timers, appearance, and onboarding state are device-local rather than account-synchronized. Native onboarding is not reproduced as a mandatory browser flow.
- Native quick add has a deterministic local parser; web uses the backend parser online. Their natural-language interpretations are not guaranteed identical.
- Focus-history edits/deletes do not adjust recorded task minutes. Hard-deleted sessions no longer retain their stable-ID replay protection. Legacy unscoped native queues are retained on disk but are not uploaded to an unknown account.
- Client request/response coverage is regression-tested, but real OAuth consent, calendar permissions, push delivery, and multi-device network interruption still require integration testing.

## Verification

Backend tests exercise PostgreSQL migrations and shared API contracts against a
disposable test database. Browser tests run desktop/mobile production builds
with mocked APIs, plus actual service-worker offline reloads. Native XCTest and
simulator builds cover request encoding, account isolation, timer safety, and
occurrence timing. These do not replace live cross-device acceptance tests.
