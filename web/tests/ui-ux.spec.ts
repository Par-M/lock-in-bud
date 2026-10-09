import { test, expect } from "@playwright/test";
const user = "11111111-1111-4111-8111-111111111111";
const taskId = "22222222-2222-4222-8222-222222222222";
const key = `planner.focus.v1:${user}`;
const today = new Date(); today.setHours(23, 59, 59, 0);
const tomorrow = new Date(today); tomorrow.setDate(today.getDate() + 1);
const yesterday = new Date(today); yesterday.setDate(today.getDate() - 1);
const task = (id: string, title: string, deadline: string | null) => ({ id, title, deadline, status: "pending", priority: "medium", is_archived: false, estimated_duration: 30, actual_duration: 30, category: null, start_at: null, end_at: null, notes: null, description: null, checklist: [{ text: "Review", done: false }], repeat_weekdays: null, repeat_ends_on: null });

test.beforeEach(async ({ page }) => {
  await page.route("https://accounts.google.com/**", r => r.abort());
  await page.route("**/api/session", r => r.fulfill({ json: { id: user, name: "Test", email: "test@example.com" } }));
  await page.route("**/api/backend/**", r => {
    const path = new URL(r.request().url()).pathname;
    if (path.includes("/sync/")) return r.fulfill({ status: 404, json: { detail: "Sync unavailable in this fixture" } });
    if (path === "/api/backend/preferences") return r.fulfill({ json: { default_priority: "medium", default_duration_minutes: 30 } });
    if (path === "/api/backend/tasks") return r.fulfill({ json: { items: [task(taskId, "Review report", today.toISOString()), task("33333333-3333-4333-8333-333333333333", "Overdue work", yesterday.toISOString()), task("44444444-4444-4444-8444-444444444444", "Future work", tomorrow.toISOString()), task("55555555-5555-4555-8555-555555555555", "Unscheduled work", null)], total: 4 } });
    if (path.endsWith("/focus/sessions")) return r.fulfill({ json: [] });
    if (path.endsWith("/focus/summary")) return r.fulfill({ json: { total_duration_seconds: 0, session_count: 0 } });
    return r.fulfill({ json: { items: [], total: 0 } });
  });
});

test("Today is the landing view and groups tasks without claiming time means completion", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Today", exact: true })).toBeVisible();
  await expect(page.getByRole("region", { name: "Today’s tasks" }).getByText("Overdue work", { exact: true })).toBeVisible();
  await expect(page.getByRole("region", { name: "Today’s tasks" }).getByText("Future work", { exact: true })).toHaveCount(0);
  await page.getByRole("navigation").getByRole("button", { name: "Tasks", exact: true }).click();
  for (const group of ["Overdue", "Today", "Upcoming", "Unscheduled"]) await expect(page.locator(".task-group-heading").filter({ hasText: group })).toBeVisible();
  await expect(page.getByText("Time tracked: 30 of 30 min").first()).toBeVisible();
  await expect(page.getByText("100% done")).toHaveCount(0);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  if (test.info().project.name === "mobile") { const tops = await page.getByRole("navigation").getByRole("button").evaluateAll(buttons => buttons.map(b => Math.round(b.getBoundingClientRect().top))); expect(new Set(tops).size).toBe(1); }
  await page.screenshot({ path: `/tmp/ui-ux-tasks-${test.info().project.name}.png`, fullPage: true });
});

test("new tasks start simple, events require both times, and keyboard dismissal restores focus", async ({ page }) => {
  await page.goto("/");
  const add = page.getByRole("button", { name: "New task", exact: true }); await add.click();
  const dialog = page.getByRole("dialog", { name: "New task" });
  await expect(dialog.getByLabel("Estimated minutes")).toBeVisible();
  await expect(dialog.getByRole("combobox", { name: "Priority", exact: true })).not.toBeVisible();
  await expect(dialog.getByRole("combobox", { name: "Status", exact: true })).toHaveCount(0);
  await expect(dialog.getByLabel("Actual minutes")).toHaveCount(0);
  await dialog.getByText("More options", { exact: true }).click();
  await expect(dialog.getByRole("combobox", { name: "Priority", exact: true })).toBeVisible();
  await dialog.getByRole("button", { name: "Event", exact: true }).click();
  await expect(dialog.getByLabel("Starts", { exact: true })).toHaveAttribute("required", "");
  await expect(dialog.getByLabel("Ends", { exact: true })).toHaveAttribute("required", "");
  await expect(dialog.getByLabel("Estimated minutes")).toHaveCount(0);
  await page.keyboard.press("Escape"); await expect(dialog).toHaveCount(0); await expect(add).toBeFocused();
});

