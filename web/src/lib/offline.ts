export type OfflineUser = { id: string; name: string | null; email: string | null };
type Task = Record<string, unknown> & { id: string; title: string };
type Operation = {
  operation_id: string; entity: "task"; operation: "upsert" | "delete";
  base_revision: number | null; payload: Task;
};
type Entry = { operation: Operation; sent: boolean; conflict?: string; blocked?: string };
type Snapshot = {
  cursor: number; ready: boolean; supported?: boolean;
  tasks: Record<string, Task>; revisions: Record<string, number>; outbox: Entry[];
  preferences?: unknown;
};
export type OfflineStatus = { online: boolean; available: boolean; pending: number; conflicts: { id: string; title: string; detail: string }[]; error: string };
export const offlineEvent = "tasks-offline-status";
export const offlineTasksChangedEvent = "tasks-offline-changed";
export const expiredEvent = "api-session-expired";
let account: string | null = null;
let generation = 0;
let lastError = "";
let database: Promise<IDBDatabase> | undefined;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function db() {
  return database ??= new Promise<IDBDatabase>((resolve, reject) => {
    const request = indexedDB.open("task-offline", 1);
    request.onupgradeneeded = () => request.result.createObjectStore("accounts");
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(new Error("Offline storage is unavailable. Changes were not saved."));
  });
}

async function storage<T>(key: string, value?: T, remove = false): Promise<T | undefined> {
  const database = await db();
  return new Promise((resolve, reject) => {
    const transaction = database.transaction("accounts", value !== undefined || remove ? "readwrite" : "readonly");
    const store = transaction.objectStore("accounts");
    const request = remove ? store.delete(key) : value !== undefined ? store.put(value, key) : store.get(key);
    transaction.oncomplete = () => resolve(value ?? request.result);
    transaction.onerror = transaction.onabort = () => reject(new Error("Offline storage failed. Changes were not saved."));
  });
}

function empty(): Snapshot { return { cursor: 0, ready: false, tasks: {}, revisions: {}, outbox: [] }; }
function publish(state = empty()) {
  window.dispatchEvent(new CustomEvent<OfflineStatus>(offlineEvent, { detail: {
    online: navigator.onLine, available: state.ready && state.supported !== false, pending: state.outbox.length, error: lastError,
    conflicts: state.outbox.filter(entry => entry.conflict || entry.blocked).map(entry => ({
      id: entry.operation.operation_id, title: entry.operation.payload.title, detail: entry.conflict || entry.blocked!,
    })),
  } }));
}

export class APIError extends Error {
  constructor(message: string, public status: number) { super(message); }
}

export async function onlineRequest<T>(path: string, options: RequestInit = {}): Promise<T> {
  const response = await fetch(`/api/backend${path}`, {
    ...options, headers: { "Content-Type": "application/json", ...options.headers }, cache: "no-store",
  });
  const data = await response.json().catch(() => null);
  if (!response.ok) {
    if (response.status === 401) window.dispatchEvent(new Event(expiredEvent));
    throw new APIError(response.status === 401 ? "Your session has expired. Sign in again." :
      typeof data?.detail === "string" ? data.detail : response.status === 429 ? "Too many requests. Please wait a minute and try again." : `Request failed (${response.status}). Please try again.`, response.status);
  }
  return data as T;
}

async function accountRequest<T>(path: string, options: RequestInit, current: () => void): Promise<T> {
  const id = account;
  const response = await fetch("/api/session", { cache: "no-store" });
  current();
  if (response.status === 401) {
    window.dispatchEvent(new Event(expiredEvent));
    throw new APIError("Your session has expired. Sign in again.", 401);
  }
  if (!response.ok) throw new APIError("Unable to verify the task account. Please retry.", response.status);
  const user = await response.json(); current();
  if (user.id !== id) {
    window.dispatchEvent(new Event(expiredEvent));
    throw new APIError("The signed-in account changed. Sign in again before syncing tasks.", 401);
  }
  return onlineRequest<T>(path, options);
}

export async function initializeOfflineAccount(user: OfflineUser) {
  const next = uuid.test(user.id || "") ? user.id : null;
  if (account !== next) { account = next; generation++; }
  lastError = "";
  if (!account) { await storage("identity", undefined, true); publish(); return; }
  const id = account, version = generation;
  await storage("identity", user);
  const state = await storage<Snapshot>(id);
  if (account === id && generation === version) publish(state || empty());
}

export async function restoredOfflineAccount() { return storage<OfflineUser>("identity"); }
export async function clearOfflineAccount() {
  const previous = account;
  account = null; generation++; lastError = ""; publish();
  if (previous) await storage(`assistant:${previous}`, undefined, true);
  await storage("identity", undefined, true);
}

