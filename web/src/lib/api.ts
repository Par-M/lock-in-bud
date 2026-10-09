import { onlineRequest, taskDefaultsRequest, taskRequest } from "./offline";

export async function api<T>(path: string, options: RequestInit = {}): Promise<T> {
  if (path === "/preferences") return taskDefaultsRequest<T>(options);
  return /^\/tasks(?:\/|\?|$)/.test(path) ? taskRequest<T>(path, options) : onlineRequest<T>(path, options);
}
