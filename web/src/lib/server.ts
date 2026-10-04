import "server-only";
import { cookies } from "next/headers";

export const backend = (process.env.API_BASE_URL || "http://localhost:8000").replace(/\/$/, "") + "/api/v1";
export const accessCookie = "lib_access";
export const refreshCookie = "lib_refresh";

export async function saveTokens(tokens: { access_token: string; refresh_token: string }) {
  const store = await cookies();
  const options = { httpOnly: true, secure: process.env.NODE_ENV === "production", sameSite: "lax" as const, path: "/" };
  store.set(accessCookie, tokens.access_token, { ...options, maxAge: 60 * 60 });
  store.set(refreshCookie, tokens.refresh_token, { ...options, maxAge: 60 * 60 * 24 * 30 });
}

export async function clearTokens() {
  const store = await cookies();
  store.delete(accessCookie);
  store.delete(refreshCookie);
}

export function sameOrigin(request: Request) {
  return request.headers.get("origin") === new URL(request.url).origin;
}

// Duplicate refreshes within an instance share one rotation request.
const refreshes = new Map<string, Promise<Response>>();
export async function authorizedFetch(path: string, init: RequestInit = {}) {
  const store = await cookies();
  const access = store.get(accessCookie)?.value;
  const refresh = store.get(refreshCookie)?.value;
  const send = (token?: string) => fetch(backend + path, {
    ...init, headers: { ...init.headers, ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    cache: "no-store", redirect: "error", signal: AbortSignal.timeout(90_000),
  });
  let response = access ? await send(access) : new Response(null, { status: 401 });
  if (response.status !== 401 || !refresh) return response;
  let rotation = refreshes.get(refresh);
  if (!rotation) {
    rotation = fetch(backend + "/auth/refresh", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ refresh_token: refresh }), cache: "no-store", signal: AbortSignal.timeout(15_000),
    });
    refreshes.set(refresh, rotation);
    // Keep completed rotations briefly for concurrent requests using old cookies.
    setTimeout(() => refreshes.delete(refresh), 5_000).unref();
  }
  const renewed = (await rotation).clone();
  if (!renewed.ok) {
    if (renewed.status === 401) await clearTokens();
    return renewed;
  }
  const tokens = await renewed.json();
  await saveTokens(tokens);
  response = await send(tokens.access_token);
  return response;
}
