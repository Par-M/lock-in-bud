import { expect, test, type Page } from "@playwright/test";

const day = new Date().toLocaleDateString("en-CA");
const at = (hour: number) => `${day}T${String(hour).padStart(2, "0")}:00:00`;
const task = (id = "task-1", title = "Write report") => ({
  id,
  title,
  priority: "medium",
  status: "pending",
  is_archived: false,
  estimated_duration: 60,
  actual_duration: 10,
  category: "Work",
  deadline: null,
  notes: null,
  description: "Research findings",
  start_at: null,
  end_at: null,
  checklist: [],
  repeat_weekdays: null,
  repeat_ends_on: null,
  repeat_overrides: null,
});
const preferences = {
  work_hours_start: 9,
  work_hours_end: 17,
  buffer_minutes: 10,
  energy_level: 3,
  max_daily_hours: 8,
  default_duration_minutes: 45,
  default_priority: "high",
};
const notifications = {
  morning_briefing_enabled: true,
  morning_briefing_time: "08:30:00",
  deadline_reminder_enabled: true,
  deadline_reminder_lead_hours: 24,
  overdue_alerts_enabled: true,
  fifteen_minute_reminder_enabled: true,
  fifteen_minute_reminder_lead_minutes: 15,
  reschedule_alerts_enabled: true,
};
const proposal = () => ({
  id: "plan-1",
  status: "pending",
  reasoning: "Protect your morning",
  failure_reason: null,
  retry_at: null,
  created_at: at(8),
  items: [
    { task_id: "task-1", task_title: "Write report", start: at(9), end: at(10), reason: "Top priority", accepted: false },
    { task_id: "task-2", task_title: "Read", start: at(11), end: at(12), reason: "Next step", accepted: false },
  ],
  meta: { overcommitted: true, deferred_tasks: ["Exercise"], warnings: ["Limited capacity"] },
});

async function mock(page: Page) {
  const writes: { path: string; method: string; body: Record<string, unknown> | null }[] = [];
  await page.route("**/api/session", (route) =>
    route.fulfill({ json: { id: "11111111-1111-4111-8111-111111111111", name: "Test User", email: "test@example.com" } }),
  );
  await page.route("**/api/backend/**", (route) => {
    const url = new URL(route.request().url());
    const path = url.pathname.replace("/api/backend", "");
    if (path.startsWith("/sync/")) return route.fulfill({ status: 404, json: { detail: "Sync is outside these mocked planner operations" } });
    const method = route.request().method();
    if (method !== "GET") writes.push({ path, method, body: route.request().postData() ? route.request().postDataJSON() : null });
    const data =
      path === "/tasks"
        ? method === "GET"
          ? { items: url.searchParams.get("archived") ? [] : [task()], total: 1 }
          : { ...task("new-task"), ...route.request().postDataJSON() }
        : path === "/preferences"
          ? preferences
          : path === "/notifications/preferences"
            ? notifications
            : path === "/focus/sessions"
              ? []
              : path === "/focus/summary"
                ? { total_duration_seconds: 0, session_count: 0 }
                : path === "/habits/dashboard"
                  ? { habits: [] }
                  : path.startsWith("/tasks/")
                    ? task()
                    : { items: [], total: 0 };
    return route.fulfill({ json: data });
  });
  return writes;
}
const navigate = (page: Page, tab: string) => page.getByRole("navigation").getByRole("button", { name: tab, exact: true }).click();

