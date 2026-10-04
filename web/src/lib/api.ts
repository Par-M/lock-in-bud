export async function api<T>(path: string, options: RequestInit = {}): Promise<T> {
  const response = await fetch(`/api/backend${path}`, {
    ...options,
    headers: { "Content-Type": "application/json", ...options.headers },
    cache: "no-store",
  });
  const data = await response.json().catch(() => null);
  if (!response.ok) {
    const detail = data?.detail;
    throw new Error(typeof detail === "string" ? detail :
      response.status === 401 ? "Your session has expired. Sign in again." :
      response.status === 429 ? "Too many requests. Please wait a minute and try again." :
      `Request failed (${response.status}). Please try again.`);
  }
  return data as T;
}
