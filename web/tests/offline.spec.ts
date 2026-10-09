import { expect, test, type Page } from "@playwright/test";

const accountA = "11111111-1111-4111-8111-111111111111";
const accountB = "22222222-2222-4222-8222-222222222222";
const taskId = "33333333-3333-4333-8333-333333333333";
type Task = Record<string, unknown> & { id: string; title: string };
type Operation = { operation_id: string; entity: string; base_revision: number | null; operation: string; payload: Task };
type Result = { operation_id: string; entity: string; entity_id: string; status: string; revision: number; record: Task | null; detail?: string };

async function mockService(page: Page, seeded = false) {
  const state = {
    account: accountA, disconnected: false, expired: false, apiExpired: false, unavailable: false, loseNextPush: false, pullPageSize: 200,
    pushes: [] as { account: string; operation: Operation }[], ordinaryWrites: [] as string[], actions: [] as string[],
    records: new Map<string, Map<string, { task: Task; revision: number; deleted?: boolean }>>(),
    changes: new Map<string, { seq: number; entity: string; entity_id: string; revision: number; operation: string; record: Task | null }[]>(),
    receipts: new Map<string, Result>(),
  };
  function change(account: string, task: Task, revision: number, operation = "upsert") {
    const records = state.records.get(account) || new Map();
    records.set(task.id, { task, revision, deleted: operation === "delete" }); state.records.set(account, records);
    const changes = state.changes.get(account) || [];
    changes.push({ seq: changes.length + 1, entity: "task", entity_id: task.id, revision, operation, record: task }); state.changes.set(account, changes);
  }
  if (seeded) change(accountA, {
    id: taskId, title: "Existing task", priority: "medium", status: "pending", is_archived: false,
    notes: "Keep these notes", checklist: [{ text: "Keep checklist", done: true }], progress_percent: 25,
    before_task_ids: ["44444444-4444-4444-8444-444444444444"], repeat_overrides: { "2026-10-05": { completed: true } },
    created_at: "2026-10-01T10:00:00Z", updated_at: "2026-10-01T10:00:00Z",
  }, 7);
  await page.route("https://accounts.google.com/**", route => route.abort());
  await page.route("**/api/session", route => {
    if (state.disconnected) return route.abort("failed");
    if (state.expired) return route.fulfill({ status: 401, json: { detail: "Expired" } });
    if (state.unavailable) return route.fulfill({ status: 502, json: { detail: "Unavailable" } });
    if (route.request().method() === "DELETE") return route.fulfill({ json: { message: "Signed out" } });
    return route.fulfill({ json: { id: state.account, name: "Offline Tester", email: "offline@example.com" } });
  });
  await page.route("**/api/backend/**", async route => {
    const request = route.request(), url = new URL(request.url()), path = url.pathname.replace("/api/backend", "");
    if (state.disconnected) return route.abort("failed");
    if (state.expired || state.apiExpired) return route.fulfill({ status: 401, json: { detail: "Expired" } });
    if (state.unavailable) return route.fulfill({ status: 502, json: { detail: "Unavailable" } });
    if (path === "/sync/pull") {
      const cursor = Number(url.searchParams.get("cursor"));
      const remaining = (state.changes.get(state.account) || []).filter(change => change.seq > cursor);
      const changes = remaining.slice(0, state.pullPageSize);
      return route.fulfill({ json: { changes, cursor: changes.at(-1)?.seq || cursor, has_more: remaining.length > changes.length } });
    }
    if (path === "/sync/push") {
      const results: Result[] = [];
      for (const operation of request.postDataJSON().operations as Operation[]) {
        state.pushes.push({ account: state.account, operation });
        const receipt = state.receipts.get(`${state.account}:${operation.operation_id}`);
        if (receipt) { results.push({ ...receipt, status: "replayed" }); continue; }
        const existing = state.records.get(state.account)?.get(operation.payload.id);
        if (existing && operation.base_revision !== null && operation.base_revision !== existing.revision) {
          results.push({ operation_id: operation.operation_id, entity: "task", entity_id: operation.payload.id, status: "conflict", revision: existing.revision, record: existing.task, detail: "Changed on another device." });
          continue;
        }
        const revision = (existing?.revision || 0) + 1;
        change(state.account, operation.payload, revision, operation.operation);
        const result = { operation_id: operation.operation_id, entity: "task", entity_id: operation.payload.id, status: "applied", revision, record: operation.payload };
        state.receipts.set(`${state.account}:${operation.operation_id}`, result); results.push(result);
      }
      if (state.loseNextPush) { state.loseNextPush = false; return route.abort("failed"); }
      return route.fulfill({ json: { results } });
    }
    if (path.startsWith("/tasks") && request.method() !== "GET") {
      if (/^\/tasks(?:\/[^/]+)?$/.test(path)) state.ordinaryWrites.push(path);
      else state.actions.push(path);
      const existing = state.records.get(state.account)?.get(path.split("/")[2]);
      if (path.endsWith("/start") && existing) {
        const task = { ...existing.task, status: "in_progress", started_at: "2026-10-05T10:00:00Z" };
        change(state.account, task, existing.revision + 1);
        return route.fulfill({ json: task });
      }
      if (path.endsWith("/complete") && existing) {
        const task = { ...existing.task, status: "completed", completed_at: "2026-10-05T11:00:00Z", progress_percent: 100 };
        change(state.account, task, existing.revision + 1);
        return route.fulfill({ json: task });
      }
      return route.fulfill({ json: existing?.task || {} });
    }
    if (path === "/tasks") {
      const items = [...(state.records.get(state.account)?.values() || [])].filter(record => !record.deleted && Boolean(record.task.is_archived) === (url.searchParams.get("archived") === "true")).map(record => record.task);
      return route.fulfill({ json: { items, total: items.length } });
    }
    if (path === "/focus/sessions") return route.fulfill({ json: [] });
    if (path === "/focus/summary") return route.fulfill({ json: { total_duration_seconds: 0, session_count: 0 } });
    if (path === "/notifications/preferences") return route.fulfill({ json: {
      morning_briefing_enabled: false, morning_briefing_time: "08:00:00", deadline_reminder_enabled: false,
      deadline_reminder_lead_hours: 24, overdue_alerts_enabled: false, fifteen_minute_reminder_enabled: false,
      fifteen_minute_reminder_lead_minutes: 15, reschedule_alerts_enabled: false,
    } });
    return route.fulfill({ json: path === "/preferences" ? { default_priority: "medium", default_duration_minutes: 30, categories: [] } : path === "/habits/dashboard" ? { habits: [] } : { items: [], total: 0 } });
  });
  return { state, change };
}

