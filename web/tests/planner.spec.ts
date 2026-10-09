import { expect, test } from "@playwright/test";

const userId = "11111111-1111-4111-8111-111111111111";

test.beforeEach(async ({ page }) => {
  await page.route("https://accounts.google.com/**", route => route.abort());
  await page.route("**/api/session", route => route.fulfill({ json: { id: userId, name: "Test User", email: "test@example.com" } }));
  await page.route("**/api/backend/**", route => {
    const path = new URL(route.request().url()).pathname;
    if (path.includes("/sync/")) return route.fulfill({ status: 404, json: { detail: "Sync is outside this mocked planner flow" } });
    const data = path.includes("/habits/dashboard") ? { habits: [] } :
path.includes("/focus/summary") ? { total_duration_seconds: 0, session_count: 0 } :
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

test("focus insight is not rendered when analysis present", async ({ page }) => {
  await page.route("**/api/backend/focus/summary", route => route.fulfill({ json: { total_duration_seconds: 5400, session_count: 3, analysis: "Productive day" } }));
  await page.goto("/");
  await page.getByRole("navigation").getByRole("button", { name: "Focus", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Focus summary" })).toBeVisible();
  await expect(page.getByText("Focus insight")).toHaveCount(0);
  await expect(page.getByText("Productive day")).toHaveCount(0);
  await expect(page.getByText("focused minutes")).toBeVisible();
  await expect(page.getByText("sessions", { exact: true })).toBeVisible();
});

test("assistant messages preserve text, sender alignment, and mocked send flow", async ({ page }) => {
  const errors: string[] = [];
  page.on("pageerror", error => errors.push(error.message));
  const history = [
    { id: "user-1", role: "user", content: "Plan my morning" },
    { id: "assistant-1", role: "assistant", content: "Start with your top priority.\nThen take a break." },
    { id: "system-1", role: "system", content: "Hidden system instructions" },
    { id: "empty-1", role: "assistant", content: null },
  ];
  await page.route("**/api/backend/chat/conversations", route => route.fulfill({ json: [{ id: "chat-1", title: "Morning plan" }] }));
  await page.route("**/api/backend/chat/conversations/chat-1", route => route.fulfill({ json: { id: "chat-1", title: "Morning plan", messages: history } }));
  const sent: unknown[] = [];
  const reply = `Make time for a short walk.\n${"A-long-unbroken-word".repeat(30)}`;
  await page.route("**/api/backend/chat/conversations/chat-1/messages", route => {
    sent.push(route.request().postDataJSON());
    return route.fulfill({ json: {
      message: { id: "user-2", role: "user", content: "What next?" },
      assistant_message: { id: "assistant-2", role: "assistant", content: reply },
    } });
  });
  await page.goto("/");
  await page.getByRole("button", { name: "Open assistant" }).click();
  const dialog = page.getByRole("dialog", { name: "Planner assistant" });
  await dialog.getByRole("combobox", { name: "Conversation", exact: true }).selectOption("chat-1");
  const messages = dialog.locator('[data-slot="message"]');
  await expect(messages).toHaveCount(2);
  await expect(dialog.getByRole("article", { name: "You", exact: true })).toHaveAttribute("data-align", "end");
  await expect(dialog.getByRole("article", { name: "Assistant", exact: true })).toHaveAttribute("data-align", "start");
  expect(await messages.nth(1).locator('[data-slot="bubble-content"]').textContent()).toBe(history[1].content);
  await expect(dialog.getByText("Hidden system instructions")).toHaveCount(0);
  await expect(dialog.locator('[data-slot="message-scroller"]')).toHaveCount(1);
  await expect(messages.locator('[data-slot="message-avatar"] [data-slot="avatar"] [data-slot="avatar-fallback"]')).toHaveCount(2);
  await expect(messages.locator('[data-slot="message-content"] [data-slot="bubble"] [data-slot="bubble-content"]')).toHaveCount(2);
  const input = dialog.getByRole("textbox", { name: "Message", exact: true });
  await input.fill("  What next?  ");
  await dialog.getByRole("button", { name: "Send message", exact: true }).click();
  await expect(messages).toHaveCount(4);
  expect(sent).toEqual([expect.objectContaining({ content: "What next?", timezone: expect.any(String), request_id: expect.any(String) })]);
  await expect(input).toHaveValue("");
  expect(await messages.nth(3).locator('[data-slot="bubble-content"]').textContent()).toBe(reply);
  await expect(dialog.getByRole("button", { name: "Send message", exact: true })).toBeDisabled();
  for (const message of await messages.all()) {
    const layout = await message.evaluate(element => {
      const avatar = element.querySelector('[data-slot="message-avatar"]')!.getBoundingClientRect();
      const bubble = element.querySelector('[data-slot="bubble"]')!.getBoundingClientRect();
      const bounds = element.getBoundingClientRect();
      return { align: element.getAttribute("data-align"), avatarLeft: avatar.left, avatarRight: avatar.right, bubbleLeft: bubble.left, bubbleRight: bubble.right, left: bounds.left, right: bounds.right };
    });
    expect(layout.bubbleLeft).toBeGreaterThanOrEqual(layout.left);
    expect(layout.bubbleRight).toBeLessThanOrEqual(layout.right);
    if (layout.align === "end") expect(layout.avatarLeft).toBeGreaterThan(layout.bubbleRight);
    else expect(layout.avatarRight).toBeLessThan(layout.bubbleLeft);
  }
  const viewport = dialog.getByRole("region", { name: "Conversation messages" });
  await expect(viewport).toBeVisible();
  expect(await viewport.evaluate(element => element.scrollWidth <= element.clientWidth)).toBe(true);
  expect(errors).toEqual([]);
});

test("manifest and offline fallback are public and valid", async ({ request }) => {
  const manifest = await request.get("/manifest.webmanifest");
  expect(manifest.ok()).toBe(true);
  expect((await manifest.json()).display).toBe("standalone");
  expect((await request.get("/icon-192.png")).ok()).toBe(true);
  expect((await request.get("/offline.html")).ok()).toBe(true);
});

test("a legacy uncertain focus write cannot be resent after reload", async ({ page }) => {
  let writes = 0;
  await page.route("**/api/backend/focus/sessions", route => {
    if (route.request().method() === "POST") {
      writes++;
      return route.abort("failed");
    }
    return route.fulfill({ json: [] });
  });
  await page.addInitScript(id => {
    const key = `planner.focus.v1:${id}`;
    if (!localStorage.getItem(key)) localStorage.setItem(key, JSON.stringify({ started: Date.now() - 120000, ended: Date.now() - 60000, taskId: "", category: "", uncertain: "session" }));
  }, userId);
  await page.goto("/");
  await page.getByRole("navigation").getByRole("button", { name: /Focus/ }).click();
  await expect(page.getByRole("button", { name: "Saving disabled: review required" })).toBeDisabled();
  await page.reload();
  await page.getByRole("navigation").getByRole("button", { name: /Focus/ }).click();
  await expect(page.getByRole("button", { name: "Saving disabled: review required" })).toBeDisabled();
  await expect(page.getByRole("button", { name: "Retry save", exact: true })).toHaveCount(0);
  expect(writes).toBe(0);
});

test("timer changes synchronize across tabs", async ({ page, context }) => {
  await page.goto("/");
  await page.getByRole("navigation").getByRole("button", { name: "Focus", exact: true }).click();
  const other = await context.newPage();
  await other.route("**/api/session", route => route.fulfill({ json: { id: userId, name: "Test User", email: "test@example.com" } }));
  await other.route("**/api/backend/**", route => {
    const path = new URL(route.request().url()).pathname;
    if (path.includes("/sync/")) return route.fulfill({ status: 404, json: { detail: "Sync is outside this mocked planner flow" } });
    return route.fulfill({ json: path.includes("/focus/sessions") ? [] : path.includes("/focus/summary") ? { total_duration_seconds: 0, session_count: 0 } : { items: [], total: 0 } });
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
