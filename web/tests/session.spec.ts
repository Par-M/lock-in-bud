import { createServer, type Server } from "node:http";
import { expect, test } from "@playwright/test";

let server: Server;
let revokedToken = "";
let loginStatus = 200;
test.beforeAll(async () => {
  server = createServer(async (request, response) => {
    let body = "";
    for await (const chunk of request) body += chunk;
    response.setHeader("Content-Type", "application/json");
    if (request.url === "/api/v1/auth/google") {
      response.statusCode = loginStatus;
      response.end(JSON.stringify({ access_token: "expired", refresh_token: "original", user: { name: "Tester", email: "test@example.com" } }));
    } else if (request.url === "/api/v1/auth/refresh") {
      response.end(JSON.stringify({ access_token: "renewed", refresh_token: "rotated" }));
    } else if (request.url === "/api/v1/auth/me") {
      response.statusCode = request.headers.authorization === "Bearer renewed" ? 200 : 401;
      response.end(JSON.stringify({ name: "Tester", email: "test@example.com" }));
    } else if (request.url === "/api/v1/auth/logout") {
      revokedToken = JSON.parse(body).refresh_token;
      response.end(JSON.stringify({ message: "Logged out" }));
    } else {
      response.statusCode = 404;
      response.end("{}");
    }
  });
  await new Promise<void>(resolve => server.listen(8765, "127.0.0.1", resolve));
});
test.afterAll(async () => { await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve())); });

test("login hides tokens and logout revokes the rotated refresh session", async ({ request }) => {
  loginStatus = 200;
  const origin = "http://localhost:3100";
  const login = await request.post("/api/session", { headers: { Origin: origin }, data: { id_token: "test-google-token" } });
  expect(login.ok()).toBe(true);
  expect(await login.json()).toEqual({ name: "Tester", email: "test@example.com" });
  const cookies = (await request.storageState()).cookies;
  expect(cookies.filter(cookie => cookie.name.startsWith("lib_")).every(cookie => cookie.httpOnly && cookie.sameSite === "Lax")).toBe(true);
  const logout = await request.delete("/api/session", { headers: { Origin: origin } });
  expect(logout.ok()).toBe(true);
  expect(revokedToken).toBe("rotated");
  expect((await request.storageState()).cookies.filter(cookie => cookie.name.startsWith("lib_"))).toEqual([]);
});

test("backend startup errors are not reported as Google credential failures", async ({ request }) => {
  loginStatus = 500;
  try {
    const response = await request.post("/api/session", { headers: { Origin: "http://localhost:3100" }, data: { id_token: "test-google-token" } });
    expect(response.status()).toBe(502);
    expect((await response.json()).detail).toContain("backend is unavailable");
    expect((await request.storageState()).cookies).toEqual([]);
  } finally { loginStatus = 200; }
});

test("invalid Google credentials produce an actionable verification error", async ({ request }) => {
  loginStatus = 401;
  try {
    const response = await request.post("/api/session", { headers: { Origin: "http://localhost:3100" }, data: { id_token: "test-google-token" } });
    expect(response.status()).toBe(401);
    expect((await response.json()).detail).toContain("OAuth client ID");
    expect((await request.storageState()).cookies).toEqual([]);
  } finally { loginStatus = 200; }
});
