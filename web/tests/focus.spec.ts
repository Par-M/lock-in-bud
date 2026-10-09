import { expect, test, type Page, type Route } from "@playwright/test";

const userId = "11111111-1111-4111-8111-111111111111";
const taskId = "22222222-2222-4222-8222-222222222222";
const otherUserId = "33333333-3333-4333-8333-333333333333";
const operationId = "44444444-4444-4444-8444-444444444444";
const timerKey = `planner.focus.v1:${userId}`;
const focus = (page: Page) => page.getByRole("navigation").getByRole("button", { name: /Focus/ }).click();

async function mock(page: Page, save: (route: Route) => Promise<void>) {
  await page.route("**/api/session", (route) => route.fulfill({ json: { id: userId, name: "Test User", email: "test@example.com" } }));
  await page.route("**/api/backend/**", (route) => {
    const path = new URL(route.request().url()).pathname;
    if (path.includes("/sync/")) return route.fulfill({ status: 404, json: { detail: "Sync is outside this mocked focus flow" } });
    if (path.endsWith("/focus/sessions") && route.request().method() === "POST") return save(route);
    return route.fulfill({
      json: path.endsWith("/focus/sessions")
        ? []
        : path.endsWith("/focus/summary")
          ? { total_duration_seconds: 0, session_count: 0 }
          : {
              items: path.endsWith("/tasks")
                ? [
                    {
                      id: taskId,
                      title: "Deep work",
                      priority: "medium",
                      status: "pending",
                      is_archived: false,
                      estimated_duration: 60,
                      actual_duration: 0,
                      category: "Work",
                      deadline: null,
                      notes: null,
                      description: null,
                      start_at: null,
                      end_at: null,
                      repeat_weekdays: null,
                      checklist: [],
                    },
                  ]
                : [],
              total: 0,
            },
    });
  });
}

test("atomic save retries the identical operation and body after a lost response and reload", async ({ page }) => {
  const bodies: Record<string, unknown>[] = [];
  const sessions = new Map<string, Record<string, unknown>>();
  let actualMinutes = 0;
  const separateTimeWrites: string[] = [];
  await mock(page, async (route) => {
    const body = route.request().postDataJSON();
    bodies.push(body);
    if (!sessions.has(body.session_id)) {
      sessions.set(body.session_id, body);
      actualMinutes += Math.floor(body.duration_seconds / 60);
    }
    if (bodies.length === 1) await route.abort("failed");
    else await route.fulfill({ json: { id: body.session_id, ...body } });
  });
  page.on("request", (request) => {
    if (request.url().includes(`/tasks/${taskId}/time`)) separateTimeWrites.push(request.url());
  });
  await page.clock.install();
  await page.goto("/");
  await focus(page);
  await page.getByRole("combobox", { name: "Task", exact: true }).selectOption(taskId);
  await page.getByRole("button", { name: "Start focus session" }).click();
  await expect(page.getByRole("button", { name: "Stop & log session", exact: true })).toBeEnabled();
  const started = await page.evaluate((key) => JSON.parse(localStorage.getItem(key)!), timerKey);
  expect(started.operationId).toMatch(/^[0-9a-f-]{36}$/);
  expect(started.sessionId).toBeUndefined();
  expect(started.ended).toBeUndefined();
  await page.clock.fastForward(125000);
  await page.getByRole("button", { name: "Stop & log session", exact: true }).click();
  await expect(page.getByRole("button", { name: "Retry save", exact: true })).toBeEnabled();
  const stopped = await page.evaluate((key) => JSON.parse(localStorage.getItem(key)!), timerKey);
  expect(stopped.operationId).toBe(started.operationId);
  expect(stopped.ended).toBeGreaterThan(stopped.started);
  expect(bodies[0]).toMatchObject({ session_id: started.operationId, record_task_time: true, task_id: taskId, duration_seconds: 125, category: "Work" });
  await page.reload();
  await focus(page);
  await expect(page.getByRole("button", { name: "Retry save", exact: true })).toBeEnabled();
  expect(bodies).toHaveLength(1);
  await page.clock.fastForward(60000);
  await page.getByRole("button", { name: "Retry save", exact: true }).click();
  await expect(page.getByRole("button", { name: "Start focus session" })).toBeVisible();
  expect(bodies).toHaveLength(2);
  expect(bodies[1]).toEqual(bodies[0]);
  expect(sessions.size).toBe(1);
  expect(actualMinutes).toBe(2);
  expect(separateTimeWrites).toEqual([]);
  expect(await page.evaluate((key) => localStorage.getItem(key), timerKey)).toBeNull();
});