async function tasks(page: Page) {
  await page.getByRole("navigation").getByRole("button", { name: "Tasks", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Tasks", exact: true })).toBeVisible();
}
async function connection(page: Page, online: boolean) {
  await page.evaluate(online => {
    Object.defineProperty(navigator, "onLine", { configurable: true, value: online });
    window.dispatchEvent(new Event(online ? "online" : "offline"));
  }, online);
}
async function warmDefaults(page: Page) {
  await page.getByRole("button", { name: "New task", exact: true }).click();
  await expect(page.getByRole("textbox", { name: "Title", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Close New task" }).click();
}
async function create(page: Page, title: string) {
  await page.getByRole("button", { name: "New task", exact: true }).click();
  await page.getByRole("textbox", { name: "Title", exact: true }).fill(title);
  await page.getByRole("button", { name: "Create task", exact: true }).click();
  await expect(page.getByRole("dialog", { name: "New task" })).toHaveCount(0);
  await expect(page.getByRole("button", { name: title, exact: true })).toBeVisible();
}
async function snapshot(page: Page, id = accountA) {
  return page.evaluate(async id => {
    const database = await new Promise<IDBDatabase>((resolve, reject) => {
      const request = indexedDB.open("task-offline", 1); request.onsuccess = () => resolve(request.result); request.onerror = reject;
    });
    return new Promise<{ outbox: { operation: Operation; sent: boolean; conflict?: string }[] }>(resolve => {
      const request = database.transaction("accounts").objectStore("accounts").get(id); request.onsuccess = () => resolve(request.result);
    });
  }, id);
}

test("offline create and edit survive reload and reconnect using stable operations, without duplicate POST", async ({ page }) => {
  const { state } = await mockService(page);
  await page.goto("/"); await tasks(page); await warmDefaults(page);
  state.disconnected = true; await connection(page, false);
  await create(page, "Offline draft");
  if (await page.getByLabel("More actions for Offline draft", { exact: true }).locator("..").getAttribute("open") === null) await page.getByLabel("More actions for Offline draft", { exact: true }).click();
  await page.getByRole("button", { name: "Edit Offline draft", exact: true }).click();
  await page.getByRole("textbox", { name: "Title", exact: true }).fill("Offline edited");
  await page.getByRole("button", { name: "Save changes", exact: true }).click();
  await expect(page.getByRole("button", { name: "Offline edited", exact: true })).toBeVisible();
  const before = await snapshot(page);
  expect(before.outbox).toHaveLength(2);
  expect(before.outbox[0].operation.payload.id).toBe(before.outbox[1].operation.payload.id);
  await page.addInitScript(() => Object.defineProperty(navigator, "onLine", { configurable: true, value: false }));
  await page.reload(); await tasks(page);
  await expect(page.getByRole("button", { name: "Offline edited", exact: true })).toBeVisible();
  state.disconnected = false; await connection(page, true);
  await expect(page.getByRole("region", { name: "Task sync status" })).toContainText("No pending task changes");
  expect(state.pushes.map(push => push.operation.operation_id)).toEqual(before.outbox.map(entry => entry.operation.operation_id));
  expect(state.pushes[1].operation.base_revision).toBe(1);
  expect(state.records.get(accountA)?.size).toBe(1);
  expect([...state.records.get(accountA)!.values()][0].task.title).toBe("Offline edited");
  expect(state.ordinaryWrites).toEqual([]);
});

test("a lost push response retries the exact operation ID and payload", async ({ page }) => {
  const { state } = await mockService(page);
  await page.goto("/"); await tasks(page); await warmDefaults(page);
  state.loseNextPush = true;
  await create(page, "Uncertain create");
  await expect(page.getByRole("region", { name: "Task sync status" })).toContainText("not confirmed on the server");
  await page.getByRole("button", { name: "Retry task sync", exact: true }).click();
  await expect(page.getByRole("region", { name: "Task sync status" })).toContainText("No pending task changes");
  expect(state.pushes).toHaveLength(2);
  expect(state.pushes[0]).toEqual(state.pushes[1]);
  expect(state.records.get(accountA)?.size).toBe(1);
  expect(state.ordinaryWrites).toEqual([]);
});

test("offline edits preserve full payload, retain revision conflicts, and require explicit discard", async ({ page }) => {
  const { state, change } = await mockService(page, true);
  await page.goto("/"); await tasks(page);
  state.disconnected = true; await connection(page, false);
  if (await page.getByLabel("More actions for Existing task", { exact: true }).locator("..").getAttribute("open") === null) await page.getByLabel("More actions for Existing task", { exact: true }).click();
  await page.getByRole("button", { name: "Edit Existing task", exact: true }).click();
  await page.getByRole("textbox", { name: "Title", exact: true }).fill("Local edit");
  await page.getByRole("button", { name: "Save changes", exact: true }).click();
  await expect(page.getByRole("button", { name: "Local edit", exact: true })).toBeVisible();
  const queued = (await snapshot(page)).outbox[0].operation;
  expect(queued.base_revision).toBe(7);
  expect(queued.payload.notes).toBe("Keep these notes");
  expect(queued.payload.repeat_overrides).toEqual({ "2026-10-05": { completed: true } });
  expect(queued.payload.before_task_ids).toHaveLength(1);
  expect(queued.payload).not.toHaveProperty("started_at");
  change(accountA, { ...state.records.get(accountA)!.get(taskId)!.task, title: "Remote edit" }, 8);
  state.disconnected = false; await connection(page, true);
  await expect(page.getByRole("region", { name: "Task sync status" })).toContainText("needs review: Local edit");
  await page.getByRole("button", { name: "Retry task sync", exact: true }).click();
  await expect.poll(async () => (await snapshot(page)).outbox[0].conflict).toBeTruthy();
  expect(state.pushes).toHaveLength(1);
  expect(state.records.get(accountA)!.get(taskId)!.task.title).toBe("Remote edit");
  await page.getByRole("button", { name: "Discard local changes for Local edit", exact: true }).click();
  await page.getByRole("dialog", { name: "Discard local changes" }).getByRole("button", { name: "Discard changes", exact: true }).click();
  await expect(page.getByRole("region", { name: "Task sync status" })).toContainText("No pending task changes");
});

test("offline delete uses a revision and full task payload, while online start keeps its route", async ({ page }) => {
  const { state } = await mockService(page, true);
  await page.goto("/"); await tasks(page);
  await page.getByRole("button", { name: "Focus on Existing task", exact: true }).click();
  await expect.poll(() => state.actions).toEqual([`/tasks/${taskId}/start`]);
  await tasks(page);
  await expect(page.getByText("in progress", { exact: true })).toBeVisible();
  state.disconnected = true; await connection(page, false);
  await page.getByRole("button", { name: "Complete Existing task", exact: true }).click();
  await expect(page.getByRole("alert").filter({ hasText: "This action requires an online connection and is not queued." })).toBeVisible();
  if (await page.getByLabel("More actions for Existing task", { exact: true }).locator("..").getAttribute("open") === null) await page.getByLabel("More actions for Existing task", { exact: true }).click();
  await page.getByRole("button", { name: "Delete Existing task", exact: true }).click();
  await page.getByRole("dialog", { name: "Confirm action" }).getByRole("button", { name: "Confirm", exact: true }).click();
  await expect(page.getByRole("button", { name: "Existing task", exact: true })).toHaveCount(0);
  const queued = (await snapshot(page)).outbox[0].operation;
  expect(queued.operation).toBe("delete"); expect(queued.base_revision).toBe(8); expect(queued.payload.id).toBe(taskId);
  state.disconnected = false; await connection(page, true);
  await expect(page.getByRole("region", { name: "Task sync status" })).toContainText("No pending task changes");
  expect(state.records.get(accountA)!.get(taskId)!.deleted).toBe(true);
});

test("account switching and logout hide cached tasks and isolate retained outboxes", async ({ page }) => {
  const { state } = await mockService(page);
  await page.goto("/"); await tasks(page); await warmDefaults(page);
  state.disconnected = true; await connection(page, false); await create(page, "Account A private task");
  state.account = accountB; state.disconnected = false; await connection(page, true);
  await expect(page.getByRole("region", { name: "Task sync status" })).toContainText("No pending task changes");
  await tasks(page);
  await expect(page.getByRole("button", { name: "Account A private task", exact: true })).toHaveCount(0);
  expect((await snapshot(page, accountA)).outbox).toHaveLength(1);
  expect(state.pushes).toEqual([]);
  state.account = accountA; await page.reload(); await tasks(page);
  await expect.poll(() => state.pushes.length).toBe(1);
  expect(state.pushes[0].account).toBe(accountA);
  await page.getByRole("button", { name: "Open settings", exact: true }).click();
  await page.getByRole("button", { name: "Sign out", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Lock In Bud", exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "Account A private task", exact: true })).toHaveCount(0);
});

test("transient foreground failures preserve the planner; an API 401 returns to sign-in with queue retained", async ({ page }) => {
  const { state } = await mockService(page);
  await page.goto("/"); await tasks(page); await warmDefaults(page);
  state.disconnected = true; await connection(page, false); await create(page, "Retained after expiry");
  state.disconnected = false; state.unavailable = true; await connection(page, true);
  await expect(page.getByRole("heading", { name: "Tasks", exact: true })).toBeVisible();
  await expect(page.getByRole("region", { name: "Task sync status" })).toContainText("Unable to reach the service");
  state.unavailable = false; state.apiExpired = true;
  await page.getByRole("button", { name: "Retry task sync", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Lock In Bud", exact: true })).toBeVisible();
  await expect(page.getByText(/Your session has expired/)).toBeVisible();
  expect((await snapshot(page)).outbox).toHaveLength(1);
  expect(state.pushes).toEqual([]);
});

test("two tabs retain independent offline creates under the same account lock", async ({ page, context }) => {
  const first = await mockService(page);
  await page.goto("/"); await tasks(page); await warmDefaults(page);
  const other = await context.newPage();
  const second = await mockService(other);
  await other.goto("/"); await tasks(other); await warmDefaults(other);
  first.state.disconnected = true; second.state.disconnected = true;
  await connection(page, false); await connection(other, false);
  await Promise.all([create(page, "First tab task"), create(other, "Second tab task")]);
  expect((await snapshot(page)).outbox).toHaveLength(2);
  first.state.disconnected = false; await connection(page, true);
  await expect(page.getByRole("region", { name: "Task sync status" })).toContainText("No pending task changes");
  expect(first.state.records.get(accountA)?.size).toBe(2);
  expect(new Set(first.state.pushes.map(push => push.operation.operation_id)).size).toBe(2);
});

test("a silently switched server session cannot upload the previous account's queue", async ({ page }) => {
  const { state } = await mockService(page);
  await page.goto("/"); await tasks(page); await warmDefaults(page);
  state.disconnected = true; await connection(page, false); await create(page, "Private queued task");
  state.disconnected = false; state.unavailable = true; await connection(page, true);
  await expect(page.getByRole("region", { name: "Task sync status" })).toContainText("Unable to reach the service");
  state.unavailable = false; state.account = accountB;
  await page.getByRole("button", { name: "Retry task sync", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Lock In Bud", exact: true })).toBeVisible();
  expect(state.pushes).toEqual([]);
  expect((await snapshot(page, accountA)).outbox).toHaveLength(1);
});

test("paginated pulls apply tombstones and keep archived tasks available offline", async ({ page }) => {
  const { state, change } = await mockService(page, true);
  state.pullPageSize = 1;
  change(accountA, { ...state.records.get(accountA)!.get(taskId)!.task, id: "55555555-5555-4555-8555-555555555555", title: "Archived offline task", is_archived: true }, 1);
  change(accountA, state.records.get(accountA)!.get(taskId)!.task, 8, "delete");
  await page.goto("/"); await tasks(page);
  await expect(page.getByRole("button", { name: "Existing task", exact: true })).toHaveCount(0);
  state.disconnected = true; await connection(page, false);
  await page.getByRole("combobox", { name: "Task filter", exact: true }).selectOption("archived");
  await expect(page.getByRole("button", { name: "Archived offline task", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Refresh tasks", exact: true }).click();
  await expect(page.getByRole("button", { name: "Archived offline task", exact: true })).toBeVisible();
});

test("online create with a status transition uses sync for details and normal start/complete routes", async ({ page }) => {
  const { state } = await mockService(page);
  await page.goto("/"); await tasks(page);
  await page.getByRole("button", { name: "New task", exact: true }).click();
  await page.getByRole("textbox", { name: "Title", exact: true }).fill("Online transition task");
  await expect(page.getByRole("combobox", { name: "Status", exact: true })).toHaveCount(0);
  await page.getByRole("button", { name: "Create task", exact: true }).click();
  await expect(page.getByRole("button", { name: "Online transition task", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Focus on Online transition task", exact: true }).click();
  await tasks(page);
  await expect(page.getByText("in progress", { exact: true })).toBeVisible();
  const id = [...state.records.get(accountA)!.keys()][0];
  expect(state.pushes[0].operation.payload.status).toBe("pending");
  expect(state.actions).toEqual([`/tasks/${id}/start`]);
  expect(state.records.get(accountA)!.get(id)!.task.started_at).toBeTruthy();
  await page.getByRole("button", { name: "Complete Online transition task", exact: true }).click();
  await expect.poll(() => state.actions).toEqual([`/tasks/${id}/start`, `/tasks/${id}/complete`]);
  expect(state.records.get(accountA)!.get(id)!.task.completed_at).toBeTruthy();
  expect(state.ordinaryWrites).toEqual([]);
});

test.describe("production offline app shell", () => {
  test.use({ serviceWorkers: "allow" });

  test("a genuine offline cold reload restores cached tasks and queues edits without caching account responses", async ({ page, context }) => {
    const { state } = await mockService(page, true);
    await page.goto("/"); await tasks(page);
    await expect(page.getByRole("button", { name: "Existing task", exact: true })).toBeVisible();
    await page.evaluate(async () => {
      await navigator.serviceWorker.ready;
      if (!navigator.serviceWorker.controller) await new Promise<void>(resolve => {
        navigator.serviceWorker.addEventListener("controllerchange", () => resolve(), { once: true });
      });
    });
    const shell = await page.evaluate(async () => {
      const cache = await caches.open("lock-in-public-v2");
      const response = await cache.match("/");
      return { html: await response?.text(), keys: (await cache.keys()).map(request => new URL(request.url).pathname) };
    });
    expect(shell.html).toContain("Connecting...");
    expect(shell.html).not.toContain("Offline Tester");
    expect(shell.html).not.toContain("offline@example.com");
    expect(shell.html).not.toContain("Existing task");
    expect(shell.keys.some(path => path.startsWith("/_next/static/") && path.endsWith(".js"))).toBe(true);
    expect(shell.keys.some(path => path.startsWith("/_next/static/") && path.endsWith(".css"))).toBe(true);

    // Remove API mocks before disconnecting: this must use the real worker and
    // browser offline mode, not a route fixture fulfilling offline requests.
    await page.unroute("**/api/session");
    await page.unroute("**/api/backend/**");
    await context.setOffline(true);
    await page.reload({ waitUntil: "domcontentloaded" });
    expect(await page.evaluate(() => navigator.onLine)).toBe(false);
    await tasks(page);
    await expect(page.getByRole("button", { name: "Existing task", exact: true })).toBeVisible();
    if (await page.getByLabel("More actions for Existing task", { exact: true }).locator("..").getAttribute("open") === null) await page.getByLabel("More actions for Existing task", { exact: true }).click();
  await page.getByRole("button", { name: "Edit Existing task", exact: true }).click();
    await page.getByRole("textbox", { name: "Title", exact: true }).fill("Cold reload edit");
    await page.getByRole("button", { name: "Save changes", exact: true }).click();
    await expect(page.getByRole("button", { name: "Cold reload edit", exact: true })).toBeVisible();
    await expect(page.getByRole("region", { name: "Task sync status" })).toContainText("saved on this device, not confirmed on the server");
    const queued = (await snapshot(page)).outbox[0].operation;
    expect(queued.payload.id).toBe(taskId); expect(queued.base_revision).toBe(7);
    expect(state.pushes).toEqual([]);

    // A new page has neither the previous React tree nor its loaded scripts.
    await page.close();
    const cold = await context.newPage();
    await cold.goto("/", { waitUntil: "domcontentloaded" }); await tasks(cold);
    await expect(cold.getByRole("button", { name: "Cold reload edit", exact: true })).toBeVisible();
    expect((await snapshot(cold)).outbox[0].operation).toEqual(queued);
    const keys = await cold.evaluate(async () => {
      const cache = await caches.open("lock-in-public-v2");
      return (await cache.keys()).map(request => new URL(request.url).pathname);
    });
    expect(keys.every(path => path === "/" || /^\/_next\/static\/.*\.(?:js|css)$/.test(path) || ["/offline.html", "/icon.svg", "/icon-192.png", "/icon-512.png", "/apple-icon.png"].includes(path))).toBe(true);
    expect(keys.some(path => path.startsWith("/api/") || path.endsWith(".rsc"))).toBe(false);
  });

  test("public cache migration preserves unrelated caches and logout/session responses never enter CacheStorage", async ({ page }) => {
    await mockService(page, true);
    // Seed the old worker's cache before the production page registers v2.
    await page.goto("/offline.html");
    await page.evaluate(async () => {
      const previous = await caches.open("lock-in-public-v1");
      await previous.add("/icon.svg");
      const unrelated = await caches.open("unrelated-cache");
      await unrelated.put("/unrelated", new Response("Keep unrelated data"));
    });
    await page.goto("/"); await tasks(page);
    await page.evaluate(async () => {
      await navigator.serviceWorker.ready;
      if (!navigator.serviceWorker.controller) await new Promise<void>(resolve => {
        navigator.serviceWorker.addEventListener("controllerchange", () => resolve(), { once: true });
      });
    });
    await page.getByRole("button", { name: "Open settings", exact: true }).click();
    await page.getByRole("button", { name: "Sign out", exact: true }).click();
    await expect(page.getByRole("heading", { name: "Lock In Bud", exact: true })).toBeVisible();
    await page.evaluate(async () => {
      await fetch("/api/session");
      await fetch("/?_rsc=cache-safety", { headers: { RSC: "1", "Next-Router-Prefetch": "1" } });
    });
    const cacheState = await page.evaluate(async () => {
      const names = await caches.keys();
      const cache = await caches.open("lock-in-public-v2");
      const shell = await cache.match("/");
      const unrelated = await caches.open("unrelated-cache");
      return { names, keys: (await cache.keys()).map(request => request.url), html: await shell?.text(), unrelated: await (await unrelated.match("/unrelated"))?.text() };
    });
    expect(cacheState.names).not.toContain("lock-in-public-v1");
    expect(cacheState.unrelated).toBe("Keep unrelated data");
    expect(cacheState.keys.some(key => key.includes("/api/") || key.includes("_rsc") || key.endsWith(".rsc"))).toBe(false);
    expect(cacheState.html).not.toContain("Offline Tester");
    expect(cacheState.html).not.toContain("Existing task");
  });
});
