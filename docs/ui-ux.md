# Everyday planning experience

Web and iOS open on Schedule. Tasks, Habits, and Focus remain available from navigation. The Today tab and its dashboard have been removed.

New task forms show the title, deadline, and estimated time first. More options contains recurrence, priority, categories, notes, and checklists. Events require start and end times. Editing exposes existing advanced values.

Task lists group work by urgency. Start focus is the primary task action and changes pending tasks to in progress. Tracked time is displayed separately from completion; logging a session never automatically completes a task. Completing a repeating task applies to the current occurrence.

Focus timers remain accessible across tabs. Pause persists across reloads and excludes paused time from logged duration. Stop and save uses the existing retry-safe session flow. Destructive actions use confirmations; completion and archive provide recovery where supported. Row-level feedback keeps unrelated tasks usable.

The desktop web assistant opens beside the plan and becomes a modal on smaller screens. Proposed actions have specific confirmation labels. Schedule proposal summaries explain added blocks and preserve fixed events. iOS onboarding is shorter; calendar and notification permissions remain available when configuring those features in Settings.

The web interface includes improved dark-theme action contrast, keyboard focus restoration, reduced-motion support, and a single-row mobile navigation bar. Native controls retain system accessibility behavior and larger task completion targets.

## Validation

- Full browser regression suite: 130 passed for the initial UX changes; focused browser checks cover the four-tab navigation, dark theme, timer pause/reload, forms, confirmations, and assistant responsiveness.
- iOS simulator unit tests: 20 passed; final simulator build also checked.
- Backend focus API compatibility: 31 passed. No database migration is required by these UI changes.

An iOS release requires a new app build. Simulator testing does not replace physical-device accessibility or notification testing.
