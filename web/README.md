# Web App

Responsive companion to the SwiftUI app, with the same Schedule, Tasks, Habits, and Focus tabs. Uses the existing FastAPI API and Google accounts. No separate database or Gemini keys are needed in the frontend.

## Local Setup

Run the backend on port 8000. In `web/.env.local`, configure:

```dotenv
API_BASE_URL=http://localhost:8000
NEXT_PUBLIC_GOOGLE_CLIENT_ID=your-web-google-client-id.apps.googleusercontent.com
```

Set the backend's `GOOGLE_WEB_CLIENT_ID` to the website's `NEXT_PUBLIC_GOOGLE_CLIENT_ID`. Keep `GOOGLE_CLIENT_ID` set to the native app's client ID. The backend verifies Google signatures, expiry, issuer, and membership in this explicit audience allowlist. In Google Cloud, use a **Web application** OAuth client and add `http://localhost:3000` and the deployed website as authorized JavaScript origins. Do not disable audience verification.

```bash
npm ci
npm run dev
```

Session tokens stay in HTTP-only, SameSite cookies. A same-origin server proxy attaches bearer tokens, handles refresh, and rejects cross-origin mutations. Neither Gemini nor database credentials belong in `NEXT_PUBLIC_*` variables.

## Deployment

1. Merge the web PR into `main`.
2. In Vercel, choose **Add New > Project** and import `Par-M/lock-in-bud` again. Give this project a different name, such as `lock-in-bud-web`.
3. Select **Root Directory `web`**, **Framework Preset Next.js**, and Node.js **24.x**. Leave the install/build/output settings at their defaults. Keep the production branch set to `main`.
4. Add `API_BASE_URL=https://lock-in-bud.vercel.app` and `NEXT_PUBLIC_GOOGLE_CLIENT_ID=<web OAuth client ID>` to Production. Add them to Preview too if previews should use this backend; previews will otherwise not be fully functional. These previews write real account data when pointed at production, so use a separate backend for isolated testing.
5. Deploy. Vercel assigns a public HTTPS URL; subsequent merges to `main` redeploy automatically. The existing backend remains in its own project with root `backend`.
6. Add the assigned website origin (for example `https://lock-in-bud-web.vercel.app`) to the web OAuth client's **Authorized JavaScript origins** in Google Cloud. Google Identity Services uses the ID-token flow here, not a custom redirect callback. Redeploy after changing the public client-ID variable, since it is embedded at build time.
7. Open the website, sign in with the account used in the native app, create a task, reload, and verify that the same task appears in both clients. Check focus logging and sign-out. On iPhone, use Safari > Share > Add to Home Screen.

Do not put the database URL, JWT secret, or Gemini key in the web project. The server-side API proxy means browser-to-backend CORS changes are not required. You can add a custom domain later under the web project's Settings > Domains; also authorize that origin in Google Cloud.

The backend must be healthy first. Run the existing `backend/scripts/migrate.py` workflow against the intended database through a controlled deployment step when migrations are pending, then verify `/openapi.json`. A Vercel deployment marked Ready does not guarantee API runtime health.

From `backend/`, using the real production database URL supplied securely as `DATABASE_URL`:

```bash
./.venv/bin/python -m scripts.migrate --check
./.venv/bin/python -m scripts.migrate
./.venv/bin/python -m scripts.migrate --check
```

The expected revision is `20251004130000`. Do not use a redacted Vercel environment export as a database connection string. Back up the database before production migrations. The backend also needs `GEMINI_API_KEY` for AI features. All Gemini providers use the configured `GEMINI_CHAT_MODEL`, defaulting to `gemini-3.5-flash-lite`.

## Installation And Offline Behavior

The manifest, PNG icons, and service worker support Add to Home Screen / browser installation. On iPhone, use Safari > Share > Add to Home Screen. The service worker caches only the anonymous public app shell, hashed static assets, icons, and offline fallback, never account data or API responses. After connecting once, account-UUID-scoped IndexedDB snapshots support offline task reading, creation, editing, and deletion. Revision-checked outboxes replay stable operation IDs and retain conflicts for review. Task transitions, occurrence actions, rescheduling, and other mutations still require connectivity. Browser storage and Web Locks coordinate writes across tabs.

Focus runs use stable session IDs and atomically record whole task minutes on the backend. Interrupted new saves can be retried explicitly with the same ID and payload; legacy uncertain saves without IDs require manual review. Editing or deleting a historical session does not retroactively adjust task minutes. Hard deletion removes that session's retry protection, so do not replay a deleted session's operation ID.

## Verification

```bash
npm run typecheck
npm run build
npx playwright install chromium
npm test
```

Browser tests mock the API to verify mobile/desktop layout and core interactions; they do not establish production Google sign-in or backend availability.

## Parity Boundaries

The clients expose the same core online task, habit, schedule-proposal, block, occurrence, reschedule, focus-history, assistant, and notification-preference operations. See `../docs/client-parity.md` for the remaining boundaries rather than treating this as a pixel-for-pixel SwiftUI port. The assistant supports conversation text but does not execute task-changing tool calls. Both clients read and write the same account data; active timers, category suggestions, and appearance are device-local.

External availability uses EventKit on iOS and explicit Google Calendar read-only consent on web. Enable the Google Calendar API and configure consent for `calendar.events.readonly` and `calendar.calendarlist.readonly` before using the web import. Tokens remain in browser memory; only busy start/end intervals reach the backend. Imports are bounded snapshots, not live sync, and exclude all-day, cancelled, and transparent events.
