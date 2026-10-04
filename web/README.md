# Web App

Responsive companion to the SwiftUI app, with the same Schedule, Tasks, Habits, and Focus tabs. Uses the existing FastAPI API and Google accounts. No separate database or Gemini keys are needed in the frontend.

## Local Setup

Run the backend on port 8000. In `web/.env.local`, configure:

```dotenv
API_BASE_URL=http://localhost:8000
NEXT_PUBLIC_GOOGLE_CLIENT_ID=your-web-google-client-id.apps.googleusercontent.com
```

The Google client ID must match the backend's `GOOGLE_CLIENT_ID`. In Google Cloud, use a **Web application** OAuth client and add `http://localhost:3000` and the deployed website as authorized JavaScript origins. If the native app currently uses a different audience, configure and test an explicitly allowed web audience on the backend before public release; do not disable audience verification.

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

The backend must be healthy first. Its production database currently needs the chat-table migration. Run the existing `backend/scripts/migrate.py` workflow against the intended database through a controlled deployment step, then verify `/openapi.json`. A Vercel deployment marked Ready does not guarantee API runtime health.

From `backend/`, using the real production database URL supplied securely as `DATABASE_URL`:

```bash
./.venv/bin/python -m scripts.migrate --check
./.venv/bin/python -m scripts.migrate
./.venv/bin/python -m scripts.migrate --check
```

The expected revision is `20251004130000`. Do not use a redacted Vercel environment export as a database connection string. Back up the database before production migrations. The backend also needs `GEMINI_API_KEY` for assistant/recommendation AI features; it was absent from the inspected production configuration. Production data and environment values have not been changed by this PR.

## Installation And Offline Behavior

The manifest, PNG icons, and service worker support Add to Home Screen / browser installation. On iPhone, use Safari > Share > Add to Home Screen. The service worker caches only public icons and an offline page, never account data or API responses. Full offline task editing and web push are not included. Focus timer state persists locally per account, but saving requires connectivity. Timers synchronize across tabs using browser storage and Web Locks. An interrupted write is marked for manual review rather than automatically retried, because the backend does not yet support idempotent focus writes.

## Verification

```bash
npm run typecheck
npm run build
npx playwright install chromium
npm test
```

Browser tests mock the API to verify mobile/desktop layout and core interactions; they do not establish production Google sign-in or backend availability.

## Parity Boundaries

The core navigation, colors, task fields, habits, schedule blocks/recommendations, focus logging, and chat mirror the app. This is not a pixel-for-pixel SwiftUI port. Device calendars (EventKit), APNs, widgets, advanced schedule review/rescheduling, chart details, and native offline queues are not replicated. The current merged assistant supports conversation text but does not execute task-changing tool calls. Both clients read and write the same account data; active timers and appearance are browser-local.