// Serialize complete read/modify/write cycles across tabs, not just IDB writes.
async function scoped<T>(work: (state: Snapshot, save: () => Promise<void>, current: () => void) => Promise<T>): Promise<T> {
  const id = account, version = generation;
  if (!id) throw new Error("A verified account UUID is required for offline tasks. Sign in online first.");
  if (!navigator.locks) throw new Error("This browser does not support safe offline task writes.");
  return navigator.locks.request(`task-offline:${id}`, async () => {
    const current = () => { if (account !== id || generation !== version) throw new Error("The account changed. Please retry."); };
    current();
    const state = await storage<Snapshot>(id) || empty();
    const save = async () => { current(); await storage(id, state); current(); publish(state); };
    const result = await work(state, save, current);
    current(); publish(state);
    return result;
  });
}

type Pull = { changes: { entity: string; entity_id: string; revision: number; operation: string; record: Task | null }[]; cursor: number; has_more: boolean };
async function pull(state: Snapshot, save: () => Promise<void>, current: () => void) {
  let more = true;
  while (more) {
    const result = await accountRequest<Pull>(`/sync/pull?cursor=${state.cursor}&limit=200`, {}, current);
    current();
    if (!Array.isArray(result?.changes) || !Number.isInteger(result.cursor) || result.cursor < state.cursor || typeof result.has_more !== "boolean") {
      throw new Error("Invalid task sync response. No changes were uploaded.");
    }
    for (const change of result.changes) {
      if (change.entity !== "task") continue;
      if (change.operation === "delete" || !change.record) delete state.tasks[change.entity_id];
      else state.tasks[change.entity_id] = { ...state.tasks[change.entity_id], ...change.record };
      state.revisions[change.entity_id] = change.revision;
    }
    if (result.has_more && result.cursor <= state.cursor) throw new Error("Task sync did not advance. Please retry.");
    state.cursor = result.cursor; more = result.has_more;
    state.ready = !more; state.supported = true;
    await save();
  }
}

async function flush(state: Snapshot, save: () => Promise<void>, current: () => void) {
  for (const entry of [...state.outbox]) {
    const id = entry.operation.payload.id;
    if (entry.conflict || entry.blocked || state.outbox.some(other => other !== entry && other.operation.payload.id === id && (other.conflict || other.blocked))) continue;
    // Once sent, neither the operation ID, base revision nor payload may change.
    if (!entry.sent) {
      const previous = state.outbox.find(other => other !== entry && other.operation.payload.id === id);
      if (previous && state.outbox.indexOf(previous) < state.outbox.indexOf(entry)) continue;
      // Only dependent local writes advance to the revision of their acknowledged predecessor.
      // The first write always retains the revision originally observed by the user.
      entry.sent = true;
      await save();
    }
    let response: { results: { operation_id: string; entity_id: string; status: string; revision: number; record: Task | null; detail?: string }[] };
    try {
      response = await accountRequest("/sync/push", { method: "POST", body: JSON.stringify({ operations: [entry.operation] }) }, current);
    } catch (error) {
      current();
      if (error instanceof APIError && error.status >= 400 && error.status < 500 && error.status !== 401 && error.status !== 429) {
        entry.blocked = error.message; await save();
      }
      throw error;
    }
    current();
    const result = response.results?.find(result => result.operation_id === entry.operation.operation_id);
    if (!result || result.entity_id !== id || !Number.isInteger(result.revision) || !["applied", "replayed", "conflict"].includes(result.status) || (entry.operation.operation === "upsert" && result.record?.id !== id)) throw new Error("Sync acknowledgement was missing. The same operation will be retried safely.");
    if (result.status === "conflict") {
      entry.conflict = result.detail || "This task changed on another device. Local changes are retained; no overwrite was performed.";
      await save(); continue;
    }
    if (entry.operation.operation === "delete") delete state.tasks[id];
    else if (result.record) state.tasks[id] = { ...state.tasks[id], ...result.record };
    state.revisions[id] = result.revision;
    state.outbox.splice(state.outbox.indexOf(entry), 1);
    const next = state.outbox.find(other => other.operation.payload.id === id);
    if (next && !next.sent) next.operation.base_revision = result.revision;
    await save();
  }
}

export async function syncOfflineTasks() {
  if (!account) return;
  return scoped(async (state, save, current) => {
    try {
      if (!navigator.onLine) { publish(state); return; }
      if (state.supported === false && !state.outbox.length) return;
      await pull(state, save, current);
      await flush(state, save, current);
      await pull(state, save, current);
      lastError = "";
      window.dispatchEvent(new Event(offlineTasksChangedEvent));
    } catch (error) {
      current(); lastError = (error as Error).message; publish(state);
      throw error;
    }
  });
}