test("free focus and sub-minute sessions use the same atomic contract", async ({ page }) => {
  const bodies: Record<string, unknown>[] = [];
  await mock(page, async (route) => {
    const body = route.request().postDataJSON();
    bodies.push(body);
    await route.fulfill({ json: { id: body.session_id, ...body } });
  });
  await page.clock.install();
  await page.goto("/");
  await focus(page);
  await page.getByRole("button", { name: "Start focus session" }).click();
  await expect(page.getByRole("button", { name: "Stop & log session" })).toBeEnabled();
  await page.clock.fastForward(30000);
  await page.getByRole("button", { name: "Stop & log session" }).click();
  await expect(page.getByRole("button", { name: "Start focus session" })).toBeVisible();
  await page.getByRole("combobox", { name: "Task", exact: true }).selectOption(taskId);
  await page.getByRole("button", { name: "Start focus session" }).click();
  await expect(page.getByRole("button", { name: "Stop & log session" })).toBeEnabled();
  await page.clock.fastForward(30000);
  await page.getByRole("button", { name: "Stop & log session" }).click();
  await expect(page.getByRole("button", { name: "Start focus session" })).toBeVisible();
  expect(bodies[0]).toMatchObject({ task_id: null, duration_seconds: 30, record_task_time: true });
  expect(bodies[1]).toMatchObject({ task_id: taskId, duration_seconds: 30, record_task_time: true });
  expect(bodies[1].session_id).not.toBe(bodies[0].session_id);
});

