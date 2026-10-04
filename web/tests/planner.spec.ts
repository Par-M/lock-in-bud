import { expect, test } from "@playwright/test";

test.beforeEach(async ({ page }) => {
  await page.route("https://accounts.google.com/**", route => route.abort());
  await page.route("**/api/session", route => route.fulfill({ json: { name: "Test User", email: "test@example.com" } }));
  await page.route("**/api/backend/**", route => {
    const path = new URL(route.request().url()).pathname;
    const data = path.includes("/habits/dashboard") ? { habits: [] } :
      path.includes("/focus/summary") ? { total_duration_seconds: 0, session_count: 0, analysis: null } :
      path.includes("/focus/sessions") || path.includes("/chat/conversations") ? [] :
      { items: [], total: 0 };
    return route.fulfill({ json: data });
  });
});

test("native tabs fit desktop and mobile, with accessible task sheet", async ({ page }) => {
  const errors: string[] = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Schedule", exact: true })).toBeVisible();
  for (const tab of ["Tasks", "Habits", "Focus", "Schedule"]) {
    await page.getByRole("navigation").getByRole("button", { name: tab, exact: true }).click();
    await expect(page.getByRole("heading", { name: tab, exact: true })).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  }
  await page.getByRole("navigation").getByRole("button", { name: "Tasks", exact: true }).click();
  await page.getByRole("button", { name: "New task", exact: true }).click();
  await expect(page.getByRole("dialog", { name: "New task" })).toBeVisible();
  await page.getByRole("textbox", { name: "Title", exact: true }).fill("Read a chapter");
  await page.getByRole("button", { name: "Close New task" }).click();
  expect(errors).toEqual([]);
});

test("focus timer survives reload without logging a session", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("navigation").getByRole("button", { name: "Focus", exact: true }).click();
  await page.getByRole("button", { name: "Start focus session" }).click();
  await expect(page.getByRole("button", { name: "Stop & log session" })).toBeVisible();
  await page.reload();
  await page.getByRole("navigation").getByRole("button", { name: /Focus/ }).click();
  await expect(page.getByRole("button", { name: "Stop & log session" })).toBeVisible();
});

test("manifest and offline fallback are public and valid", async ({ request }) => {
  const manifest = await request.get("/manifest.webmanifest");
  expect(manifest.ok()).toBe(true);
  expect((await manifest.json()).display).toBe("standalone");
  expect((await request.get("/icon-192.png")).ok()).toBe(true);
  expect((await request.get("/offline.html")).ok()).toBe(true);
});

test("an uncertain focus write cannot be resent after reload", async ({ page }) => {
  let writes = 0;
  await page.route("**/api/backend/focus/sessions", route => {
    if (route.request().method() === "POST") {
      writes++;
      return route.abort("failed");
    }
    return route.fulfill({ json: [] });
  });
  await page.goto("/");
  await page.getByRole("navigation").getByRole("button", { name: "Focus", exact: true }).click();
  await page.getByRole("button", { name: "Start focus session" }).click();
  await page.getByRole("button", { name: "Stop & log session" }).click();
  await expect(page.getByRole("button", { name: "Saving disabled: review required" })).toBeDisabled();
  await page.reload();
  await page.getByRole("navigation").getByRole("button", { name: /Focus/ }).click();
  await expect(page.getByRole("button", { name: "Saving disabled: review required" })).toBeDisabled();
  expect(writes).toBe(1);
});

test("timer changes synchronize across tabs", async ({ page, context }) => {
  await page.goto("/");
  await page.getByRole("navigation").getByRole("button", { name: "Focus", exact: true }).click();
  const other = await context.newPage();
  await other.route("**/api/session", route => route.fulfill({ json: { name: "Test User", email: "test@example.com" } }));
  await other.route("**/api/backend/**", route => {
    const path = new URL(route.request().url()).pathname;
    return route.fulfill({ json: path.includes("/focus/sessions") ? [] : path.includes("/focus/summary") ? { total_duration_seconds: 0, session_count: 0, analysis: null } : { items: [], total: 0 } });
  });
  await other.goto("/");
  await expect(other.getByRole("heading", { name: "Schedule", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Start focus session" }).click();
  await other.getByRole("navigation").getByRole("button", { name: /Focus/ }).click();
  await expect(other.getByRole("button", { name: "Stop & log session" })).toBeVisible();
  other.once("dialog", dialog => dialog.accept());
  await other.getByRole("button", { name: "Discard session", exact: true }).click();
  await expect(page.getByRole("button", { name: "Start focus session" })).toBeVisible();
  await other.close();
});

test("proxy rejects unauthenticated cross-origin mutations and token endpoints", async ({ request }) => {
  const mutation = await request.post("/api/backend/tasks", { headers: { Origin: "https://evil.example" }, data: { title: "Forbidden" } });
  expect(mutation.status()).toBe(403);
  expect((await request.get("/api/backend/auth/refresh")).status()).toBe(404);
  expect((await request.post("/api/session", { headers: { Origin: "https://evil.example" }, data: { id_token: "fake" } })).status()).toBe(403);
});
