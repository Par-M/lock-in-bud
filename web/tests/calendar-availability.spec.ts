import { expect, test, type Page } from "@playwright/test";

const scopes = "https://www.googleapis.com/auth/calendar.events.readonly https://www.googleapis.com/auth/calendar.calendarlist.readonly";
const start = new Date();
start.setHours(10, 0, 0, 0);
const end = new Date(start);
end.setHours(11);
const busy = { start: start.toISOString(), end: end.toISOString() };

async function setup(page: Page) {
  const writes: { path: string; body: Record<string, unknown> }[] = [];
  await page.route("https://accounts.google.com/gsi/client", route => route.fulfill({ contentType: "application/javascript", body: `
    window.calendarConsentRequests = [];
    window.google = { accounts: { oauth2: { initTokenClient(options) {
      return { requestAccessToken(request) {
        window.calendarConsentRequests.push({ scope: options.scope, prompt: request.prompt });
        options.callback({ access_token: "memory-only-token", expires_in: 3600, scope: ${JSON.stringify(scopes)} });
      } };
    } } } };
  ` }));
  await page.route("**/api/session", route => route.fulfill({ json: { id: "11111111-1111-4111-8111-111111111111", name: "Test", email: "test@example.com" } }));
  await page.route("**/api/backend/**", route => {
    const path = new URL(route.request().url()).pathname.replace("/api/backend", "");
    if (route.request().method() !== "GET") writes.push({ path, body: route.request().postDataJSON() });
    if (path.startsWith("/sync/")) return route.fulfill({ status: 404, json: { detail: "No sync fixture" } });
    return route.fulfill({ json: path === "/recommendations/daily" ? { days: [], unscheduled: [] } : path === "/schedule/generate" ? {
      id: "proposal", status: "pending", reasoning: null, failure_reason: null, retry_at: null, items: [], meta: { warnings: [], deferred_tasks: [], overcommitted: false },
    } : { items: [], total: 0 } });
  });
  return writes;
}

test("explicit Google consent imports paginated busy times into identical daily/proposal payloads", async ({ page }) => {
  const writes = await setup(page);
  const queries: URL[] = [];
  await page.route("https://www.googleapis.com/calendar/v3/**", route => {
    const url = new URL(route.request().url());
    queries.push(url);
    expect(route.request().headers().authorization).toBe("Bearer memory-only-token");
    if (url.pathname.endsWith("calendarList")) return route.fulfill({ json: url.searchParams.has("pageToken") ? { items: [{ id: "second", summary: "Second calendar" }] } : { items: [{ id: "primary", summary: "Main calendar" }], nextPageToken: "list-next" } });
    if (url.pathname.includes("/second/")) return route.fulfill({ json: { items: [] } });
    const event = { summary: "Private event name", start: { dateTime: busy.start }, end: { dateTime: busy.end } };
    return route.fulfill({ json: url.searchParams.has("pageToken") ? { items: [event] } : {
      items: [{ ...event, transparency: "transparent" }, { ...event, status: "cancelled" }, { start: { date: "2026-10-05" }, end: { date: "2026-10-06" } }], nextPageToken: "events-next",
    } });
  });
  await page.goto("/"); await page.getByRole("navigation").getByRole("button", { name: "Schedule", exact: true }).click();
  await expect(page.getByRole("button", { name: "Connect Google Calendar" })).toBeEnabled();
  expect(queries).toHaveLength(0);
  await page.getByRole("button", { name: "Connect Google Calendar" }).click();
  await expect(page.getByText("1 busy intervals.", { exact: false })).toBeVisible();
  await expect(page.getByLabel("Main calendar")).toBeChecked();
  await expect(page.getByLabel("Second calendar")).toBeChecked();
  await page.getByRole("button", { name: "Generate", exact: true }).click();
  await expect(page.getByRole("button", { name: "Refresh", exact: true })).toBeEnabled();
  await page.getByRole("button", { name: "Generate schedule proposal" }).click();
  await expect.poll(() => writes.length).toBe(2);
  expect(writes.map(write => write.body.busy_times)).toEqual([[busy], [busy]]);
  expect(JSON.stringify(writes)).not.toContain("Private event name");
  expect(JSON.stringify(writes)).not.toContain("memory-only-token");
  expect(await page.evaluate(() => (window as unknown as { calendarConsentRequests: unknown[] }).calendarConsentRequests)).toEqual([{ scope: scopes, prompt: "consent" }]);
  const eventQueries = queries.filter(url => url.pathname.endsWith("/events"));
  expect(eventQueries.some(url => url.searchParams.get("pageToken") === "events-next")).toBe(true);
  for (const url of eventQueries) {
    expect(url.searchParams.get("singleEvents")).toBe("true");
    const min = new Date(url.searchParams.get("timeMin")!);
    const max = new Date(url.searchParams.get("timeMax")!);
    expect((+max - +min) / 86400000).toBeGreaterThan(365);
    expect((+max - +min) / 86400000).toBeLessThan(367);
  }
  expect(await page.evaluate(() => JSON.stringify(localStorage))).not.toContain("memory-only-token");
  await page.getByLabel("Main calendar").uncheck();
  await expect(page.getByText("0 busy intervals.", { exact: false })).toBeVisible();
  await page.getByLabel("Second calendar").uncheck();
  await page.getByRole("button", { name: "Generate", exact: true }).click();
  await expect.poll(() => writes.length).toBe(3);
  expect(writes[2].body.busy_times).toEqual([]);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
});

test("failed reload retains prior intervals, blocks planning, and recovers on explicit retry", async ({ page }) => {
  await setup(page);
  let fail = false;
  await page.route("https://www.googleapis.com/calendar/v3/**", route => {
    if (route.request().url().includes("calendarList")) return route.fulfill({ json: { items: [{ id: "primary", summary: "Main calendar" }] } });
    return fail ? route.fulfill({ status: 403, json: { error: { message: "API disabled" } } }) : route.fulfill({ json: { items: [{ start: { dateTime: busy.start }, end: { dateTime: busy.end } }] } });
  });
  await page.goto("/"); await page.getByRole("navigation").getByRole("button", { name: "Schedule", exact: true }).click();
  await page.getByRole("button", { name: "Connect Google Calendar" }).click();
  await expect(page.getByText("1 busy intervals.", { exact: false })).toBeVisible();
  fail = true;
  await page.getByRole("button", { name: "Reload busy times" }).click();
  await expect(page.getByRole("region", { name: "External calendar availability" }).getByRole("alert")).toContainText("Previous busy times are retained");
  await expect(page.getByText("1 busy intervals.", { exact: false })).toBeVisible();
  await expect(page.getByRole("button", { name: "Generate", exact: true })).toBeDisabled();
  await expect(page.getByRole("button", { name: "Generate schedule proposal" })).toBeDisabled();
  fail = false;
  await page.getByRole("button", { name: "Reload busy times" }).click();
  await expect(page.getByRole("button", { name: "Generate schedule proposal" })).toBeEnabled();
  await page.reload();
  await expect(page.getByText("1 busy intervals.", { exact: false })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Reload busy times" })).toHaveCount(0);
});