export async function taskDefaultsRequest<T>(options: RequestInit = {}): Promise<T> {
  if (!account || (options.method || "GET").toUpperCase() !== "GET") return onlineRequest<T>("/preferences", options);
  return scoped(async (state, save, current) => {
    if (navigator.onLine) {
      try {
        const result = await accountRequest<T>("/preferences", options, current);
        current(); state.preferences = result; await save(); return result;
      } catch (error) {
        current();
        if (error instanceof APIError && error.status < 500) throw error;
        if (state.preferences === undefined) throw error;
      }
    }
    if (state.preferences === undefined) throw new Error("Task defaults have not been downloaded. Connect once before creating tasks offline.");
    return state.preferences as T;
  });
}

export async function discardTaskConflict(operationId: string) {
  return scoped(async (state, save) => {
    const entry = state.outbox.find(entry => entry.operation.operation_id === operationId && (entry.conflict || entry.blocked));
    if (!entry) return;
    // Discard dependent edits too: their full payload was built from this local version.
    state.outbox = state.outbox.filter(other => other.operation.payload.id !== entry.operation.payload.id);
    lastError = ""; await save();
    window.dispatchEvent(new Event(offlineTasksChangedEvent));
  });
}

const defaults = {
  description: null, deadline: null, start_at: null, end_at: null, priority: "medium", status: "pending",
  estimated_duration: null, actual_duration: null, productivity: null, category: null, notes: null,
  checklist: null, progress_percent: 0, repeat_weekdays: null, repeat_ends_on: null, repeat_overrides: null,
  before_task_ids: null, after_task_ids: null, is_archived: false, created_at: null, updated_at: null,
};
function payload(task: Task): Task {
  return Object.fromEntries(["id", "title", ...Object.keys(defaults)].map(key => [key, task[key] ?? (defaults as Record<string, unknown>)[key] ?? null])) as Task;
}
function localTasks(state: Snapshot) {
  const tasks = { ...state.tasks };
  for (const entry of state.outbox) {
    if (entry.operation.operation === "delete") delete tasks[entry.operation.payload.id];
    else tasks[entry.operation.payload.id] = { ...tasks[entry.operation.payload.id], ...entry.operation.payload };
  }
  return tasks;
}
function cached(path: string, state: Snapshot) {
  const url = new URL(path, location.origin);
  const tasks = localTasks(state), id = url.pathname.split("/")[2];
  if (id) {
    if (!tasks[id]) throw new Error("This task is not available offline.");
    return tasks[id];
  }
  const query = url.searchParams;
  let items = Object.values(tasks).filter(task => Boolean(task.is_archived) === (query.get("archived") === "true"));
  for (const key of ["priority", "status", "category"]) if (query.has(key)) items = items.filter(task => task[key] === query.get(key));
  if (query.get("search")) {
    const search = query.get("search")!.toLowerCase();
    items = items.filter(task => [task.title, task.description, task.notes, task.category].some(value => String(value || "").toLowerCase().includes(search.trim())));
  }
  if (query.get("since")) items = items.filter(task => String(task.updated_at) >= query.get("since")!);
  const sort = query.get("sort") || "created_at";
  if (!["created_at", "updated_at", "priority", "deadline", "category"].includes(sort)) throw new Error("Unsupported task sort.");
  const rank: Record<string, number> = { low: 0, medium: 1, high: 2, urgent: 3 };
  items.sort((a, b) => {
    const left = sort === "priority" ? rank[String(a.priority)] : String(a[sort] ?? "\uffff");
    const right = sort === "priority" ? rank[String(b.priority)] : String(b[sort] ?? "\uffff");
    return (left < right ? -1 : left > right ? 1 : 0) * (query.get("order") === "desc" || !query.has("sort") ? -1 : 1) || String(b.created_at).localeCompare(String(a.created_at));
  });
  return { items, total: items.length };
}

