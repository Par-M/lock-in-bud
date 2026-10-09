# Planner assistant

The assistant reads an account-scoped planner snapshot and can invoke four read
tools: tasks, today's plan, logged focus statistics and habits. It proposes task
creation, occurrence completion, starting the current device's focus timer and
remembering a preference. Every proposal requires an explicit Confirm or Cancel
in the app. No planner mutation is executed by the model itself.

## Persistence and retries

A send is one transaction: user message, tool calls/results, assistant reply and
pending actions. A provider error or interrupted unfinished stream rolls it back.
Clients keep the draft and request UUID. Retrying that UUID replays the committed
reply after a lost response, without another provider request or another action.
Changing the draft uses a new UUID. Conversation row locks serialize sends and
action decisions. Confirmed and cancelled decisions are idempotent. Existing
planner services execute inside an outer transaction using savepoints, so their
internal commits cannot leave a mutation without its confirmation receipt.

A focus confirmation authorizes starting a timer on the confirming device; it
never creates a completed focus session or invents worked minutes. The normal
focus workflow logs work when the timer stops. Clients deduplicate timer starts
by action ID and preserve existing running timers.

## Context and tools

History is bounded to whole turns, with function-call/result pairs intact.
Gemini model parts and thought signatures are retained for replay. Older included
turns are compressed into bounded **extractive excerpts**, labelled as historical
and untrusted; this avoids another model request and does not infer new facts.
Live context is valid bounded JSON, built inside isolated savepoints. Unavailable
components are omitted, so a failed planner snapshot does not block chat.
Focus summaries sum logged sessions directly and never call another AI model.

Each tool round has an allowlist and argument validation. There is a round cap,
a context budget, output bounds and a total turn deadline. Task references carry
verified IDs for links; arbitrary URLs and HTML are not rendered as active web
content. Task data, memory and excerpts are data, never instructions.

## API

- `GET/POST /api/v1/chat/conversations` — paginated summaries / creation.
- `GET/PATCH/DELETE /api/v1/chat/conversations/{id}` — bounded detail / rename / delete.
- `GET .../{id}/messages?after=UUID&limit=50` — forward pages. `before` supports
  loading older pages; use one cursor direction at a time.
- `POST .../{id}/messages` — JSON reply by default; `Accept: text/event-stream`
  enables SSE. The `/messages/stream` alias also enables SSE.
- Send body: `content`, IANA `timezone` (default UTC), optional UUID `request_id`.
- Stream events: `delta`, `tool_status`, `complete`, `error`. Only `complete`
  acknowledges a saved reply; partial text is never cached as saved history.
- `POST .../{id}/actions/{action_id}/confirm` or `/cancel` — account-scoped decisions.
- `GET/DELETE /api/v1/chat/memory` — inspect / clear remembered preferences.

The conversation detail includes pending action cards. Conversation lists omit
messages and are capped at 100 per page; detail returns the last 100 messages.
Message ordering uses `(created_at, id)` for stable pagination.

## Privacy, deployment and limits

Memory is capped at 20 short, explicitly confirmed preferences in
`user_preferences.assistant_memory`. It requires migration `20261009110000`.
Clearing it removes active memory; old conversation confirmations remain part of
history until that conversation is deleted. The prompt treats them as historical.
Web offline history is an account-scoped read-only IndexedDB snapshot, separate
from the task outbox and cleared at logout. iOS keeps already-loaded history
readable. Both clients disable sends and decisions while offline.

Rate limiting enforces minute, hour and day windows under a process lock, prunes
expired entries and returns `Retry-After`. This is **best effort per backend
instance**, not a global quota across Vercel instances. Move it to a shared
limiter if deployment-wide enforcement is needed. Defaults: 10/minute, 60/hour,
100/day, eight provider rounds, 24,000 history characters, 4,000 snapshot
characters and an 80-second turn deadline. Telemetry logs only model, duration,
round count and token count, never message content or credentials.

Apply `python -m scripts.migrate` from `backend/` as the normal deployment step
before serving the new backend. Do not point test commands at application data.
The suite requires a separate `TEST_DATABASE_URL` and validates its disposable
name. All provider tests use mocks; no real Gemini calls are needed for tests.

Web dictation is feature-detected and uses the browser's speech recognition API
only after pressing Dictate. iOS retains the system keyboard's dictation input.
The Next.js proxy passes SSE through without buffering and keeps credentials in
HTTP-only session cookies.

## Validation

Backend: `TEST_DATABASE_URL=postgresql+psycopg://USER@localhost:5432/myapp_test
python -m pytest tests -q` from `backend/` (on one shell line).

Web: `npm run typecheck` and `npm test` from `web/`.

App: `xcodebuild test -project ios/MyApp.xcodeproj -scheme MyApp -destination
'platform=iOS Simulator,id=SIMULATOR_UUID' -only-testing:MyAppTests` (one line).
Client CI runs browser tests and isolated iOS unit tests. The iOS workflow pins
`macos-26` and chooses an installed iPhone simulator; the shipping deployment
target remains unchanged. Runner capabilities are documented in the official
[GitHub runner image](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md).
UI tests that require a live signed-in backend are not run by CI.