test("persisted proposals resume, redo, accept individually/all, generate and reject", async ({ page }) => {
  await mock(page);
  let plan = proposal();
  let pending = true;
  const operations: string[] = [];
  let generation: Record<string, unknown> | undefined;
  await page.route("**/api/backend/schedule/**", (route) => {
    const path = new URL(route.request().url()).pathname;
    if (route.request().method() === "GET") return route.fulfill({ json: { items: pending ? [plan] : [], total: pending ? 1 : 0 } });
    operations.push(path);
    if (path.endsWith("/generate")) {
      generation = route.request().postDataJSON();
      plan = proposal();
      pending = true;
    }
    if (path.endsWith("/redo")) plan.items[0].reason = "Revised slot";
    if (path.endsWith("/items/0/accept")) plan.items[0].accepted = true;
    if (path.endsWith("/plan-1/accept")) {
      plan.status = "accepted";
      pending = false;
    }
    if (path.endsWith("/reject")) {
      plan.status = "rejected";
      pending = false;
    }
    return route.fulfill({ json: path.endsWith("/accept") ? { recommendation: plan, blocks: [] } : plan });
  });
  await page.goto("/");
  await expect(
    page.getByText(
      "Plans begin today and cover at least the next week, extending to task deadlines. Dates select your calendar view, not the schedule horizon.",
    ),
  ).toBeVisible();
  await expect(page.getByLabel("Plan through")).toHaveCount(0);
  await expect(page.getByText("Protect your morning")).toBeVisible();
  await expect(page.getByText("Deferred: Exercise")).toBeVisible();
  await page.getByRole("button", { name: "Redo Write report", exact: true }).click();
  await expect(page.getByText("Revised slot")).toBeVisible();
  await page.getByRole("button", { name: "Accept Write report", exact: true }).click();
  await expect(page.getByRole("button", { name: "Accept Write report", exact: true })).toBeDisabled();
  await page.reload();
  await expect(page.getByText("Accepted", { exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Accept all", exact: true }).click();
  await expect(page.getByText("No pending proposals.", { exact: false })).toBeVisible();
  await page.getByRole("button", { name: "Generate schedule proposal" }).click();
  await expect(page.getByText("Protect your morning")).toBeVisible();
  expect(generation).toMatchObject({ start_date: day, end_date: day, busy_times: [] });
  expect(typeof generation?.timezone).toBe("string");
  await page.getByRole("button", { name: "Reject proposal", exact: true }).click();
  await expect(page.getByText("No pending proposals.", { exact: false })).toBeVisible();
  expect(operations.map((p) => p.split("/schedule")[1])).toEqual([
    "/recommendations/plan-1/items/0/redo",
    "/recommendations/plan-1/items/0/accept",
    "/recommendations/plan-1/accept",
    "/generate",
    "/recommendations/plan-1/reject",
  ]);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
});

test("proposal errors preserve review and reload checks uncertain outcomes", async ({ page }) => {
  await mock(page);
  await page.route("**/api/backend/schedule/recommendations?*", (route) => route.fulfill({ json: { items: [proposal()] } }));
  await page.route("**/api/backend/schedule/recommendations/plan-1/accept", (route) => route.fulfill({ status: 409, json: { detail: "Slot conflict" } }));
  await page.goto("/");
  await page.getByRole("button", { name: "Accept all", exact: true }).click();
  await expect(page.getByRole("region", { name: "Schedule proposals" }).getByRole("alert")).toContainText("Slot conflict");
  await expect(page.getByText("Protect your morning")).toBeVisible();
  await page.getByRole("button", { name: "Reload pending proposals" }).click();
  await expect(page.getByRole("region", { name: "Schedule proposals" }).getByRole("alert")).toHaveCount(0);
});

test("failed generation shows server retry information without acceptance", async ({ page }) => {
  await mock(page);
  await page.route("**/api/backend/schedule/generate", (route) =>
    route.fulfill({
      json: {
        ...proposal(),
        status: "failed",
        failure_reason: "Provider unavailable",
        retry_at: at(12),
        message: "A new plan will be attempted automatically.",
      },
    }),
  );
  await page.goto("/");
  await page.getByRole("button", { name: "Generate schedule proposal" }).click();
  await expect(page.getByText(/Provider unavailable/)).toBeVisible();
  await expect(page.getByText(/Try again after/)).toBeVisible();
  await expect(page.getByText(/Retry scheduled/)).toHaveCount(0);
  await expect(page.getByText(/attempted automatically/)).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Accept all", exact: true })).toBeDisabled();
});

for (const operation of ["items/0/accept", "items/0/redo", "reject"]) {
  test(`proposal ${operation} errors preserve items and accepted flags`, async ({ page }) => {
    await mock(page);
    await page.route("**/api/backend/schedule/recommendations?*", (route) => route.fulfill({ json: { items: [proposal()] } }));
    await page.route(`**/api/backend/schedule/recommendations/plan-1/${operation}`, (route) =>
      route.fulfill({ status: 409, json: { detail: "Proposal changed" } }),
    );
    await page.goto("/");
    const name = operation === "reject" ? "Reject proposal" : operation.endsWith("redo") ? "Redo Write report" : "Accept Write report";
    await page.getByRole("button", { name, exact: true }).click();
    const region = page.getByRole("region", { name: "Schedule proposals" });
    await expect(region.getByRole("alert")).toContainText("Proposal changed");
    await expect(region.getByText("Top priority", { exact: true })).toBeVisible();
    await expect(region.getByText("Accepted", { exact: true })).toHaveCount(0);
  });
}

test("daily advice ignores a stale response after changing date and returning", async ({ page }) => {
  await mock(page);
  let release!: () => void;
  const held = new Promise<void>((resolve) => {
    release = resolve;
  });
  let started!: () => void;
  const requested = new Promise<void>((resolve) => {
    started = resolve;
  });
  await page.route("**/api/backend/recommendations/daily", async (route) => {
    const date = route.request().postDataJSON().start_date.slice(0, 10);
    started();
    await held;
    await route.fulfill({
      json: {
        days: [
          {
            date,
            available_minutes: 60,
            items: [{ task_id: "task-1", task_title: "Stale advice", part_title: null, minutes: 60, reason: "old response", start_at: at(9), end_at: at(10) }],
          },
        ],
        unscheduled: [],
      },
    });
  });
  await page.goto("/");
  await page.getByRole("button", { name: "Generate", exact: true }).click();
  await requested;
  const calendar = page.getByRole("region", { name: "Month calendar" });
  await calendar.locator('button[aria-pressed="false"]').first().click();
  await page.getByRole("button", { name: "Go to today" }).click();
  const response = page.waitForResponse("**/api/backend/recommendations/daily");
  release();
  await response;
  await expect(page.getByRole("button", { name: "Generate", exact: true })).toBeEnabled();
  await expect(page.getByText("Stale advice")).toHaveCount(0);
});

test("task defaults, description search, explicit status transitions and actual time", async ({ page }) => {
  const writes = await mock(page);
  await page.goto("/");
  await navigate(page, "Tasks");
  await page.getByRole("button", { name: "New task", exact: true }).click();
  const create = page.getByRole("dialog", { name: "New task", exact: true });
  await expect(create.getByRole("combobox", { name: "Priority", exact: true })).toHaveValue("high");
  await expect(create.getByLabel("Estimated minutes")).toHaveValue("45");
  await create.getByLabel("Title", { exact: true }).fill("New work");
  await create.getByRole("combobox", { name: "Status", exact: true }).selectOption("in_progress");
  await create.getByRole("button", { name: "Create task", exact: true }).click();
  await expect(create).toHaveCount(0);
  await expect.poll(() => writes.some((w) => w.path === "/tasks/new-task/start")).toBe(true);
  await page.getByRole("searchbox", { name: "Search tasks" }).fill("Research findings");
  await expect(page.getByRole("button", { name: "Write report", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Edit Write report", exact: true }).click();
  const edit = page.getByRole("dialog", { name: "Edit task", exact: true });
  await edit.getByLabel("Actual minutes").fill("35");
  await edit.getByRole("combobox", { name: "Status", exact: true }).selectOption("completed");
  await edit.getByRole("button", { name: "Save changes", exact: true }).click();
  await expect(edit).toHaveCount(0);
  expect(writes.find((w) => w.path === "/tasks/task-1" && w.method === "PATCH")?.body).toMatchObject({ actual_duration: 35 });
  expect(writes.some((w) => w.path === "/tasks/task-1/complete")).toBe(true);
  await page.getByRole("button", { name: "Start task Write report" }).click();
  await expect.poll(() => writes.some((w) => w.path === "/tasks/task-1/start")).toBe(true);
  await expect(page.getByRole("button", { name: "Start task Write report" })).toBeEnabled();
});

test("task sort fields and both directions reach the backend", async ({ page }) => {
  await mock(page);
  const queries: string[] = [];
  page.on("request", (request) => {
    if (request.url().includes("/api/backend/tasks?")) queries.push(request.url());
  });
  await page.goto("/");
  await navigate(page, "Tasks");
  await page.getByRole("combobox", { name: "Sort tasks", exact: true }).selectOption("updated_at");
  await expect.poll(() => queries.some((q) => q.includes("sort=updated_at&order=desc"))).toBe(true);
  await page.getByRole("combobox", { name: "Sort tasks", exact: true }).selectOption("category");
  await page.getByLabel("Sort direction").selectOption("asc");
  await expect.poll(() => queries.some((q) => q.includes("sort=category&order=asc"))).toBe(true);
});

test("task edit errors keep unsaved actual minutes and description", async ({ page }) => {
  await mock(page);
  await page.route("**/api/backend/tasks/task-1", (route) => route.fulfill({ status: 422, json: { detail: "Cannot update task" } }));
  await page.goto("/");
  await navigate(page, "Tasks");
  await page.getByRole("button", { name: "Edit Write report", exact: true }).click();
  const dialog = page.getByRole("dialog", { name: "Edit task", exact: true });
  await dialog.getByLabel("Actual minutes").fill("23");
  await dialog.getByRole("textbox", { name: "Description", exact: true }).fill("Keep my text");
  await dialog.getByRole("button", { name: "Save changes", exact: true }).click();
  await expect(dialog.getByRole("alert")).toContainText("Cannot update task");
  await expect(dialog.getByLabel("Actual minutes")).toHaveValue("23");
  await expect(dialog.getByRole("textbox", { name: "Description", exact: true })).toHaveValue("Keep my text");
});

test("manual blocks create/edit and repeat occurrence scopes use exact contracts", async ({ page }) => {
  const writes = await mock(page);
  const repeated = { ...task("repeat-1", "Daily reading"), start_at: at(13), end_at: at(14), repeat_weekdays: [0, 1, 2, 3, 4, 5, 6] };
  await page.route("**/api/backend/tasks?*", (route) => route.fulfill({ json: { items: [task(), repeated] } }));
  await page.route("**/api/backend/calendar/blocks", (route) =>
    route.request().method() === "GET"
      ? route.fulfill({ json: { items: [{ id: "block-1", task_id: "task-1", title: "Report time", start_at: at(9), end_at: at(10), completed_at: null }] } })
      : route.fallback(),
  );
  await page.goto("/");
  await page.getByRole("button", { name: "Add block", exact: true }).click();
  const add = page.getByRole("dialog", { name: "Schedule a task" });
  await add.getByRole("combobox", { name: "Task", exact: true }).selectOption("task-1");
  await add.getByRole("button", { name: "Add to schedule" }).click();
  await expect(add).toHaveCount(0);
  expect(writes.find((w) => w.path === "/calendar/blocks")?.body).toMatchObject({ task_id: "task-1", title: "Write report" });
  await page.getByRole("button", { name: "Edit block Report time" }).click();
  const block = page.getByRole("dialog", { name: "Edit schedule block" });
  await block.getByLabel("Block title").fill("Updated block");
  await block.getByLabel("End", { exact: true }).fill(`${day}T08:00`);
  await block.getByRole("button", { name: "Save block" }).click();
  await expect(block.getByRole("alert")).toContainText("End time");
  await block.getByLabel("End", { exact: true }).fill(`${day}T10:30`);
  await block.getByRole("button", { name: "Save block" }).click();
  await expect(block).toHaveCount(0);
  expect(writes.find((w) => w.path === "/calendar/blocks/block-1")?.body).toMatchObject({ title: "Updated block", start_at: at(9) });
  for (const scope of ["this_event_only", "from_now_onwards"]) {
    await page.getByRole("button", { name: "Edit occurrence Daily reading" }).click();
    const occurrence = page.getByRole("dialog", { name: "Edit repeating occurrence" });
    await occurrence.getByLabel("Apply to").selectOption(scope);
    await occurrence.getByLabel("Start", { exact: true }).fill(`${day}T12:30`);
    await occurrence.getByRole("button", { name: "Save occurrence" }).click();
    await expect(occurrence).toHaveCount(0);
    expect(writes.filter((w) => w.path === "/tasks/repeat-1/occurrence").at(-1)?.body).toMatchObject({ date: day, scope, timezone: expect.any(String) });
  }
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
});

test("reschedule/snooze preserve errors and send remaining work, reason, timezone", async ({ page }) => {
  const writes = await mock(page);
  let fail = true;
  await page.route("**/api/backend/tasks/task-1/reschedule", (route) =>
    fail ? route.fulfill({ status: 409, json: { detail: "No available time" } }) : route.fallback(),
  );
  await page.goto("/");
  await navigate(page, "Tasks");
  await page.getByRole("button", { name: "Reschedule Write report" }).click();
  const dialog = page.getByRole("dialog", { name: "Reschedule task" });
  await dialog.getByLabel("Remaining minutes").fill("25");
  await dialog.getByLabel("Reason", { exact: true }).fill("Need more time");
  await dialog.getByRole("button", { name: "Replan remaining work" }).click();
  await expect(dialog.getByRole("alert")).toContainText("No available time");
  await expect(dialog.getByLabel("Reason", { exact: true })).toHaveValue("Need more time");
  fail = false;
  await dialog.getByRole("button", { name: "Replan remaining work" }).click();
  await expect(dialog).toHaveCount(0);
  expect(writes.find((w) => w.path.endsWith("/reschedule"))?.body).toMatchObject({
    minutes_remaining: 25,
    reason: "Need more time",
    timezone: expect.any(String),
  });
  await page.getByRole("button", { name: "Reschedule Write report" }).click();
  await dialog.getByLabel("Snooze minutes").fill("30");
  await dialog.getByRole("button", { name: "Snooze task", exact: true }).click();
  await expect(dialog).toHaveCount(0);
  expect(writes.find((w) => w.path.endsWith("/snooze"))?.body).toMatchObject({ minutes: 30 });
});

test("block and occurrence server errors keep edited times and scope", async ({ page }) => {
  await mock(page);
  await page.route("**/api/backend/tasks?*", (route) =>
    route.fulfill({ json: { items: [{ ...task("repeat-1", "Daily reading"), start_at: at(13), end_at: at(14), repeat_weekdays: [0, 1, 2, 3, 4, 5, 6] }] } }),
  );
  await page.route("**/api/backend/calendar/blocks", (route) =>
    route.fulfill({ json: { items: [{ id: "block-1", task_id: "task-1", title: "Report time", start_at: at(9), end_at: at(10), completed_at: null }] } }),
  );
  await page.route("**/api/backend/calendar/blocks/block-1", (route) => route.fulfill({ status: 409, json: { detail: "Block conflict" } }));
  await page.route("**/api/backend/tasks/repeat-1/occurrence", (route) => route.fulfill({ status: 409, json: { detail: "Occurrence conflict" } }));
  await page.goto("/");
  await page.getByRole("button", { name: "Edit block Report time" }).click();
  const block = page.getByRole("dialog", { name: "Edit schedule block" });
  await block.getByLabel("Block title").fill("Keep block title");
  await block.getByLabel("End", { exact: true }).fill(`${day}T10:30`);
  await block.getByRole("button", { name: "Save block" }).click();
  await expect(block.getByRole("alert")).toContainText("Block conflict");
  await expect(block.getByLabel("Block title")).toHaveValue("Keep block title");
  await block.getByRole("button", { name: "Close Edit schedule block" }).click();
  await page.getByRole("button", { name: "Edit occurrence Daily reading" }).click();
  const occurrence = page.getByRole("dialog", { name: "Edit repeating occurrence" });
  await occurrence.getByLabel("Apply to").selectOption("from_now_onwards");
  await occurrence.getByLabel("End", { exact: true }).fill(`${day}T14:30`);
  await occurrence.getByRole("button", { name: "Save occurrence" }).click();
  await expect(occurrence.getByRole("alert")).toContainText("Occurrence conflict");
  await expect(occurrence.getByLabel("Apply to")).toHaveValue("from_now_onwards");
  await expect(occurrence.getByLabel("End", { exact: true })).toHaveValue(`${day}T14:30`);
});

test("block completion, reopening and deletion use explicit routes", async ({ page }) => {
  const writes = await mock(page);
  let completed = false;
  let deleted = false;
  await page.route("**/api/backend/calendar/blocks", (route) =>
    route.fulfill({
      json: {
        items: deleted
          ? []
          : [{ id: "block-1", task_id: "task-1", title: "Report time", start_at: at(9), end_at: at(10), completed_at: completed ? at(10) : null }],
      },
    }),
  );
  await page.route("**/api/backend/calendar/blocks/block-1/**", (route) => {
    completed = route.request().url().endsWith("/complete");
    return route.fallback();
  });
  await page.route("**/api/backend/calendar/blocks/block-1", (route) => {
    deleted = true;
    return route.fallback();
  });
  await page.goto("/");
  await page.getByRole("button", { name: `Complete Report time on ${day}`, exact: true }).click();
  await page.getByRole("button", { name: `Reopen Report time on ${day}`, exact: true }).click();
  await expect(page.getByRole("button", { name: `Complete Report time on ${day}`, exact: true })).toBeVisible();
  page.once("dialog", (d) => d.accept());
  await page.getByRole("button", { name: "Delete block Report time" }).click();
  await expect(page.getByRole("heading", { name: "Report time", exact: true })).toHaveCount(0);
  expect(writes.map((w) => w.path)).toEqual(["/calendar/blocks/block-1/complete", "/calendar/blocks/block-1/reopen", "/calendar/blocks/block-1"]);
});

test("moved repeat overrides and overnight spillovers retain original occurrence date", async ({ page }) => {
  const writes = await mock(page);
  const previous = new Date(`${day}T00:00:00`);
  previous.setDate(previous.getDate() - 1);
  const source = previous.toLocaleDateString("en-CA");
  await page.route("**/api/backend/tasks?*", (route) =>
    route.fulfill({
      json: {
        items: [
          {
            ...task("moved", "Moved reading"),
            start_at: `${source}T09:00:00`,
            end_at: `${source}T10:00:00`,
            repeat_weekdays: [previous.getDay()],
            repeat_overrides: { [source]: { start_at: at(15), end_at: at(16) } },
          },
          { ...task("overnight", "Night shift"), start_at: `${source}T23:00:00`, end_at: at(1), repeat_weekdays: [previous.getDay()] },
        ],
      },
    }),
  );
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Moved reading", exact: true })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Night shift", exact: true })).toBeVisible();
  await page.getByRole("button", { name: `Complete Moved reading on ${source}`, exact: true }).click();
  await expect.poll(() => writes.some((w) => w.path === "/tasks/moved/occurrence/completion")).toBe(true);
  await expect(page.getByRole("button", { name: `Complete Moved reading on ${source}`, exact: true })).toBeEnabled();
  expect(writes.find((w) => w.path === "/tasks/moved/occurrence/completion")?.body).toMatchObject({ date: source, completed: true });
  await page.getByRole("button", { name: "Edit occurrence Moved reading" }).click();
  const dialog = page.getByRole("dialog", { name: "Edit repeating occurrence" });
  await expect(dialog.getByLabel("Start", { exact: true })).toHaveValue(`${day}T15:00`);
  await dialog.getByRole("button", { name: "Save occurrence" }).click();
  await expect(dialog).toHaveCount(0);
  expect(writes.find((w) => w.path === "/tasks/moved/occurrence")?.body).toMatchObject({ date: source });
});

test("habit edit, reorder, complete, reset and manual count", async ({ page }) => {
  const writes = await mock(page);
  const habits = ["Read", "Walk"].map((title, i) => ({
    habit: { id: `habit-${i}`, title, daily_goal: 3, repeat_weekdays: null },
    current_streak: 1,
    best_streak: 2,
    completion_rate_30d: 0.5,
    scheduled_7d: 7,
    completed_7d: 2,
    last_7_days: [{ date: day, scheduled: true, completed_count: 1 }],
  }));
  await page.route("**/api/backend/habits/dashboard?*", (route) => route.fulfill({ json: { habits } }));
  await page.goto("/");
  await navigate(page, "Habits");
  await page.getByRole("button", { name: "Edit habit Read" }).click();
  const dialog = page.getByRole("dialog", { name: "Edit habit" });
  await dialog.getByLabel("Habit name").fill("Read books");
  await dialog.getByLabel("Daily goal").fill("4");
  await dialog.getByRole("button", { name: "Mon", exact: true }).click();
  await dialog.getByRole("button", { name: "Save habit" }).click();
  await expect(dialog).toHaveCount(0);
  expect(writes.find((w) => w.path === "/habits/habit-0")?.body).toMatchObject({ title: "Read books", daily_goal: 4, repeat_weekdays: [1] });
  await page.getByRole("button", { name: "Move Read down" }).click();
  await expect.poll(() => writes.some((w) => w.path === "/habits/reorder")).toBe(true);
  await expect(page.getByRole("button", { name: "Move Read down" })).toBeEnabled();
  expect(writes.find((w) => w.path === "/habits/reorder")?.body).toEqual({ habit_ids: ["habit-1", "habit-0"] });
  await page.getByRole("button", { name: "Complete habit Read today" }).click();
  await expect.poll(() => writes.some((w) => w.body?.count === 3)).toBe(true);
  await expect(page.getByRole("button", { name: "Complete habit Read today" })).toBeEnabled();
  page.once("dialog", (d) => d.accept());
  await page.getByRole("button", { name: "Reset habit Read today" }).click();
  await expect.poll(() => writes.some((w) => w.body?.count === 0)).toBe(true);
  await expect(page.getByRole("button", { name: "Reset habit Read today" })).toBeEnabled();
  await expect(page.getByRole("button", { name: "Refresh habits", exact: true })).toBeEnabled();
  const card = page.locator("article").filter({ has: page.getByRole("heading", { name: "Read", exact: true }) });
  await card.getByLabel("Today", { exact: true }).fill("2");
  await card.getByRole("button", { name: "Set count" }).click();
  await expect.poll(() => writes.some((w) => w.body?.count === 2)).toBe(true);
  await expect(card.getByRole("button", { name: "Set count" })).toBeEnabled();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
});

test("focus edit/delete, category analytics never rewrite task actual time", async ({ page }) => {
  const writes = await mock(page);
  let sessions = [
    { id: "session-1", task_id: "task-1", started_at: at(9), ended_at: at(10), duration_seconds: 3600, category: "Work" },
    { id: "session-2", task_id: null, started_at: at(11), ended_at: at(12), duration_seconds: 3600, category: "Study" },
  ];
  await page.route("**/api/backend/focus/sessions?*", (route) => route.fulfill({ json: sessions }));
  await page.route("**/api/backend/focus/summary?*", (route) =>
    route.fulfill({ json: { total_duration_seconds: 7200, session_count: 2, analysis: "Do not show insight" } }),
  );
  let fail = true;
  await page.route("**/api/backend/focus/sessions/session-1", (route) => {
    if (fail) return route.fulfill({ status: 422, json: { detail: "Could not save session" } });
    if (route.request().method() === "DELETE") sessions = sessions.filter((s) => s.id !== "session-1");
    return route.fallback();
  });
  await page.goto("/");
  await navigate(page, "Focus");
  await page.getByLabel("Focus category").selectOption("Work");
  await expect(page.getByRole("button", { name: "Edit focus session session-2" })).toHaveCount(0);
  await expect(page.getByText("Work: 60 min", { exact: true })).toBeVisible();
  await expect(page.getByRole("meter")).toHaveCount(1);
  await page.getByRole("button", { name: "Edit focus session session-1" }).click();
  const dialog = page.getByRole("dialog", { name: "Edit focus session" });
  await dialog.getByLabel("Ended", { exact: true }).fill(`${day}T10:30`);
  await dialog.getByRole("button", { name: "Save session" }).click();
  await expect(dialog.getByRole("alert")).toContainText("Could not save session");
  await expect(dialog.getByLabel("Ended", { exact: true })).toHaveValue(`${day}T10:30`);
  fail = false;
  await dialog.getByRole("button", { name: "Save session" }).click();
  await expect(dialog).toHaveCount(0);
  expect(writes.find((w) => w.path === "/focus/sessions/session-1")?.body).toMatchObject({ started_at: at(9), ended_at: expect.any(String) });
  page.once("dialog", (d) => d.accept());
  await page.getByRole("button", { name: "Delete focus session session-1" }).click();
  await expect(page.getByRole("button", { name: "Edit focus session session-1" })).toHaveCount(0);
  expect(writes.some((w) => w.path.startsWith("/tasks/"))).toBe(false);
  await expect(page.getByText("Do not show insight")).toHaveCount(0);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
});

test("habit edit and reorder failures preserve form and existing order", async ({ page }) => {
  await mock(page);
  const habits = ["Read", "Walk"].map((title, i) => ({
    habit: { id: `habit-${i}`, title, daily_goal: 1, repeat_weekdays: null },
    current_streak: 0,
    best_streak: 0,
    completion_rate_30d: 0,
    scheduled_7d: 7,
    completed_7d: 0,
    last_7_days: [],
  }));
  await page.route("**/api/backend/habits/dashboard?*", (route) => route.fulfill({ json: { habits } }));
  await page.route("**/api/backend/habits/habit-0", (route) => route.fulfill({ status: 422, json: { detail: "Habit could not be saved" } }));
  await page.route("**/api/backend/habits/reorder", (route) => route.fulfill({ status: 409, json: { detail: "Order could not be saved" } }));
  await page.goto("/");
  await navigate(page, "Habits");
  await page.getByRole("button", { name: "Edit habit Read" }).click();
  const dialog = page.getByRole("dialog", { name: "Edit habit" });
  await dialog.getByLabel("Habit name").fill("Keep habit name");
  await dialog.getByRole("button", { name: "Save habit" }).click();
  await expect(dialog.getByRole("alert")).toContainText("Habit could not be saved");
  await expect(dialog.getByLabel("Habit name")).toHaveValue("Keep habit name");
  await dialog.getByRole("button", { name: "Close Edit habit" }).click();
  await page.getByRole("button", { name: "Move Read down" }).click();
  await expect(page.getByRole("main").getByRole("alert")).toContainText("Order could not be saved");
  await expect(page.locator(".habit-grid article h2")).toHaveText(["Read", "Walk"]);
});

test("notification preferences preserve failed edits, save all fields and expose privacy/categories", async ({ page }) => {
  const writes = await mock(page);
  let fail = true;
  await page.route("**/api/backend/notifications/preferences", (route) =>
    route.request().method() === "PATCH" && fail ? route.fulfill({ status: 422, json: { detail: "Unable to update reminders" } }) : route.fallback(),
  );
  await page.goto("/");
  await page.getByRole("button", { name: "Open settings" }).click();
  const dialog = page.getByRole("dialog", { name: "Settings", exact: true });
  await dialog.getByLabel("Morning briefing", { exact: true }).uncheck();
  await dialog.getByLabel("Morning briefing time", { exact: true }).fill("07:45");
  await dialog.getByLabel("Deadline lead hours").fill("12");
  await dialog.getByLabel("Upcoming reminder lead minutes").fill("20");
  await dialog.getByRole("button", { name: "Save notification preferences" }).click();
  await expect(dialog.getByRole("alert")).toContainText("Unable to update reminders");
  await expect(dialog.getByLabel("Morning briefing", { exact: true })).not.toBeChecked();
  fail = false;
  await dialog.getByRole("button", { name: "Save notification preferences" }).click();
  await expect(dialog.getByText("Notification preferences saved.")).toBeVisible();
  expect(writes.find((w) => w.path === "/notifications/preferences")?.body).toMatchObject({
    morning_briefing_enabled: false,
    morning_briefing_time: "07:45",
    deadline_reminder_lead_hours: 12,
    fifteen_minute_reminder_lead_minutes: 20,
  });
  await expect(dialog.getByRole("heading", { name: "AI privacy" })).toBeVisible();
  await expect(dialog.getByRole("heading", { name: "Category suggestions" })).toBeVisible();
  await dialog.getByRole("button", { name: "Close Settings" }).click();
  await navigate(page, "Tasks");
  await page.getByRole("button", { name: "New task", exact: true }).click();
  await expect(page.getByLabel("Category", { exact: true })).toHaveAttribute("list", "planner-categories");
  await expect(page.locator("#planner-categories option")).toHaveAttribute("value", "Work");
});

test("independent category suggestions persist per account, remove labels only from suggestions, and can be restored", async ({ page }) => {
  const writes = await mock(page);
  let account = { id: "11111111-1111-4111-8111-111111111111", name: "Test User", email: "test@example.com" };
  await page.route("**/api/session", (route) => route.fulfill({ json: account }));
  await page.goto("/");
  await page.getByRole("button", { name: "Open settings" }).click();
  const dialog = page.getByRole("dialog", { name: "Settings", exact: true });
  await dialog.getByLabel("New category", { exact: true }).fill("  Study  ");
  await dialog.getByRole("button", { name: "Add category suggestion" }).click();
  await expect(dialog.getByRole("button", { name: "Remove category suggestion Study" })).toBeVisible();
  page.once("dialog", (d) => d.accept());
  await dialog.getByRole("button", { name: "Remove category suggestion Work" }).click();
  await expect(page.locator("#planner-categories option")).toHaveAttribute("value", "Study");
  await dialog.getByRole("button", { name: "Close Settings" }).click();
  await navigate(page, "Tasks");
  await expect(page.locator(".task-meta").getByText("Work", { exact: true })).toBeVisible();
  account = { ...account, email: "renamed@example.com" };
  await page.reload();
  await page.getByRole("button", { name: "Open settings" }).click();
  await expect(dialog.getByRole("button", { name: "Remove category suggestion Study" })).toBeVisible();
  await expect(dialog.getByRole("button", { name: "Remove category suggestion Work" })).toHaveCount(0);
  await dialog.getByLabel("New category", { exact: true }).fill("Work");
  await dialog.getByRole("button", { name: "Add category suggestion" }).click();
  await expect(dialog.getByRole("button", { name: "Remove category suggestion Work" })).toBeVisible();
  account = { ...account, id: "33333333-3333-4333-8333-333333333333" };
  await page.reload();
  await page.getByRole("button", { name: "Open settings" }).click();
  await expect(dialog.getByRole("button", { name: "Remove category suggestion Study" })).toHaveCount(0);
  await expect(dialog.getByRole("button", { name: "Remove category suggestion Work" })).toBeVisible();
  expect(writes).toEqual([]);
});

test("category storage failures preserve input and do not claim a saved suggestion", async ({ page }) => {
  await mock(page);
  await page.addInitScript(() => {
    const original = Storage.prototype.setItem;
    Storage.prototype.setItem = function (key, value) {
      if (key.startsWith("planner.categories.")) throw new Error("Storage denied");
      original.call(this, key, value);
    };
  });
  await page.goto("/");
  await page.getByRole("button", { name: "Open settings" }).click();
  const dialog = page.getByRole("dialog", { name: "Settings", exact: true });
  await dialog.getByLabel("New category", { exact: true }).fill("Keep my category");
  await dialog.getByRole("button", { name: "Add category suggestion" }).click();
  await expect(dialog.getByRole("alert")).toContainText("Category suggestions could not be saved");
  await expect(dialog.getByLabel("New category", { exact: true })).toHaveValue("Keep my category");
  await expect(dialog.getByRole("button", { name: "Remove category suggestion Keep my category" })).toHaveCount(0);
});

test("offline task-change events reload tasks, ignore superseded reads, and do not loop", async ({ page }) => {
  await mock(page);
  let title = "Original task";
  let reads = 0;
  let holdNext = false;
  let release!: () => void;
  const held = new Promise<void>((resolve) => {
    release = resolve;
  });
  let started!: () => void;
  const requested = new Promise<void>((resolve) => {
    started = resolve;
  });
  await page.route("**/api/backend/tasks?*", async (route) => {
    if (new URL(route.request().url()).searchParams.get("archived")) {
      await route.fulfill({ json: { items: [] } });
      return;
    }
    reads++;
    const snapshot = task("task-1", title);
    if (holdNext) {
      holdNext = false;
      started();
      await held;
    }
    await route.fulfill({ json: { items: [snapshot] } });
  });
  await page.goto("/");
  const initialTasksLoad = page.waitForResponse(response => new URL(response.url()).searchParams.get("archived") === "true");
  await navigate(page, "Tasks");
  await initialTasksLoad;
  await expect(page.getByRole("button", { name: "Original task", exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "Refresh tasks", exact: true })).toBeEnabled();
  const initialReads = reads;
  title = "Stale sync snapshot";
  holdNext = true;
  await page.evaluate(() => window.dispatchEvent(new Event("tasks-offline-changed")));
  await requested;
  title = "Synced server task";
  await page.evaluate(() => window.dispatchEvent(new Event("tasks-offline-changed")));
  release();
  await expect(page.getByRole("button", { name: "Synced server task", exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "Refresh tasks", exact: true })).toBeEnabled();
  await expect(page.getByRole("button", { name: "Stale sync snapshot", exact: true })).toHaveCount(0);
  expect(reads).toBe(initialReads + 2);
});

test("scheduling preferences accept 24-hour boundaries but reject reversed hours and values above 24", async ({ page }) => {
  const writes = await mock(page);
  await page.goto("/");
  await page.getByRole("button", { name: "Open settings" }).click();
  const dialog = page.getByRole("dialog", { name: "Settings", exact: true });
  const start = dialog.getByLabel("Work starts (hour)", { exact: true });
  const end = dialog.getByLabel("Work ends (hour)", { exact: true });
  await expect(start).toHaveAttribute("max", "24");
  await expect(end).toHaveAttribute("max", "24");
  await start.fill("24");
  await end.fill("24");
  await dialog.getByRole("button", { name: "Save preferences", exact: true }).click();
  await expect(dialog.getByRole("alert")).toContainText("Work hours must end after they start");
  expect(writes.filter((write) => write.path === "/preferences")).toEqual([]);
  await start.fill("0");
  await end.fill("25");
  expect(await end.evaluate((input) => (input as HTMLInputElement).validity.rangeOverflow)).toBe(true);
  await dialog.getByRole("button", { name: "Save preferences", exact: true }).click();
  expect(writes.filter((write) => write.path === "/preferences")).toEqual([]);
  await end.fill("24");
  await dialog.getByRole("button", { name: "Save preferences", exact: true }).click();
  await expect(dialog.getByText("Preferences saved.", { exact: true })).toBeVisible();
  await expect(dialog.getByRole("button", { name: "Save preferences", exact: true })).toBeEnabled();
  expect(writes.find((write) => write.path === "/preferences")?.body).toMatchObject({ work_hours_start: 0, work_hours_end: 24 });
});