export async function taskRequest<T>(path: string, options: RequestInit = {}): Promise<T> {
  const method = (options.method || "GET").toUpperCase();
  const url = new URL(path, location.origin);
  const parts = url.pathname.split("/").filter(Boolean);
  const ordinary = parts[0] === "tasks" && (parts.length === 1 || (parts.length === 2 && uuid.test(parts[1])));
  if (!ordinary || !account) {
    if (!navigator.onLine) throw new Error("This action requires an online connection and is not queued.");
    if (parts[0] === "tasks" && method !== "GET" && account) {
      await syncOfflineTasks();
      return scoped(async (state, _save, current) => {
        if (state.outbox.some(entry => entry.operation.payload.id === parts[1])) throw new Error("Sync this task's pending changes before using online actions.");
        return accountRequest<T>(path, options, current);
      });
    }
    return onlineRequest<T>(path, options);
  }
  return scoped(async (state, save, current) => {
    if (method === "GET") {
      let result: T | undefined;
      if (navigator.onLine) {
        try {
          result = await accountRequest<T>(path, options, current); current();
          const records = parts.length === 1 ? (result as { items?: Task[] })?.items : [result as Task];
          for (const task of records || []) if (task?.id) state.tasks[task.id] = task;
          await save();
          await pull(state, save, current);
          lastError = "";
        } catch (error) {
          current();
          if (error instanceof APIError && error.status === 401) throw error;
          if (error instanceof APIError && [404, 405].includes(error.status) && result !== undefined) { state.supported = false; await save(); }
          else if (error instanceof APIError && error.status < 500 && result === undefined) throw error;
          lastError = (error as Error).message;
        }
      }
      if (state.ready) return cached(path, state) as T;
      if (result !== undefined) return result;
      throw new Error("Tasks have not been downloaded for this account. Connect once before using tasks offline.");
    }
    if (!["POST", "PATCH", "DELETE"].includes(method)) return accountRequest<T>(path, options, current);
    const body = options.body ? JSON.parse(String(options.body)) as Record<string, unknown> : {};
    const existing = localTasks(state)[parts[1]];
    if (body.status && body.status !== (existing?.status || "pending")) {
      if (!navigator.onLine) throw new Error("Status changes require an online connection for timestamps and scheduling. Nothing was queued.");
      if (state.outbox.some(entry => entry.operation.payload.id === parts[1])) throw new Error("Sync this task's pending changes before changing status.");
      return accountRequest<T>(path, options, current);
    }
    if (state.supported === false && !state.outbox.length && navigator.onLine) return accountRequest<T>(path, options, current);
    if (!state.ready && navigator.onLine) {
      try { await pull(state, save, current); }
      catch (error) {
        current();
        if (error instanceof APIError && [404, 405].includes(error.status) && !state.outbox.length) {
          state.supported = false; await save(); return accountRequest<T>(path, options, current);
        }
        throw error;
      }
    }
    if (!state.ready) throw new Error("Download tasks online first. A safe base revision is not available.");
    if (state.supported === false) throw new Error("Task sync is unavailable. Offline changes are disabled and nothing was queued.");
    const id = parts[1] || crypto.randomUUID();
    const local = localTasks(state)[id];
    if (parts[1] && (!local || state.revisions[id] === undefined && !state.outbox.some(entry => entry.operation.payload.id === id))) throw new Error("Download this task's revision before editing offline.");
    if (state.outbox.some(entry => entry.operation.payload.id === id && (entry.conflict || entry.blocked))) throw new Error("This task has unresolved sync changes. Review them before editing again.");
    const task = payload({ ...defaults, ...local, ...body, id } as Task);
    if (typeof task.title !== "string" || !task.title.trim() || task.title.trim().length > 255) throw new Error("A task title of 1 to 255 characters is required.");
    task.title = task.title.trim();
    task.created_at ||= new Date().toISOString(); task.updated_at = new Date().toISOString();
    if (task.start_at || task.end_at) {
      if (!task.start_at || !task.end_at || new Date(String(task.end_at)) <= new Date(String(task.start_at))) throw new Error("Start and end must be set together, with end after start.");
    }
    state.outbox.push({ operation: {
      operation_id: crypto.randomUUID(), entity: "task", operation: method === "DELETE" ? "delete" : "upsert",
      base_revision: state.revisions[id] ?? null, payload: task,
    }, sent: false });
    await save();
    if (navigator.onLine) {
      try { await flush(state, save, current); lastError = ""; }
      catch (error) {
        current();
        if (error instanceof APIError && error.status === 401) throw error;
        lastError = `Saved on this device, not confirmed on the server. ${(error as Error).message}`;
      }
    }
    publish(state);
    return (method === "DELETE" ? null : localTasks(state)[id]) as T;
  });
}

// Assistant history is a read-only snapshot, never a task-outbox operation.
export async function readAssistantHistory<T>(userId: string): Promise<T | undefined> {
  if (account !== userId) return undefined;
  return storage<T>(`assistant:${userId}`);
}
export async function cacheAssistantHistory<T>(userId: string, history: T): Promise<void> {
  if (account === userId) await storage(`assistant:${userId}`, history);
}
export async function removeAssistantHistory(userId: string): Promise<void> {
  await storage(`assistant:${userId}`, undefined, true);
}