test("cross-tab save and retry are locked and replay the same persisted operation", async ({ page, context }) => {
  const bodies: Record<string, unknown>[] = [];
  let release!: () => void;
  const held = new Promise<void>((resolve) => {
    release = resolve;
  });
  const save = async (route: Route) => {
    const body = route.request().postDataJSON();
    bodies.push(body);
    if (bodies.length === 1) {
      await held;
      await route.abort("failed");
    } else await route.fulfill({ json: { id: body.session_id, ...body } });
  };
  await mock(page, save);
  await page.goto("/");
  await focus(page);
  const other = await context.newPage();
  await mock(other, save);
  await other.goto("/");
  await focus(other);
  await page.getByRole("button", { name: "Start focus session" }).click();
  await expect(other.getByRole("button", { name: "Stop & log session" })).toBeVisible();
  await page.getByRole("button", { name: "Stop & log session" }).click();
  await expect(other.getByRole("button", { name: "Retry save", exact: true })).toBeVisible();
  await other.getByRole("button", { name: "Retry save", exact: true }).click();
  await expect(other.getByRole("main").getByRole("alert")).toContainText("Another tab");
  expect(bodies).toHaveLength(1);
  release();
  await expect(page.getByRole("button", { name: "Retry save", exact: true })).toBeEnabled();
  await other.getByRole("button", { name: "Retry save", exact: true }).click();
  await expect(other.getByRole("button", { name: "Start focus session" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Start focus session" })).toBeVisible();
  expect(bodies).toHaveLength(2);
  expect(bodies[1]).toEqual(bodies[0]);
  await other.close();
});

for (const uncertain of ["session", "time"] as const) {
  test(`legacy ${uncertain} uncertainty stays review-only across reload`, async ({ page }) => {
    let writes = 0;
    await mock(page, async (route) => {
      writes++;
      await route.abort("failed");
    });
    await page.addInitScript(
      ({ key, uncertain, operationId }) => {
        if (!localStorage.getItem(key))
          localStorage.setItem(
            key,
            JSON.stringify({
              id: "legacy-run",
              started: Date.now() - 120000,
              ended: Date.now() - 60000,
              taskId: "",
              category: "Study",
              uncertain,
              ...(uncertain === "time" ? { sessionId: operationId } : {}),
            }),
          );
      },
      { key: timerKey, uncertain, operationId },
    );
    await page.goto("/");
    await focus(page);
    const saved = await page.evaluate((key) => localStorage.getItem(key), timerKey);
    await expect(page.getByRole("button", { name: "Saving disabled: review required" })).toBeDisabled();
    await expect(page.getByRole("button", { name: "Retry save", exact: true })).toHaveCount(0);
    await page.reload();
    await focus(page);
    await expect(page.getByRole("button", { name: "Saving disabled: review required" })).toBeDisabled();
    expect(writes).toBe(0);
    expect(await page.evaluate((key) => localStorage.getItem(key), timerKey)).toBe(saved);
    await page.getByRole("button", { name: "Discard pending state (no writes)" }).click();
  await page.getByRole("dialog", { name: "Confirm action" }).getByRole("button", { name: "Confirm", exact: true }).click();
    await expect(page.getByRole("button", { name: "Start focus session" })).toBeVisible();
    expect(writes).toBe(0);
  });
}

test("a running legacy timer gets an operation ID before its first write", async ({ page }) => {
  const bodies: Record<string, unknown>[] = [];
  await mock(page, async (route) => {
    const body = route.request().postDataJSON();
    bodies.push(body);
    await route.fulfill({ json: { id: body.session_id, ...body } });
  });
  await page.addInitScript((key) => localStorage.setItem(key, JSON.stringify({ started: Date.now() - 90000, taskId: "", category: "Study" })), timerKey);
  await page.goto("/");
  await focus(page);
  await page.getByRole("button", { name: "Stop & log session" }).click();
  await expect(page.getByRole("button", { name: "Start focus session" })).toBeVisible();
  expect(bodies[0].session_id).toMatch(/^[0-9a-f-]{36}$/);
  expect(bodies[0].record_task_time).toBe(true);
});

test("timer identity uses account UUID rather than email or name", async ({ page }) => {
  await mock(page, (route) => route.abort("failed"));
  let account = { id: userId, name: "Test User", email: "test@example.com" };
  await page.route("**/api/session", (route) => route.fulfill({ json: account }));
  await page.goto("/");
  await focus(page);
  await page.getByRole("button", { name: "Start focus session" }).click();
  await expect(page.getByRole("button", { name: "Stop & log session" })).toBeEnabled();
  const original = await page.evaluate((key) => localStorage.getItem(key), timerKey);
  account = { ...account, email: "renamed@example.com" };
  await page.reload();
  await focus(page);
  await expect(page.getByRole("button", { name: "Stop & log session" })).toBeVisible();
  expect(await page.evaluate((key) => localStorage.getItem(key), timerKey)).toBe(original);
  account = { ...account, id: otherUserId };
  await page.reload();
  await focus(page);
  await expect(page.getByRole("button", { name: "Start focus session" })).toBeVisible();
  await page.getByRole("button", { name: "Start focus session" }).click();
  await expect(page.getByRole("button", { name: "Stop & log session" })).toBeEnabled();
  expect(await page.evaluate((key) => localStorage.getItem(key), timerKey)).toBe(original);
  const other = await page.evaluate((key) => JSON.parse(localStorage.getItem(key)!), `planner.focus.v1:${otherUserId}`);
  expect(other.operationId).not.toBe(JSON.parse(original!).operationId);
  expect(await page.evaluate(() => localStorage.getItem("planner.focus.v1:renamed@example.com"))).toBeNull();
});

test("invalid operation ID is preserved and never sent", async ({ page }) => {
  let writes = 0;
  await mock(page, async (route) => {
    writes++;
    await route.abort("failed");
  });
  await page.addInitScript(
    (key) =>
      localStorage.setItem(key, JSON.stringify({ operationId: "invalid", started: Date.now() - 90000, ended: Date.now() - 30000, taskId: "", category: "" })),
    timerKey,
  );
  await page.goto("/");
  await focus(page);
  await expect(page.getByRole("button", { name: "Start focus session" })).toBeDisabled();
  await expect(page.getByRole("main").getByRole("alert")).toContainText("invalid");
  expect(writes).toBe(0);
  expect(await page.evaluate((key) => JSON.parse(localStorage.getItem(key)!).operationId, timerKey)).toBe("invalid");
});

test("failure to persist stopped times prevents the atomic request", async ({ page }) => {
  let writes = 0;
  await mock(page, async (route) => {
    writes++;
    await route.abort("failed");
  });
  await page.goto("/");
  await focus(page);
  await page.getByRole("button", { name: "Start focus session" }).click();
  await expect(page.getByRole("button", { name: "Stop & log session" })).toBeEnabled();
  await page.evaluate(() => {
    const original = Storage.prototype.setItem;
    Storage.prototype.setItem = function (key, value) {
      if (key.startsWith("planner.focus.")) throw new Error("Storage unavailable");
      original.call(this, key, value);
    };
  });
  await page.getByRole("button", { name: "Stop & log session" }).click();
  await expect(page.getByRole("button", { name: "Retry save", exact: true })).toBeDisabled();
  expect(writes).toBe(0);
  expect(await page.evaluate((key) => JSON.parse(localStorage.getItem(key)!).ended, timerKey)).toBeUndefined();
});
