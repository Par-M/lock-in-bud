import { expect, test } from "@playwright/test";
const user = { id: "11111111-1111-4111-8111-111111111111", name: "Test", email: "test@example.com" };
const conv = { id: "chat-1", title: "Today", messages: [], actions: [] };
test.beforeEach(async ({ page }) => {
  await page.route("https://accounts.google.com/**", r => r.abort());
  await page.route("**/api/session", r => r.fulfill({ json: user }));
  await page.route("**/api/backend/**", r => {
    const path = new URL(r.request().url()).pathname;
    if (path.includes("/sync/")) return r.fulfill({ status: 404, json: {} });
    if (path.endsWith("/chat/memory")) return r.fulfill({ json: { facts: [] } });
    if (path.endsWith("/chat/conversations")) return r.fulfill({ json: [conv] });
    if (path.endsWith("/chat/conversations/chat-1")) return r.fulfill({ json: conv });
    return r.fulfill({ json: path.includes("/habits/dashboard") ? { habits: [] } : path.includes("/focus/summary") ? { total_duration_seconds: 0, session_count: 0 } : path.includes("/focus/sessions") ? [] : { items: [], total: 0 } });
  });
});

test("failed send preserves draft and retries the same request once", async ({ page }) => {
  const sent: { request_id: string; content: string }[] = [];
  await page.route("**/chat/conversations/chat-1/messages", r => {
    sent.push(r.request().postDataJSON());
    return sent.length === 1 ? r.fulfill({ status: 502, json: { detail: "Provider unavailable" } }) : r.fulfill({ json: {
      conversation_id: "chat-1", message: { id: "u", role: "user", content: "Help me" }, assistant_message: { id: "a", role: "assistant", content: "Here is a plan" }, actions: [],
    } });
  });
  await page.goto("/"); await page.getByRole("button", { name: "Open assistant" }).click();
  const dialog = page.getByRole("dialog", { name: "Planner assistant" });
  await expect(dialog.getByRole("combobox")).toHaveValue("chat-1");
  const input = dialog.getByRole("textbox", { name: "Message", exact: true });
  await input.fill("Help me"); await dialog.getByRole("button", { name: "Send message", exact: true }).click();
  await expect(dialog.getByRole("alert")).toContainText("your draft was kept");
  await expect(input).toHaveValue("Help me");
  await dialog.getByRole("button", { name: "Retry", exact: true }).click();
  await expect(input).toHaveValue(""); await expect(dialog.getByText("Here is a plan")).toBeVisible();
  expect(sent).toHaveLength(2); expect(sent[0].request_id).toBe(sent[1].request_id);
});

test("streaming renders progressively and confirms an action explicitly", async ({ page }) => {
  const action = { action_id: "action-1", name: "create_task", args: { title: "Read" }, status: "pending" };
  const result = { conversation_id: "chat-1", message: { id: "u", role: "user", content: "Create a task" }, assistant_message: { id: "a", role: "assistant", content: "Review this task." }, actions: [action] };
  await page.route("**/chat/conversations/chat-1/messages", r => r.fulfill({ contentType: "text/event-stream", body: `data: ${JSON.stringify({ type: "delta", text: "Review this task." })}\n\ndata: ${JSON.stringify({ type: "complete", result })}\n\n` }));
  let confirmed = 0;
  await page.route("**/actions/action-1/confirm", r => { confirmed++; return r.fulfill({ json: { ...action, status: "confirmed", result: {} } }); });
  await page.goto("/"); await page.getByRole("button", { name: "Open assistant" }).click();
  const dialog = page.getByRole("dialog", { name: "Planner assistant" });
  await expect(dialog.getByRole("combobox")).toHaveValue("chat-1");
  await dialog.getByRole("textbox", { name: "Message", exact: true }).fill("Create a task");
  await dialog.getByRole("button", { name: "Send message", exact: true }).click();
  await expect(dialog.getByRole("button", { name: "Create task", exact: true })).toBeVisible(); expect(confirmed).toBe(0);
  await dialog.getByRole("button", { name: "Create task", exact: true }).click();
  await expect(dialog.getByText("confirmed", { exact: true })).toBeVisible(); expect(confirmed).toBe(1);
});

test("offline keeps history readable and disables sending", async ({ page, context }) => {
  await page.route("**/chat/conversations/chat-1", r => r.fulfill({ json: { ...conv, messages: [{ id: "a", role: "assistant", content: "Saved plan" }] } }));
  await page.goto("/"); await page.getByRole("button", { name: "Open assistant" }).click();
  const dialog = page.getByRole("dialog", { name: "Planner assistant" });
  await expect(dialog.getByText("Saved plan")).toBeVisible();
  await context.setOffline(true);
  await expect(dialog.getByText(/The assistant needs a connection/)).toBeVisible();
  await dialog.getByRole("textbox", { name: "Message", exact: true }).fill("Draft");
  await expect(dialog.getByRole("button", { name: "Send message", exact: true })).toBeDisabled();
  await expect(dialog.getByText("Saved plan")).toBeVisible();
});

test("history refresh failure after success never offers to resend a committed message", async ({ page }) => {
  let sent = false;
  await page.route("**/chat/conversations", r => sent ? r.fulfill({ status: 502, json: { detail: "History unavailable" } }) : r.fulfill({ json: [conv] }));
  await page.route("**/chat/conversations/chat-1/messages", r => { sent = true; return r.fulfill({ json: {
    conversation_id: "chat-1", message: { id: "u", role: "user", content: "Saved" }, assistant_message: { id: "a", role: "assistant", content: "Saved reply" }, actions: [],
  } }); });
  await page.goto("/"); await page.getByRole("button", { name: "Open assistant" }).click();
  const dialog = page.getByRole("dialog", { name: "Planner assistant" });
  await expect(dialog.getByRole("combobox")).toHaveValue("chat-1");
  await dialog.getByRole("textbox", { name: "Message", exact: true }).fill("Saved");
  await dialog.getByRole("button", { name: "Send message", exact: true }).click();
  await expect(dialog.getByText("Saved reply")).toBeVisible();
  await expect(dialog.getByRole("textbox", { name: "Message", exact: true })).toHaveValue("");
  await expect(dialog.getByRole("button", { name: "Retry", exact: true })).toHaveCount(0);
});