test("overflow hides destructive actions and cancellation sends no delete", async ({ page }) => {
  let deletes = 0;
  await page.route(`**/tasks/${taskId}`, r => { if (r.request().method() === "DELETE") deletes++; return r.fulfill({ json: {} }); });
  await page.goto("/"); await page.getByRole("navigation").getByRole("button", { name: "Tasks", exact: true }).click();
  await expect(page.getByRole("button", { name: "Delete Review report", exact: true })).not.toBeVisible();
  await page.getByLabel("More actions for Review report", { exact: true }).click();
  await page.getByRole("button", { name: "Delete Review report", exact: true }).click();
  const dialog = page.getByRole("dialog", { name: "Confirm action" }); await expect(dialog).toContainText("Permanently delete");
  await dialog.getByRole("button", { name: "Cancel", exact: true }).click(); expect(deletes).toBe(0);
});

test("paused focus persists across reload and excludes paused time from logged duration", async ({ page }) => {
  let body: Record<string, unknown> = {};
  const started = Date.now() - 600_000;
  await page.addInitScript(({ key, started }) => localStorage.setItem(key, JSON.stringify({ operationId: "66666666-6666-4666-8666-666666666666", started, pausedAt: started + 60_000, pausedMilliseconds: 0, taskId: "", category: "" })), { key, started });
  await page.route("**/focus/sessions", r => {
    if (r.request().method() === "POST") { body = r.request().postDataJSON(); return r.fulfill({ json: { id: body.session_id } }); }
    return r.fulfill({ json: [] });
  });
  await page.goto("/");
  const bar = page.getByRole("complementary", { name: "Active focus session" });
  await expect(bar.getByRole("timer")).toHaveText("00:01:00"); await expect(bar.getByRole("button", { name: "Resume", exact: true })).toBeVisible();
  await page.reload(); await expect(bar.getByRole("timer")).toHaveText("00:01:00");
  await bar.getByRole("button", { name: "Stop and save", exact: true }).click();
  await expect.poll(() => body.duration_seconds).toBe(60); await expect(bar).toHaveCount(0);
});

test("desktop assistant keeps the plan usable and becomes modal on smaller screens", async ({ page }) => {
  test.skip(test.info().project.name !== "desktop", "Desktop side panel behavior");
  await page.route("**/chat/conversations*", r => r.fulfill({ json: [] }));
  await page.route("**/chat/memory", r => r.fulfill({ json: { facts: [] } }));
  await page.goto("/"); await page.getByRole("button", { name: "Open assistant", exact: true }).click();
  const panel = page.getByRole("dialog", { name: "Planner assistant" });
  await expect(panel).toHaveAttribute("data-modal", "false");
  await page.getByRole("navigation").getByRole("button", { name: "Tasks", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Tasks", exact: true })).toBeVisible(); await expect(panel).toBeVisible();
  await panel.getByRole("textbox", { name: "Message", exact: true }).fill("Keep this draft");
  await page.setViewportSize({ width: 800, height: 900 }); await expect(panel).toHaveAttribute("data-modal", "true");
  await expect(panel.getByRole("textbox", { name: "Message", exact: true })).toHaveValue("Keep this draft");
  await page.keyboard.press("Escape"); await expect(panel).toHaveCount(0);
});

test("dark theme keeps primary actions readable without horizontal overflow", async ({ page }) => {
  await page.emulateMedia({ colorScheme: "dark", reducedMotion: "reduce" });
  await page.goto("/"); await expect(page.getByRole("heading", { name: "Today", exact: true })).toBeVisible();
  await page.screenshot({ path: `/tmp/ui-ux-today-dark-${test.info().project.name}.png`, fullPage: true });
  const primary = page.getByRole("region", { name: "Your next step" }).getByRole("button", { name: "Start focus", exact: true });
  const colors = await primary.evaluate(el => ({ text: getComputedStyle(el).color, background: getComputedStyle(el).backgroundColor }));
  expect(colors.text).toBe("rgb(0, 0, 0)"); expect(colors.background).toBe("rgb(100, 181, 255)");
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
});
