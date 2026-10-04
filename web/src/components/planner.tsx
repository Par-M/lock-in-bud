"use client";

import { useEffect, useRef, useState, type ReactNode, type FormEvent } from "react";
import { CalendarDays, ListChecks, CircleCheck, Timer, Settings, MessageCircle, Plus, ChevronLeft, ChevronRight, X, RefreshCw, Play, Square, Archive, RotateCcw, Pencil, Trash2 } from "lucide-react";
import { api } from "@/lib/api";

type Task = {
  id: string; title: string; priority: "low" | "medium" | "high";
  status: "pending" | "in_progress" | "completed"; is_archived: boolean;
  estimated_duration: number | null; actual_duration: number | null;
  category: string | null; deadline: string | null; notes: string | null;
  start_at: string | null; end_at: string | null;
  description: string | null; checklist: { text: string; done: boolean }[] | null;
  repeat_weekdays: number[] | null; repeat_ends_on: string | null;
  repeat_overrides?: Record<string, { completed?: boolean; start_at?: string | null; end_at?: string | null }> | null;
};
type Block = { id: string; task_id: string; title: string; start_at: string; end_at: string; completed_at: string | null };
type HabitStats = {
  habit: { id: string; title: string; daily_goal: number; repeat_weekdays: number[] | null };
  current_streak: number; best_streak: number; completion_rate_30d: number;
  scheduled_7d: number; completed_7d: number;
  last_7_days: { date: string; scheduled: boolean; completed_count: number }[];
};
type Session = { id: string; task_id: string | null; started_at: string; ended_at: string; duration_seconds: number; category: string | null };
type Summary = { total_duration_seconds: number; session_count: number; analysis: string };
type Recommendations = { days: { date: string; available_minutes: number; items: { task_id: string; task_title: string; part_title: string | null; minutes: number; reason: string; start_at: string | null; end_at: string | null }[] }[]; unscheduled: { task_id: string; task_title: string; minutes: number }[] };
type FocusRun = { id?: string; started: number; taskId: string; category: string; ended?: number; sessionId?: string; uncertain?: "session" | "time" };
type Tab = "Schedule" | "Tasks" | "Habits" | "Focus";
const tabs = [{ name: "Schedule", icon: CalendarDays }, { name: "Tasks", icon: ListChecks }, { name: "Habits", icon: CircleCheck }, { name: "Focus", icon: Timer }] as const;
const weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const timezone = () => Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
const dateKey = (date: Date) => `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
const localInput = (value: string | null) => value ? `${dateKey(new Date(value))}T${new Date(value).toTimeString().slice(0, 5)}` : "";
const timeLabel = (value: string) => new Date(value).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
const errorText = (error: unknown) => error instanceof Error ? error.message : "Something went wrong. Please try again.";
const request = (method: string, body?: unknown): RequestInit => ({ method, ...(body === undefined ? {} : { headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) }) });

function readFocusRun(key: string): FocusRun | null {
  const saved = localStorage.getItem(key);
  if (saved === null) return null;
  const value = JSON.parse(saved) as FocusRun | null;
  if (!value || (value.id !== undefined && (typeof value.id !== "string" || !value.id)) || !Number.isFinite(value.started) || value.started <= 0 || value.started > Date.now() || typeof value.taskId !== "string" || typeof value.category !== "string" || (value.ended !== undefined && (!Number.isFinite(value.ended) || value.ended < value.started)) || (value.sessionId !== undefined && (typeof value.sessionId !== "string" || !value.sessionId || value.ended === undefined)) || (value.uncertain !== undefined && (!["session", "time"].includes(value.uncertain) || value.ended === undefined))) {
    throw new Error("Stored focus timer is invalid. It has been left untouched; saving is disabled.");
  }
  return value;
}

function fixedEventsForDay(tasks: Task[], blocks: Block[], day: Date) {
  const key = dateKey(day); const next = new Date(day); next.setDate(next.getDate() + 1);
  const blocked = new Set(blocks.filter(b => new Date(b.start_at) < next && new Date(b.end_at) > day).map(b => b.task_id));
  return tasks.flatMap(task => {
    if (!task.start_at || !task.end_at || task.is_archived || blocked.has(task.id)) return [];
    let start = new Date(task.start_at); let end = new Date(task.end_at);
    if (task.repeat_weekdays?.length) {
      if (task.status === "completed" || !task.repeat_weekdays.includes(day.getDay()) || key < dateKey(start) || (task.repeat_ends_on && key > dateKey(new Date(task.repeat_ends_on)))) return [];
      const override = task.repeat_overrides?.[key];
      start = new Date(override?.start_at || task.start_at); end = new Date(override?.end_at || task.end_at);
      const endDayOffset = Math.round((Date.UTC(end.getFullYear(), end.getMonth(), end.getDate()) - Date.UTC(start.getFullYear(), start.getMonth(), start.getDate())) / 86400000);
      const occurrenceStart = new Date(day); occurrenceStart.setHours(start.getHours(), start.getMinutes(), start.getSeconds(), 0);
      const occurrenceEnd = new Date(day); occurrenceEnd.setDate(occurrenceEnd.getDate() + endDayOffset); occurrenceEnd.setHours(end.getHours(), end.getMinutes(), end.getSeconds(), 0);
      start = occurrenceStart; end = occurrenceEnd;
    }
    if (start >= next || end <= day) return [];
    return [{ task, start_at: start.toISOString(), end_at: end.toISOString() }];
  });
}

function Sheet({ title, onClose, children }: { title: string; onClose: () => void; children: ReactNode }) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => { const dialog = ref.current; dialog?.showModal(); return () => dialog?.close(); }, []);
  return <dialog ref={ref} className="sheet" aria-label={title} onCancel={event => { event.preventDefault(); onClose(); }} onClick={event => { if (event.target === event.currentTarget) { const box = event.currentTarget.getBoundingClientRect(); if (event.clientX < box.left || event.clientX > box.right || event.clientY < box.top || event.clientY > box.bottom) onClose(); } }}>
    <div className="sheet-heading"><h2>{title}</h2><button type="button" className="icon-button" aria-label={`Close ${title}`} onClick={onClose}><X /></button></div>{children}
  </dialog>;
}

function RepeatDays({ value, onChange }: { value: number[]; onChange: (days: number[]) => void }) {
  return <fieldset><legend>Repeat on days <span className="muted">(optional)</span></legend><div className="weekdays">{weekdays.map((day, index) => <button type="button" key={day} aria-pressed={value.includes(index)} onClick={() => onChange(value.includes(index) ? value.filter(v => v !== index) : [...value, index].sort())}>{day}</button>)}</div></fieldset>;
}

function TaskForm({ task, onSave, busy }: { task: Task | null; onSave: (body: unknown) => void; busy: boolean }) {
  const [days, setDays] = useState(task?.repeat_weekdays || []);
  const [checklist, setChecklist] = useState(task?.checklist || []);
  const [validationError, setValidationError] = useState("");
  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); const data = new FormData(event.currentTarget);
    const deadline = String(data.get("deadline") || ""); const ends = String(data.get("repeat_ends_on") || "");
    const start = String(data.get("start_at") || ""); const end = String(data.get("end_at") || "");
    // Keep existing seconds and offset when an edit leaves the displayed time unchanged.
    const startAt = start ? start === localInput(task?.start_at || null) ? task!.start_at : new Date(start).toISOString() : null;
    const endAt = end ? end === localInput(task?.end_at || null) ? task!.end_at : new Date(end).toISOString() : null;
    if (!!startAt !== !!endAt || (startAt && endAt && new Date(endAt) <= new Date(startAt))) { setValidationError("Set both fixed-event times, with the end after the start, or leave both blank."); return; }
    setValidationError("");
    onSave({ title: String(data.get("title")).trim(), description: data.get("description") || null, priority: data.get("priority"), status: data.get("status"), estimated_duration: data.get("estimated_duration") ? Number(data.get("estimated_duration")) : null, category: data.get("category") || null, deadline: deadline ? new Date(deadline).toISOString() : null, start_at: startAt, end_at: endAt, notes: data.get("notes") || null, checklist: checklist.filter(item => item.text.trim()).map(item => ({ ...item, text: item.text.trim() })), repeat_weekdays: days.length ? days : null, repeat_ends_on: ends ? new Date(`${ends}T23:59:59`).toISOString() : null });
  }
  return <form onSubmit={submit} className="stack">
    <label>Title<input autoFocus required name="title" maxLength={255} defaultValue={task?.title} placeholder="What needs to get done?" /></label>
    <div className="form-grid"><label>Priority<select name="priority" defaultValue={task?.priority || "medium"}><option value="low">Low</option><option value="medium">Medium</option><option value="high">High</option></select></label><label>Status<select name="status" defaultValue={task?.status || "pending"}><option value="pending">Pending</option><option value="in_progress">In progress</option><option value="completed">Completed (entire task)</option></select></label>
    <label>Estimated minutes<input name="estimated_duration" type="number" min={1} max={525600} defaultValue={task?.estimated_duration ?? ""} /></label><label>Category<input name="category" maxLength={100} defaultValue={task?.category || ""} /></label></div>
    <label>Deadline<input name="deadline" type="datetime-local" defaultValue={localInput(task?.deadline || null)} /></label>
    <fieldset className="stack compact"><legend>Fixed event <span className="muted">(optional)</span></legend><div className="form-grid"><label>Starts<input name="start_at" type="datetime-local" defaultValue={localInput(task?.start_at || null)} /></label><label>Ends<input name="end_at" type="datetime-local" defaultValue={localInput(task?.end_at || null)} /></label></div><p className="muted small">Set both times to place this task on the calendar. Repeat days use these local times.</p>{validationError && <p className="error" role="alert">{validationError}</p>}</fieldset>
    <label>Description<textarea name="description" defaultValue={task?.description || ""} rows={2} /></label><label>Notes<textarea name="notes" defaultValue={task?.notes || ""} rows={3} /></label>
    <fieldset><legend>Checklist</legend><div className="stack compact">{checklist.map((item, index) => <div className="checklist-row" key={index}><input type="checkbox" aria-label={`Complete checklist item ${index + 1}`} checked={item.done} onChange={event => setChecklist(checklist.map((v, i) => i === index ? { ...v, done: event.target.checked } : v))} /><input aria-label={`Checklist item ${index + 1}`} maxLength={500} value={item.text} onChange={event => setChecklist(checklist.map((v, i) => i === index ? { ...v, text: event.target.value } : v))} /><button type="button" className="icon-button" aria-label={`Remove checklist item ${index + 1}`} onClick={() => setChecklist(checklist.filter((_, i) => i !== index))}><X /></button></div>)}<button type="button" onClick={() => setChecklist([...checklist, { text: "", done: false }])}><Plus /> Add checklist item</button></div></fieldset>
    <RepeatDays value={days} onChange={setDays} />{days.length > 0 && <label>Repeat until<input type="date" name="repeat_ends_on" defaultValue={task?.repeat_ends_on ? dateKey(new Date(task.repeat_ends_on)) : ""} /></label>}
    <button className="primary" disabled={busy}>{busy ? "Saving..." : task ? "Save changes" : "Create task"}</button>
  </form>;
}

function HabitForm({ onSave, busy }: { onSave: (body: unknown) => void; busy: boolean }) {
  const [days, setDays] = useState<number[]>([]);
  return <form className="stack" onSubmit={event => { event.preventDefault(); const data = new FormData(event.currentTarget); onSave({ title: String(data.get("title")).trim(), daily_goal: Number(data.get("goal")), repeat_weekdays: days.length ? days : null }); }}><label>Habit name<input autoFocus required name="title" maxLength={255} placeholder="A small step, every day" /></label><label>Daily goal<input type="number" name="goal" min={1} max={100} defaultValue={1} required /></label><RepeatDays value={days} onChange={setDays} /><p className="muted">No days selected means every day.</p><button className="primary" disabled={busy}>{busy ? "Saving..." : "Create habit"}</button></form>;
}

type Message = { id: string; role: string; content: string | null };
type Conversation = { id: string; title: string | null; messages?: Message[] | null };
function Assistant({ onClose }: { onClose: () => void }) {
  const [conversations, setConversations] = useState<Conversation[]>([]);
  const [current, setCurrent] = useState<Conversation | null>(null);
  const [content, setContent] = useState(""); const [busy, setBusy] = useState(false); const [error, setError] = useState("");
  const sequence = useRef(0); const bottom = useRef<HTMLDivElement>(null);
  async function load() { setBusy(true); setError(""); try { setConversations(await api<Conversation[]>("/chat/conversations")); } catch (e) { setError(errorText(e)); } finally { setBusy(false); } }
  useEffect(() => { void load(); }, []);
  useEffect(() => { bottom.current?.scrollIntoView({ block: "nearest" }); }, [current?.messages?.length]);
  async function select(id: string) {
    const token = ++sequence.current; setBusy(true); setError("");
    try { const result = await api<Conversation>(`/chat/conversations/${id}`); if (token === sequence.current) setCurrent(result); } catch (e) { if (token === sequence.current) setError(errorText(e)); } finally { if (token === sequence.current) setBusy(false); }
  }
  async function create() { setBusy(true); setError(""); try { const result = await api<Conversation>("/chat/conversations", request("POST", {})); setConversations(v => [result, ...v]); setCurrent({ ...result, messages: [] }); setContent(""); } catch (e) { setError(errorText(e)); } finally { setBusy(false); } }
  async function send(event: FormEvent) {
    event.preventDefault(); if (!current || !content.trim() || busy) return;
    setBusy(true); setError("");
    try { const result = await api<{ message: Message; assistant_message: Message }>(`/chat/conversations/${current.id}/messages`, request("POST", { content: content.trim() })); setCurrent({ ...current, messages: [...(current.messages || []), result.message, result.assistant_message] }); setContent(""); }
    catch (e) { setError(`${errorText(e)} Your message is preserved. Reload this conversation before retrying to check whether it was saved.`); }
    finally { setBusy(false); }
  }
  return <Sheet title="Planner assistant" onClose={onClose}><div className="stack"><p className="muted">Talk through your day. The assistant is currently chat-only: it offers advice but cannot create, edit, or complete planner items.</p><div className="row"><label className="grow">Conversation<select value={current?.id || ""} disabled={busy} onChange={event => { if (event.target.value) void select(event.target.value); }}><option value="">Choose a conversation</option>{conversations.map(c => <option key={c.id} value={c.id}>{c.title || "Untitled conversation"}</option>)}</select></label><button disabled={busy} onClick={() => void create()}><Plus /> New</button></div>
    {error && <div className="error" role="alert">{error}<button disabled={busy} onClick={() => current ? void select(current.id) : void load()}>Reload history</button></div>}
    <div className="chat-history" aria-live="polite">{!current && <p className="empty">Start a conversation or choose one from your history.</p>}{current?.messages?.filter(m => m.content && (m.role === "user" || m.role === "assistant")).map(m => <article key={m.id} className={`message ${m.role}`}><strong>{m.role === "user" ? "You" : "Assistant"}</strong><p>{m.content}</p></article>)}{busy && <p role="status">Loading...</p>}<div ref={bottom} /></div>
    <form onSubmit={send} className="stack compact"><label>Message<textarea value={content} onChange={event => setContent(event.target.value)} maxLength={8000} rows={3} placeholder="Help me plan my day..." disabled={!current} /></label><div className="row"><button type="button" disabled={!current || busy} onClick={() => current && void select(current.id)}><RefreshCw /> Refresh history</button><button className="primary" disabled={!current || busy || !content.trim()}>{busy ? "Working..." : "Send message"}</button></div></form></div></Sheet>;
}

type Preferences = { work_hours_start: number; work_hours_end: number; buffer_minutes: number; energy_level: number; max_daily_hours: number; default_duration_minutes: number; default_priority: string };
function SchedulingPreferences({ onSaved }: { onSaved: () => void }) {
  const [preferences, setPreferences] = useState<Preferences | null>(null);
  const [loading, setLoading] = useState(true); const [saving, setSaving] = useState(false); const [error, setError] = useState(""); const [saved, setSaved] = useState(false); const [retry, setRetry] = useState(0);
  useEffect(() => {
    let active = true; setLoading(true); setError("");
    api<Preferences>("/preferences").then(result => { if (active) setPreferences(result); }).catch(e => { if (active) setError(errorText(e)); }).finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [retry]);
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); if (saving) return; const data = new FormData(event.currentTarget);
    const body = { work_hours_start: Number(data.get("work_hours_start")), work_hours_end: Number(data.get("work_hours_end")), buffer_minutes: Number(data.get("buffer_minutes")), energy_level: Number(data.get("energy_level")), max_daily_hours: Number(data.get("max_daily_hours")), default_duration_minutes: Number(data.get("default_duration_minutes")), default_priority: String(data.get("default_priority")) };
    setError(""); setSaved(false);
    if (body.work_hours_end <= body.work_hours_start) { setError("Work hours must end after they start."); return; }
    setSaving(true);
    try { setPreferences(await api<Preferences>("/preferences", request("PUT", body))); setSaved(true); onSaved(); } catch (e) { setError(errorText(e)); } finally { setSaving(false); }
  }
  return <section className="stack"><h3>Scheduling preferences</h3>{loading && <p className="muted" role="status">Loading preferences...</p>}{error && <div className="error" role="alert">{error}{!preferences && <button type="button" disabled={loading} onClick={() => setRetry(v => v + 1)}>Retry</button>}</div>}{preferences && !loading && <form className="stack" onSubmit={submit} onChange={() => setSaved(false)}><fieldset disabled={saving} className="form-grid"><label>Work starts (hour)<input required type="number" name="work_hours_start" min={0} max={24} step={.5} defaultValue={preferences.work_hours_start} /></label><label>Work ends (hour)<input required type="number" name="work_hours_end" min={0} max={24} step={.5} defaultValue={preferences.work_hours_end} /></label><label>Buffer minutes<input required type="number" name="buffer_minutes" min={0} max={120} defaultValue={preferences.buffer_minutes} /></label><label>Energy level (1-5)<input required type="number" name="energy_level" min={1} max={5} defaultValue={preferences.energy_level} /></label><label>Maximum daily hours<input required type="number" name="max_daily_hours" min={1} max={24} defaultValue={preferences.max_daily_hours} /></label><label>Default task minutes<input required type="number" name="default_duration_minutes" min={5} max={480} defaultValue={preferences.default_duration_minutes} /></label><label>Default priority<select name="default_priority" defaultValue={preferences.default_priority}><option value="low">Low</option><option value="medium">Medium</option><option value="high">High</option></select></label></fieldset><p className="muted small">Hours use 24-hour notation in half-hour steps, for example 9.5 = 09:30. These preferences guide scheduling recommendations.</p><button className="primary" disabled={saving}>{saving ? "Saving..." : "Save preferences"}</button>{saved && <p role="status" className="muted">Preferences saved.</p>}</form>}</section>;
}

export default function Planner({ user, onLogout }: { user: { name: string | null; email: string | null }; onLogout: () => Promise<void> }) {
  const [tab, setTab] = useState<Tab>("Schedule"); const [reload, setReload] = useState(0);
  const [tasks, setTasks] = useState<Task[]>([]); const [archivedTasks, setArchivedTasks] = useState<Task[]>([]);
  const [blocks, setBlocks] = useState<Block[]>([]); const [habits, setHabits] = useState<HabitStats[]>([]);
  const [sessions, setSessions] = useState<Session[]>([]); const [summary, setSummary] = useState<Summary | null>(null);
  const [loading, setLoading] = useState(true); const [loadError, setLoadError] = useState(""); const [error, setError] = useState(""); const [busy, setBusy] = useState(false);
  const [sheet, setSheet] = useState<"task" | "habit" | "block" | "settings" | "assistant" | null>(null); const [editing, setEditing] = useState<Task | null>(null);
  const [search, setSearch] = useState(""); const [filter, setFilter] = useState("active"); const [sort, setSort] = useState("created_at"); const [quickAdd, setQuickAdd] = useState("");
  const [selectedDate, setSelectedDate] = useState(() => dateKey(new Date())); const [month, setMonth] = useState(() => new Date(new Date().getFullYear(), new Date().getMonth(), 1));
  const [recommendations, setRecommendations] = useState<Recommendations | null>(null); const [recommendBusy, setRecommendBusy] = useState(false); const [recommendError, setRecommendError] = useState("");
  const [range, setRange] = useState(7); const [run, setRun] = useState<FocusRun | null>(null); const [clock, setClock] = useState(Date.now()); const [timerReady, setTimerReady] = useState(false);
  const [timerIssue, setTimerIssue] = useState(""); const operationBusy = useRef(false);
  const [focusTask, setFocusTask] = useState(""); const [focusCategory, setFocusCategory] = useState(""); const [theme, setTheme] = useState("system");
  const timerKey = `planner.focus.v1:${user.email || user.name || "user"}`;
  const refresh = () => setReload(v => v + 1);
  useEffect(() => {
    let active = true; setLoading(true); setLoadError("");
    async function load() {
      try {
        const taskQuery = `sort=${sort}&order=${sort === "deadline" ? "asc" : "desc"}`;
        const taskResult = await api<{ items: Task[] }>(`/tasks?${taskQuery}`); if (!active) return; setTasks(taskResult.items);
        if (tab === "Tasks") { const result = await api<{ items: Task[] }>(`/tasks?archived=true&${taskQuery}`); if (active) setArchivedTasks(result.items); }
        if (tab === "Schedule") { const result = await api<{ items: Block[] }>("/calendar/blocks"); if (active) setBlocks(result.items); }
        if (tab === "Habits") { const result = await api<{ habits: HabitStats[] }>(`/habits/dashboard?timezone=${encodeURIComponent(timezone())}`); if (active) setHabits(result.habits); }
        if (tab === "Focus") {
          const start = new Date(); start.setDate(start.getDate() - range + 1); start.setHours(0, 0, 0, 0);
          const query = `?after=${encodeURIComponent(start.toISOString())}&before=${encodeURIComponent(new Date().toISOString())}`;
          const [history, stats] = await Promise.all([api<Session[]>(`/focus/sessions${query}`), api<Summary>(`/focus/summary${query}`)]);
          if (active) { setSessions(history); setSummary(stats); }
        }
      } catch (e) { if (active) setLoadError(errorText(e)); } finally { if (active) setLoading(false); }
    }
    void load(); return () => { active = false; };
  }, [tab, reload, range, sort]);
  useEffect(() => {
    setRun(null); setTimerReady(false);
    function syncTimer() {
      try {
        const current = readFocusRun(timerKey);
        setRun(previous => current && previous?.id === current.id && previous?.started === current.started && previous.taskId === current.taskId ? { ...current, sessionId: current.sessionId || previous.sessionId } : current); setClock(Date.now());
        setTimerReady(!!navigator.locks);
        setTimerIssue(navigator.locks ? "" : "This browser does not support Web Locks. Timer changes and automatic saving are disabled to prevent duplicate writes. Use a supported browser on this device and check session history and task time before discarding pending work.");
      } catch (e) { setTimerReady(false); setTimerIssue(`Focus storage is unavailable or invalid. Durability cannot be guaranteed, so timer changes and saving are disabled. Existing storage is left untouched. ${errorText(e)}`); }
    }
    function onStorage(event: StorageEvent) { if (event.key === timerKey || event.key === null) { syncTimer(); refresh(); } }
    syncTimer();
    try { const storedTheme = localStorage.getItem("planner.theme"); if (["system", "light", "dark"].includes(storedTheme || "")) setTheme(storedTheme!); } catch { /* Theme storage is independent of timer safety. */ }
    window.addEventListener("storage", onStorage); window.addEventListener("focus", syncTimer);
    return () => { window.removeEventListener("storage", onStorage); window.removeEventListener("focus", syncTimer); };
  }, [timerKey]);
  useEffect(() => { if (!run || run.ended) return; setClock(Date.now()); const id = window.setInterval(() => setClock(Date.now()), 1000); return () => window.clearInterval(id); }, [run]);
  useEffect(() => { document.documentElement.dataset.theme = theme; try { localStorage.setItem("planner.theme", theme); } catch { /* Theme still applies when storage is unavailable. */ } }, [theme]);
  async function act(action: () => Promise<void>, close = false) {
    if (operationBusy.current) return; operationBusy.current = true; setBusy(true); setError("");
    try { await action(); if (close) setSheet(null); refresh(); } catch (e) { setError(errorText(e)); } finally { operationBusy.current = false; setBusy(false); }
  }
  function openTask(task: Task | null = null) { setEditing(task); setError(""); setSheet("task"); }
  function closeSheet() { if (!busy) { setSheet(null); setError(""); } }
  const today = dateKey(new Date());
  const taskDone = (task: Task, date = today) => task.status === "completed" || (task.repeat_weekdays?.length ? !!task.repeat_overrides?.[date]?.completed : false);
  function toggleTask(task: Task, date = today) {
    void act(async () => {
      if (task.repeat_weekdays?.length) await api(`/tasks/${task.id}/occurrence/completion`, request("PATCH", { date, completed: !taskDone(task, date), timezone: timezone() }));
      else if (taskDone(task, date)) await api(`/tasks/${task.id}`, request("PATCH", { status: "pending" }));
      else await api(`/tasks/${task.id}/complete`, request("POST", { timezone: timezone() }));
    });
  }
  async function withFocusLock(action: (current: FocusRun | null) => Promise<void>) {
    if (!navigator.locks) throw new Error("Automatic focus saving is unavailable without Web Locks. No writes were sent. Use a supported browser and check history/task time before discarding pending work.");
    await navigator.locks.request(timerKey, { ifAvailable: true }, async lock => {
      if (!lock) throw new Error("Another tab is changing this focus session. Wait for it to finish; no writes were sent from this tab.");
      let current: FocusRun | null;
      try { current = readFocusRun(timerKey); } catch (e) { setTimerReady(false); setTimerIssue("Focus storage could not be read. Timer changes are disabled and existing storage is left untouched."); throw e; }
      setRun(previous => current && previous?.id === current.id && previous?.started === current.started && previous.taskId === current.taskId ? { ...current, sessionId: current.sessionId || previous.sessionId } : current);
      await action(current);
    });
  }
  function persistFocus(value: FocusRun | null) {
    setRun(value);
    try { if (value) localStorage.setItem(timerKey, JSON.stringify(value)); else localStorage.removeItem(timerKey); }
    catch { setTimerReady(false); setTimerIssue("Focus state could not be persisted. Durability cannot be guaranteed. Keep this page open, check session history and task time, and do not resend writes."); throw new Error("Focus storage failed. No further API writes will be sent."); }
  }
  function startFocus(taskId = focusTask) {
    void act(async () => withFocusLock(async current => {
      setTab("Focus");
      if (current) throw new Error("A focus session already exists in this browser. Continue it or review and discard its pending state before starting another.");
      const started = Date.now(); persistFocus({ id: crypto.randomUUID(), started, taskId, category: focusCategory.trim() || tasks.find(t => t.id === taskId)?.category || "" }); setClock(started);
    }));
  }
  async function saveFocus() {
    if (!run) return;
    await act(async () => withFocusLock(async current => {
      if (!current || current.id !== run.id || current.started !== run.started || current.taskId !== run.taskId) throw new Error("The focus session changed in another tab. This tab has been synchronized; no writes were sent.");
      // Stopped legacy sessions are also review-only: an earlier write may have succeeded.
      if (current.ended !== undefined || current.uncertain || current.sessionId) throw new Error("This session needs manual review. Check session history and task time, then discard its pending state. Writes will not be retried because the API is not idempotent.");
      const pending: FocusRun & { ended: number } = { ...current, ended: Date.now(), uncertain: "session" };
      const seconds = Math.max(1, Math.floor((pending.ended - pending.started) / 1000));
      if (seconds > 2592000) throw new Error("This session exceeds the API's 30-day limit. Discard it and start a new session.");
      persistFocus({ ...pending });
      try {
        const saved = await api<Session>("/focus/sessions", request("POST", { task_id: pending.taskId || null, started_at: new Date(pending.started).toISOString(), ended_at: new Date(Math.max(pending.ended, pending.started + 1000)).toISOString(), duration_seconds: seconds, category: pending.category || null }));
        pending.sessionId = saved.id; pending.uncertain = undefined; persistFocus({ ...pending });
        if (pending.taskId && seconds >= 60) {
          pending.uncertain = "time"; persistFocus({ ...pending });
          await api(`/tasks/${pending.taskId}/time`, request("PATCH", { minutes: Math.floor(seconds / 60) }));
        }
        persistFocus(null);
      } catch (e) {
        setRun({ ...pending }); refresh();
        throw new Error(`${errorText(e)} The save outcome may be uncertain. Check session history and task time, then explicitly discard pending state. No automatic retry is allowed.`);
      }
    }));
  }
  function discardFocus() {
    if (!run) return;
    void act(async () => withFocusLock(async current => {
      if (!current || current.id !== run.id || current.started !== run.started || current.taskId !== run.taskId) throw new Error("The focus session changed in another tab. Review the synchronized timer before discarding it.");
      if (window.confirm(current.ended !== undefined ? "Check session history and task time first. Discard only this pending browser state? Saved server data will remain, and no API writes will be sent." : "Discard this focus session without saving?")) persistFocus(null);
    }));
  }
  async function recommend() {
    setRecommendBusy(true); setRecommendError(""); setRecommendations(null);
    try { setRecommendations(await api<Recommendations>("/recommendations/daily", request("POST", { timezone: timezone(), start_date: `${selectedDate}T00:00:00`, end_date: `${selectedDate}T23:59:59`, busy_times: [] }))); } catch (e) { setRecommendError(errorText(e)); } finally { setRecommendBusy(false); }
  }
  const displayedTasks = (filter === "archived" ? archivedTasks : tasks).filter(t => (filter !== "active" || t.status !== "completed") && (filter !== "completed" || t.status === "completed") && `${t.title} ${t.category || ""} ${t.notes || ""}`.toLowerCase().includes(search.toLowerCase()));
  const dayStart = new Date(`${selectedDate}T00:00:00`); const dayEnd = new Date(dayStart); dayEnd.setDate(dayEnd.getDate() + 1);
  const dayBlocks = blocks.filter(b => new Date(b.start_at) < dayEnd && new Date(b.end_at) > dayStart).sort((a, b) => a.start_at.localeCompare(b.start_at));
  const dayEntries = [...dayBlocks.map(block => ({ block, task: undefined, title: block.title, start_at: block.start_at, end_at: block.end_at, completed: !!block.completed_at })), ...fixedEventsForDay(tasks, blocks, dayStart).map(event => ({ ...event, block: undefined, title: event.task.title, completed: taskDone(event.task, selectedDate) }))].sort((a, b) => a.start_at.localeCompare(b.start_at));
  const elapsed = run ? Math.max(0, Math.floor(((run.ended || clock) - run.started) / 1000)) : 0;
  const timerText = `${String(Math.floor(elapsed / 3600)).padStart(2, "0")}:${String(Math.floor(elapsed / 60) % 60).padStart(2, "0")}:${String(elapsed % 60).padStart(2, "0")}`;
  const calendarStart = new Date(month); calendarStart.setDate(1 - month.getDay());
  const calendarDates = Array.from({ length: 42 }, (_, i) => { const d = new Date(calendarStart); d.setDate(d.getDate() + i); return d; });
  const scheduled = habits.reduce((sum, h) => sum + h.scheduled_7d, 0); const completed = habits.reduce((sum, h) => sum + h.completed_7d, 0);
  return <div className="planner">
    <header className="app-header"><a className="brand" href="#main"><CalendarDays /> <span>My Planner</span></a><div className="header-actions"><button className="icon-button" aria-label="Open assistant" onClick={() => setSheet("assistant")}><MessageCircle /></button><button className="icon-button" aria-label="Open settings" onClick={() => { setError(""); setSheet("settings"); }}><Settings /></button></div></header>
    <nav className="tab-nav" aria-label="Main navigation">{tabs.map(({ name, icon: Icon }) => <button key={name} aria-current={tab === name ? "page" : undefined} onClick={() => { setTab(name); setError(""); }}><Icon /><span>{name}</span>{name === "Focus" && run && <span className="running-dot" aria-label="Session in progress" />}</button>)}</nav>
    <main id="main"><div className="page-heading"><div><p className="eyebrow">{new Date().toLocaleDateString([], { weekday: "long", month: "long", day: "numeric" })}</p><h1>{tab}</h1></div><div className="row"><button className="icon-button" aria-label={`Refresh ${tab.toLowerCase()}`} disabled={loading || busy} onClick={refresh}><RefreshCw className={loading ? "spinning" : ""} /></button>{tab !== "Focus" && <button className="primary" onClick={() => { setError(""); if (tab === "Tasks") openTask(); else setSheet(tab === "Habits" ? "habit" : "block"); }}><Plus /><span>{tab === "Tasks" ? "New task" : tab === "Habits" ? "New habit" : "Add block"}</span></button>}</div></div>
    {loadError && <div className="error" role="alert">{loadError}<button onClick={refresh}>Retry</button></div>}{error && !sheet && <div className="error" role="alert">{error}<button onClick={() => setError("")}>Dismiss</button></div>}{loading && <p className="muted" role="status">Loading {tab.toLowerCase()}...</p>}
    {tab === "Schedule" && <div className="schedule-layout"><section className="card calendar-card" aria-label="Month calendar"><div className="section-heading"><h2>{month.toLocaleDateString([], { month: "long", year: "numeric" })}</h2><div className="row"><button className="icon-button" aria-label="Previous month" onClick={() => setMonth(new Date(month.getFullYear(), month.getMonth() - 1, 1))}><ChevronLeft /></button><button className="icon-button" aria-label="Next month" onClick={() => setMonth(new Date(month.getFullYear(), month.getMonth() + 1, 1))}><ChevronRight /></button></div></div><div className="calendar-grid">{weekdays.map(d => <span className="calendar-weekday" key={d}>{d}</span>)}{calendarDates.map(d => { const key = dateKey(d); const hasEvents = blocks.some(b => dateKey(new Date(b.start_at)) === key) || fixedEventsForDay(tasks, blocks, d).length > 0; return <button key={key} className={`${d.getMonth() !== month.getMonth() ? "outside" : ""} ${key === today ? "today" : ""}`} aria-pressed={key === selectedDate} aria-label={`${d.toLocaleDateString([], { dateStyle: "full" })}${hasEvents ? ", scheduled events" : ""}`} onClick={() => { setSelectedDate(key); setRecommendations(null); setRecommendError(""); }}><span>{d.getDate()}</span><span className={`calendar-dot ${hasEvents ? "visible" : ""}`} /></button>; })}</div><button className="text-button" onClick={() => { const d = new Date(); setMonth(new Date(d.getFullYear(), d.getMonth(), 1)); setSelectedDate(dateKey(d)); setRecommendations(null); }}>Go to today</button></section>
    <div className="stack"><section className="card"><div className="section-heading"><h2>{dayStart.toLocaleDateString([], { weekday: "long", month: "short", day: "numeric" })}</h2><span className="muted">{dayEntries.length} events</span></div>{!dayEntries.length && !loading && !loadError && <p className="empty">No events scheduled. Give your tasks some time.</p>}<div className="stack compact">{dayEntries.map(entry => <article className={`schedule-block ${entry.completed ? "done" : ""}`} key={entry.block ? `block-${entry.block.id}` : `task-${entry.task.id}-${selectedDate}`}>
      <div className="grow"><p className="muted">{timeLabel(entry.start_at)} - {timeLabel(entry.end_at)}</p><h3>{entry.title}</h3>{entry.task && <p className="muted">{entry.task.repeat_weekdays?.length ? "Repeating event" : "Fixed event"}{entry.completed ? " · Completed" : ""}</p>}</div>
      <button className={`icon-button ${entry.completed ? "checked" : ""}`} disabled={busy} aria-label={`${entry.completed ? "Reopen" : "Complete"} ${entry.title} on ${selectedDate}`} onClick={() => { if (entry.task) toggleTask(entry.task, selectedDate); else void act(async () => { await api(`/calendar/blocks/${entry.block.id}/${entry.completed ? "reopen" : "complete"}`, request("POST", {})); }); }}><CircleCheck /></button>
      {entry.task ? <button className="icon-button" aria-label={`Edit event series ${entry.title}`} onClick={() => openTask(entry.task)}><Pencil /></button> : <button className="icon-button danger" disabled={busy} aria-label={`Delete block ${entry.title}`} onClick={() => { if (window.confirm(`Delete schedule block "${entry.title}"?`)) void act(async () => { await api(`/calendar/blocks/${entry.block.id}`, request("DELETE")); }); }}><Trash2 /></button>}
    </article>)}</div></section>
    <section className="card"><div className="section-heading"><h2>Daily recommendations</h2><button disabled={recommendBusy} onClick={() => void recommend()}><RefreshCw />{recommendBusy ? "Planning..." : recommendations ? "Refresh" : "Generate"}</button></div><p className="muted">Suggested work for the selected date, using your planner preferences.</p>{recommendError && <div role="alert" className="error">{recommendError}<button onClick={() => void recommend()}>Retry</button></div>}{recommendBusy && <p role="status">Finding time for your tasks...</p>}{recommendations?.days.filter(d => d.date === selectedDate).map(d => <div className="stack compact" key={d.date}><p className="muted">{d.available_minutes} available minutes</p>{d.items.length === 0 && <p className="empty">No recommendations for this day.</p>}{d.items.map((item, i) => <article className="recommendation" key={`${item.task_id}-${i}`}><div className="grow"><h3>{item.part_title || item.task_title}</h3>{item.part_title && <p className="muted">{item.task_title}</p>}<p className="muted">{item.minutes} min{item.start_at ? ` · ${timeLabel(item.start_at)}` : ""}</p>{item.reason && <p>{item.reason}</p>}</div><button className="icon-button" aria-label={`Focus on ${item.task_title}`} disabled={!!run || !timerReady} onClick={() => startFocus(item.task_id)}><Play /></button></article>)}</div>)}{recommendations && !recommendations.days.some(d => d.date === selectedDate) && <p className="empty">No recommendations returned for this date.</p>}{!!recommendations?.unscheduled.length && <details><summary>Could not fit ({recommendations.unscheduled.length})</summary>{recommendations.unscheduled.map((item, i) => <p key={i}>{item.task_title} · {item.minutes} min</p>)}</details>}</section></div></div>}
    {tab === "Tasks" && <div className="stack">
      <form className="card row quick-add" onSubmit={event => { event.preventDefault(); if (!quickAdd.trim()) return; void act(async () => { await api("/tasks/parse", request("POST", { text: quickAdd.trim(), timezone: timezone() })); setQuickAdd(""); }); }}><label className="grow">Quick add<input required maxLength={2000} value={quickAdd} onChange={e => setQuickAdd(e.target.value)} placeholder="e.g. Submit report tomorrow at 3pm, 45 minutes" /></label><button className="primary" disabled={busy || !quickAdd.trim()}><Plus />{busy ? "Adding..." : "Add task"}</button></form>
      <div className="task-toolbar"><label className="grow"><span className="sr-only">Search tasks</span><input type="search" value={search} onChange={e => setSearch(e.target.value)} placeholder="Search tasks, categories, notes" /></label><label><span className="sr-only">Task filter</span><select value={filter} onChange={e => setFilter(e.target.value)}><option value="active">Active</option><option value="all">All tasks</option><option value="completed">Completed</option><option value="archived">Archived</option></select></label><label><span className="sr-only">Sort tasks</span><select value={sort} onChange={e => setSort(e.target.value)}><option value="created_at">Newest created</option><option value="deadline">Earliest deadline</option><option value="priority">Highest priority</option></select></label></div>
      <section className="card task-list" aria-label="Task list">{!displayedTasks.length && !loading && !loadError && <div className="empty"><h2>{search ? "No matching tasks" : "Nothing here yet"}</h2><p>{search ? "Try another search." : "Create a task to get started, or change the filter."}</p></div>}{displayedTasks.map(task => <article className="task-row" key={task.id}><button className={`completion-button ${taskDone(task) ? "checked" : ""}`} aria-label={`${taskDone(task) ? "Reopen" : "Complete"} ${task.title}${task.repeat_weekdays?.length ? " for today" : ""}`} disabled={busy || task.is_archived} onClick={() => toggleTask(task)}><CircleCheck /></button><div className="grow"><button className={`task-title ${taskDone(task) ? "done" : ""}`} onClick={() => openTask(task)}>{task.title}</button><div className="task-meta"><span className={`priority ${task.priority}`}>{task.priority}</span><span>{task.status.replace("_", " ")}</span>{task.category && <span>{task.category}</span>}{task.estimated_duration != null && <span>{task.actual_duration || 0}/{task.estimated_duration} min</span>}{task.deadline && <span className={new Date(task.deadline) < new Date() && !taskDone(task) ? "danger" : ""}>Due {new Date(task.deadline).toLocaleDateString()}</span>}{!!task.repeat_weekdays?.length && <span>Repeats · completion is for today</span>}{!!task.checklist?.length && <span>{task.checklist.filter(c => c.done).length}/{task.checklist.length} checklist</span>}</div></div><div className="task-actions"><button className="icon-button" aria-label={`Edit ${task.title}`} onClick={() => openTask(task)}><Pencil /></button>{!task.is_archived && <button className="icon-button" disabled={!!run || !timerReady || task.status === "completed"} aria-label={`Focus on ${task.title}`} onClick={() => startFocus(task.id)}><Play /></button>}<button className="icon-button" disabled={busy} aria-label={`${task.is_archived ? "Restore" : "Archive"} ${task.title}`} onClick={() => void act(async () => { await api(`/tasks/${task.id}/${task.is_archived ? "restore" : "archive"}`, request("POST")); })}>{task.is_archived ? <RotateCcw /> : <Archive />}</button><button className="icon-button danger" disabled={busy} aria-label={`Delete ${task.title}`} onClick={() => { if (window.confirm(`Permanently delete "${task.title}"?`)) void act(async () => { await api(`/tasks/${task.id}`, request("DELETE")); }); }}><Trash2 /></button></div></article>)}</section></div>}
    {tab === "Habits" && <div className="stack"><section className="card"><div className="section-heading"><h2>This week</h2><strong>{scheduled ? Math.round(completed / scheduled * 100) : 0}%</strong></div><progress aria-label="Weekly habit completion" value={completed} max={Math.max(1, scheduled)} /><p className="muted">{completed} of {scheduled} scheduled completions done</p></section>{!habits.length && !loading && !loadError && <section className="card empty"><h2>Build a little momentum</h2><p>Create a habit, then log your daily progress.</p></section>}<div className="habit-grid">{habits.map(stats => { const h = stats.habit; const count = stats.last_7_days.find(d => d.date === today)?.completed_count || 0; const due = !h.repeat_weekdays?.length || h.repeat_weekdays.includes(new Date().getDay()); return <article className="card stack" key={h.id}><div className="section-heading"><div><h2>{h.title}</h2><p className="muted">{h.repeat_weekdays?.length ? h.repeat_weekdays.map(d => weekdays[d]).join(", ") : "Every day"} · goal {h.daily_goal}/day</p></div><span className="badge">{stats.current_streak} day streak</span></div><div className="habit-bars" aria-label="Last seven days">{stats.last_7_days.map(d => <div key={d.date} title={`${d.date}: ${d.completed_count}/${h.daily_goal}${d.scheduled ? "" : " (not scheduled)"}`}><div className="bar-track"><div className={d.completed_count >= h.daily_goal ? "bar complete" : "bar"} style={{ height: `${Math.min(100, d.completed_count / h.daily_goal * 100)}%` }} /></div><span>{weekdays[new Date(`${d.date}T12:00:00`).getDay()].slice(0, 1)}</span><span className="sr-only">{d.date}: {d.completed_count} completions</span></div>)}</div><div className="row spread"><span className="muted">30-day rate: {Math.round(stats.completion_rate_30d * 100)}%<br />Best streak: {stats.best_streak} days</span><span className="badge">{stats.completion_rate_30d >= .75 ? "On track" : "Needs work"}</span></div><form className="row" onSubmit={event => { event.preventDefault(); const data = new FormData(event.currentTarget); void act(async () => { await api(`/habits/${h.id}/logs/day?timezone=${encodeURIComponent(timezone())}`, request("PUT", { count: Number(data.get("count")), date: today })); }); }}><label className="grow">Today{!due && " (not scheduled)"}<input key={`${count}-${reload}`} type="number" name="count" min={0} max={1000} required defaultValue={count} /></label><button disabled={busy}>Set count</button><button type="button" className="icon-button danger" disabled={busy} aria-label={`Delete habit ${h.title}`} onClick={() => { if (window.confirm(`Delete habit "${h.title}" and its history?`)) void act(async () => { await api(`/habits/${h.id}`, request("DELETE")); }); }}><Trash2 /></button></form></article>; })}</div></div>}
    {tab === "Focus" && <div className="focus-layout"><section className="card timer-card"><p className="eyebrow">{run?.ended !== undefined ? "Session needs review" : run ? "One thing at a time" : "Make room for deep work"}</p><h2>{run ? tasks.find(t => t.id === run.taskId)?.title || "Focus session" : "Your focus starts here"}</h2><div className="timer-display" role="timer" aria-label={`Elapsed time ${timerText}`}>{timerText}</div>
      {timerIssue && <p className="error" role="alert">{timerIssue}</p>}
      {!run ? <div className="stack"><label>Task<select value={focusTask} onChange={e => setFocusTask(e.target.value)}><option value="">Free focus (no task)</option>{tasks.filter(t => t.status !== "completed").map(t => <option key={t.id} value={t.id}>{t.title}</option>)}</select></label><label>Category<input maxLength={100} value={focusCategory} onChange={e => setFocusCategory(e.target.value)} placeholder="Optional" /></label><button className="primary" disabled={!timerReady || busy} onClick={() => startFocus()}><Play />Start focus session</button></div> : <div className="stack">
        <p className="muted">Started {new Date(run.started).toLocaleString()}{run.category ? ` · ${run.category}` : ""}</p>
        <button className="primary" disabled={busy || !timerReady || run.ended !== undefined || !!run.uncertain || !!run.sessionId} onClick={() => void saveFocus()}><Square />{busy ? "Working..." : run.ended !== undefined ? "Saving disabled: review required" : "Stop & log session"}</button>
        {run.sessionId && <p className="muted">Confirmed saved session: {run.sessionId}. Task time may or may not have been updated.</p>}
        {run.ended !== undefined && <div className="stack compact"><p className="muted" role="status">A save was started in this or another tab. If it failed or was interrupted, check session history and task time before discarding pending state. Writes cannot be retried safely because the API is not idempotent.</p><button disabled={busy} onClick={refresh}><RefreshCw />Check session history</button>{run.taskId && <button disabled={busy} onClick={() => { setTab("Tasks"); setFilter("all"); setSearch(tasks.find(t => t.id === run.taskId)?.title || ""); refresh(); }}>Check task time</button>}</div>}
        <button className="text-button danger" disabled={busy || !timerReady} onClick={discardFocus}>{run.ended !== undefined ? "Discard pending state (no writes)" : "Discard session"}</button>
      </div>}
      <p className="muted small">With browser storage available, the timer resumes across reloads and synchronizes between tabs. Sessions retain seconds; task time includes only whole minutes. Sessions shorter than 60 seconds do not add task time.</p>
    </section><div className="stack"><section className="card"><div className="section-heading"><h2>Focus summary</h2><label><span className="sr-only">Summary period</span><select value={range} onChange={e => setRange(Number(e.target.value))}>{[1, 3, 7, 14, 28].map(d => <option value={d} key={d}>{d === 1 ? "Today" : `Last ${d} days`}</option>)}</select></label></div>{summary && <><div className="stat-grid"><div><strong>{Math.round(summary.total_duration_seconds / 60)}</strong><span>focused minutes</span></div><div><strong>{summary.session_count}</strong><span>sessions</span></div></div>{summary.analysis && <p className="analysis">{summary.analysis}</p>}</>}</section><section className="card"><h2>Recent sessions</h2>{!sessions.length && !loading && !loadError && <p className="empty">Your saved sessions will appear here.</p>}{[...sessions].sort((a, b) => b.started_at.localeCompare(a.started_at)).map(s => <article className="session-row" key={s.id}><div className="grow"><h3>{tasks.find(t => t.id === s.task_id)?.title || s.category || "Free focus"}</h3><p className="muted">{new Date(s.started_at).toLocaleDateString()} · {timeLabel(s.started_at)} - {timeLabel(s.ended_at)}</p></div><strong>{Math.round(s.duration_seconds / 60)} min</strong></article>)}</section><button onClick={() => setSheet("assistant")}><MessageCircle />Talk to your assistant</button></div></div>}
    </main>
    {sheet === "task" && <Sheet title={editing ? "Edit task" : "New task"} onClose={closeSheet}>{error && <p role="alert" className="error">{error}</p>}<TaskForm task={editing} busy={busy} onSave={body => void act(async () => { await api(editing ? `/tasks/${editing.id}` : "/tasks", request(editing ? "PATCH" : "POST", body)); }, true)} /></Sheet>}
    {sheet === "habit" && <Sheet title="New habit" onClose={closeSheet}>{error && <p role="alert" className="error">{error}</p>}<HabitForm busy={busy} onSave={body => void act(async () => { await api("/habits", request("POST", body)); }, true)} /></Sheet>}
    {sheet === "block" && <Sheet title="Schedule a task" onClose={closeSheet}>{error && <p role="alert" className="error">{error}</p>}<form className="stack" onSubmit={event => { event.preventDefault(); const data = new FormData(event.currentTarget); const start = new Date(String(data.get("start"))); const end = new Date(String(data.get("end"))); if (end <= start) { setError("End time must be after start time."); return; } const task = tasks.find(t => t.id === data.get("task")); void act(async () => { await api("/calendar/blocks", request("POST", { task_id: task?.id, title: String(data.get("title") || task?.title).trim(), start_at: start.toISOString(), end_at: end.toISOString() })); }, true); }}><label>Task<select autoFocus required name="task" defaultValue=""><option value="" disabled>Choose a task</option>{tasks.filter(t => t.status !== "completed").map(t => <option value={t.id} key={t.id}>{t.title}</option>)}</select></label>{!tasks.some(t => t.status !== "completed") && <p className="muted">Create an active task in the Tasks tab first.</p>}<label>Block title<input name="title" maxLength={255} placeholder="Defaults to task title" /></label><label>Start<input type="datetime-local" name="start" required defaultValue={`${selectedDate}T09:00`} /></label><label>End<input type="datetime-local" name="end" required defaultValue={`${selectedDate}T10:00`} /></label><button className="primary" disabled={busy || !tasks.some(t => t.status !== "completed")}>{busy ? "Saving..." : "Add to schedule"}</button></form></Sheet>}
    {sheet === "settings" && <Sheet title="Settings" onClose={closeSheet}><div className="stack">{error && <p className="error" role="alert">{error}</p>}<section className="settings-account"><h3>{user.name || "Your account"}</h3><p className="muted">{user.email}</p></section><label>Appearance<select value={theme} onChange={e => setTheme(e.target.value)}><option value="system">System</option><option value="light">Light</option><option value="dark">Dark</option></select></label><div><h3>Time zone</h3><p className="muted">{timezone()} · Uses your device time zone.</p></div>
      <SchedulingPreferences onSaved={() => { setRecommendations(null); refresh(); }} />
      <p className="muted">Authentication is managed by the app. Planner data is saved to your account. Focus timers use browser storage when available; durability cannot be guaranteed if storage fails.</p><button className="danger" disabled={busy} onClick={() => void act(async () => { if (run && !window.confirm("A focus session exists. Check any pending save against history and task time before leaving. Sign out?")) return; await onLogout(); })}>{busy ? "Signing out..." : "Sign out"}</button></div></Sheet>}
    {sheet === "assistant" && <Assistant onClose={() => setSheet(null)} />}
  </div>;
}
