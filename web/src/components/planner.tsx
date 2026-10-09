"use client";

import { useEffect, useRef, useState, type ReactNode, type FormEvent } from "react";
import {
  CalendarDays,
  ListChecks,
  CircleCheck,
  Timer,
  Settings,
  MessageCircle,
  Plus,
  ChevronLeft,
  ChevronRight,
  X,
  RefreshCw,
  Play,
  Square,
  Archive,
  RotateCcw,
  Pencil,
  Trash2,
} from "lucide-react";
import { Assistant } from "@/components/assistant";
import { Sheet } from "@/components/sheet";
import { api } from "@/lib/api";
import { offlineTasksChangedEvent } from "@/lib/offline";
import { NotificationPreferences } from "@/components/notification-preferences";
import { CalendarAvailability, availabilityCovers, emptyCalendarAvailability } from "@/components/calendar-availability";
import { ScheduleProposals } from "@/components/schedule-proposals";


type Task = {
  id: string;
  title: string;
  priority: "low" | "medium" | "high";
  status: "pending" | "in_progress" | "completed";
  is_archived: boolean;
  estimated_duration: number | null;
  actual_duration: number | null;
  progress_percent?: number;
  category: string | null;
  deadline: string | null;
  notes: string | null;
  start_at: string | null;
  end_at: string | null;
  description: string | null;
  checklist: { text: string; done: boolean }[] | null;
  repeat_weekdays: number[] | null;
  repeat_ends_on: string | null;
  repeat_overrides?: Record<string, { completed?: boolean; start_at?: string | null; end_at?: string | null }> | null;
};
type Block = {
  id: string;
  task_id: string;
  title: string;
  start_at: string;
  end_at: string;
  completed_at: string | null;
};
type HabitStats = {
  habit: {
    id: string;
    title: string;
    daily_goal: number;
    repeat_weekdays: number[] | null;
  };
  current_streak: number;
  best_streak: number;
  completion_rate_30d: number;
  scheduled_7d: number;
  completed_7d: number;
  last_7_days: { date: string; scheduled: boolean; completed_count: number }[];
};
type Session = {
  id: string;
  task_id: string | null;
  started_at: string;
  ended_at: string;
  duration_seconds: number;
  category: string | null;
};
type Summary = { total_duration_seconds: number; session_count: number };
type Recommendations = {
  days: {
    date: string;
    available_minutes: number;
    items: {
      task_id: string;
      task_title: string;
      part_title: string | null;
      minutes: number;
      reason: string;
      start_at: string | null;
      end_at: string | null;
    }[];
  }[];
  unscheduled: { task_id: string; task_title: string; minutes: number }[];
};
type FocusRun = {
  id?: string;
  operationId?: string;
  started: number;
  taskId: string;
  category: string;
  ended?: number;
  sessionId?: string;
  uncertain?: "session" | "time";
};
type Tab = "Schedule" | "Tasks" | "Habits" | "Focus";
const tabs = [
  { name: "Schedule", icon: CalendarDays },
  { name: "Tasks", icon: ListChecks },
  { name: "Habits", icon: CircleCheck },
  { name: "Focus", icon: Timer },
] as const;
const weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const timezone = () => Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
const dateKey = (date: Date) => `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
const localInput = (value: string | null) => (value ? `${dateKey(new Date(value))}T${new Date(value).toTimeString().slice(0, 5)}` : "");
const timeLabel = (value: string) =>
  new Date(value).toLocaleTimeString([], {
    hour: "numeric",
    minute: "2-digit",
  });
const errorText = (error: unknown) => (error instanceof Error ? error.message : "Something went wrong. Please try again.");
const request = (method: string, body?: unknown): RequestInit => ({
  method,
  ...(body === undefined
    ? {}
    : {
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      }),
});

function readFocusRun(key: string): FocusRun | null {
  const saved = localStorage.getItem(key);
  if (saved === null) return null;
  const value = JSON.parse(saved) as FocusRun | null;
  if (
    !value ||
    (value.id !== undefined && (typeof value.id !== "string" || !value.id)) ||
    (value.operationId !== undefined && (typeof value.operationId !== "string" || !uuidPattern.test(value.operationId))) ||
    !Number.isFinite(value.started) ||
    value.started <= 0 ||
    value.started > Date.now() ||
    typeof value.taskId !== "string" ||
    typeof value.category !== "string" ||
    (value.ended !== undefined && (!Number.isFinite(value.ended) || value.ended < value.started)) ||
    (value.sessionId !== undefined && (typeof value.sessionId !== "string" || !value.sessionId || value.ended === undefined)) ||
    (value.operationId !== undefined && ((value.sessionId !== undefined && value.sessionId !== value.operationId) || value.uncertain === "time")) ||
    (value.uncertain !== undefined && (!["session", "time"].includes(value.uncertain) || value.ended === undefined))
  ) {
    throw new Error("Stored focus timer is invalid. It has been left untouched; saving is disabled.");
  }
  return value;
}

function readCategories(key: string): { names: string[]; removed: string[] } {
  const saved = localStorage.getItem(key);
  if (saved === null) return { names: [], removed: [] };
  const value = JSON.parse(saved);
  if (
    !value ||
    ![value.names, value.removed].every(
      (list) => Array.isArray(list) && list.every((name) => typeof name === "string" && name.trim() === name && name.length > 0 && name.length <= 100),
    )
  ) {
    throw new Error("Stored category suggestions are invalid and have been left untouched.");
  }
  return value;
}

function fixedEventsForDay(tasks: Task[], blocks: Block[], day: Date) {
  const next = new Date(day);
  next.setDate(next.getDate() + 1);
  const blocked = new Set(blocks.filter((b) => new Date(b.start_at) < next && new Date(b.end_at) > day).map((b) => b.task_id));
  return tasks.flatMap((task) => {
    if (!task.start_at || !task.end_at || task.is_archived || blocked.has(task.id)) return [];
    const baseStart = new Date(task.start_at);
    const baseEnd = new Date(task.end_at);
    if (!task.repeat_weekdays?.length)
      return baseStart < next && baseEnd > day ? [{ task, start_at: task.start_at, end_at: task.end_at, occurrence_date: dateKey(baseStart) }] : [];
    if (task.status === "completed") return [];
    const endDayOffset = Math.round(
      (Date.UTC(baseEnd.getFullYear(), baseEnd.getMonth(), baseEnd.getDate()) - Date.UTC(baseStart.getFullYear(), baseStart.getMonth(), baseStart.getDate())) /
        86400000,
    );
    const dates = new Set(Object.keys(task.repeat_overrides || {}));
    // Include overnight spillovers and overrides moved onto a different day.
    for (let offset = 0; offset <= endDayOffset; offset++) {
      const source = new Date(day);
      source.setDate(source.getDate() - offset);
      dates.add(dateKey(source));
    }
    return [...dates].flatMap((occurrenceDate) => {
      const source = new Date(`${occurrenceDate}T00:00:00`);
      if (
        !task.repeat_weekdays!.includes(source.getDay()) ||
        occurrenceDate < dateKey(baseStart) ||
        (task.repeat_ends_on && occurrenceDate > dateKey(new Date(task.repeat_ends_on)))
      )
        return [];
      const override = task.repeat_overrides?.[occurrenceDate];
      const start = new Date(source);
      start.setHours(baseStart.getHours(), baseStart.getMinutes(), baseStart.getSeconds(), baseStart.getMilliseconds());
      const end = new Date(source);
      end.setDate(end.getDate() + endDayOffset);
      end.setHours(baseEnd.getHours(), baseEnd.getMinutes(), baseEnd.getSeconds(), baseEnd.getMilliseconds());
      const actualStart = override?.start_at ? new Date(override.start_at) : start;
      const actualEnd = override?.end_at ? new Date(override.end_at) : end;
      return actualStart < next && actualEnd > day
        ? [{ task, start_at: actualStart.toISOString(), end_at: actualEnd.toISOString(), occurrence_date: occurrenceDate }]
        : [];
    });
  });
}


function RepeatDays({ value, onChange }: { value: number[]; onChange: (days: number[]) => void }) {
  return (
    <fieldset>
      <legend>
        Repeat on days <span className="muted">(optional)</span>
      </legend>
      <div className="weekdays">
        {weekdays.map((day, index) => (
          <button
            type="button"
            key={day}
            aria-pressed={value.includes(index)}
            onClick={() => onChange(value.includes(index) ? value.filter((v) => v !== index) : [...value, index].sort())}
          >
            {day}
          </button>
        ))}
      </div>
    </fieldset>
  );
}

function TaskForm({ task, onSave, busy }: { task: Task | null; onSave: (body: Record<string, unknown>) => void; busy: boolean }) {
  const [days, setDays] = useState(task?.repeat_weekdays || []);
  const [checklist, setChecklist] = useState(task?.checklist || []);
  const [validationError, setValidationError] = useState("");
  const [defaults, setDefaults] = useState<Preferences | null>(null);
  const [defaultsLoaded, setDefaultsLoaded] = useState(!!task);
  const [defaultsRetry, setDefaultsRetry] = useState(0);
  useEffect(() => {
    if (task) return;
    let active = true;
    api<Preferences>("/preferences")
      .then((value) => {
        if (active) {
          setDefaults(value);
          setDefaultsLoaded(true);
          setValidationError("");
        }
      })
      .catch((e) => {
        if (active) setValidationError(errorText(e));
      });
    return () => {
      active = false;
    };
  }, [task, defaultsRetry]);
  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const data = new FormData(event.currentTarget);
    const deadline = String(data.get("deadline") || "");
    const ends = String(data.get("repeat_ends_on") || "");
    const start = String(data.get("start_at") || "");
    const end = String(data.get("end_at") || "");
    // Keep existing seconds and offset when an edit leaves the displayed time unchanged.
    const startAt = start ? (start === localInput(task?.start_at || null) ? task!.start_at : new Date(start).toISOString()) : null;
    const endAt = end ? (end === localInput(task?.end_at || null) ? task!.end_at : new Date(end).toISOString()) : null;
    if (!!startAt !== !!endAt || (startAt && endAt && new Date(endAt) <= new Date(startAt))) {
      setValidationError("Set both fixed-event times, with the end after the start, or leave both blank.");
      return;
    }
    setValidationError("");
    onSave({
      title: String(data.get("title")).trim(),
      description: data.get("description") || null,
      priority: data.get("priority"),
      status: data.get("status"),
      estimated_duration: data.get("estimated_duration") ? Number(data.get("estimated_duration")) : null,
      actual_duration: data.get("actual_duration") !== "" ? Number(data.get("actual_duration")) : null,
      category: data.get("category") || null,
      deadline: deadline ? new Date(deadline).toISOString() : null,
      start_at: startAt,
      end_at: endAt,
      notes: data.get("notes") || null,
      checklist: checklist.filter((item) => item.text.trim()).map((item) => ({ ...item, text: item.text.trim() })),
      repeat_weekdays: days.length ? days : null,
      repeat_ends_on: ends ? new Date(`${ends}T23:59:59`).toISOString() : null,
    });
  }
  if (!defaultsLoaded)
    return (
      <div className="stack">
        <p role="status">Loading task defaults...</p>
        {validationError && (
          <p className="error" role="alert">
            {validationError}
          </p>
        )}
        <button onClick={() => setDefaultsRetry((v) => v + 1)}>Retry task defaults</button>
      </div>
    );
  return (
    <form onSubmit={submit} className="stack">
      <label>
        Title
        <input autoFocus required name="title" maxLength={255} defaultValue={task?.title} placeholder="What needs to get done?" />
      </label>
      <div className="form-grid">
        <label>
          Priority
          <select name="priority" defaultValue={task?.priority || defaults?.default_priority || "medium"}>
            <option value="low">Low</option>
            <option value="medium">Medium</option>
            <option value="high">High</option>
          </select>
        </label>
        <label>
          Status
          <select name="status" defaultValue={task?.status || "pending"}>
            <option value="pending">Pending</option>
            <option value="in_progress">In progress</option>
            <option value="completed">Completed (entire task)</option>
          </select>
        </label>
        <label>
          Estimated minutes
          <input
            name="estimated_duration"
            type="number"
            min={1}
            max={525600}
            defaultValue={task ? (task.estimated_duration ?? "") : (defaults?.default_duration_minutes ?? "")}
          />
        </label>
        <label>
          Actual minutes
          <input name="actual_duration" type="number" min={0} max={525600} defaultValue={task?.actual_duration ?? ""} />
        </label>
        <p className="muted small">Actual minutes replace the tracked total and determine duration progress. Focus history is not changed.</p>
        <label>
          Category
          <input name="category" list="planner-categories" maxLength={100} defaultValue={task?.category || ""} />
        </label>
      </div>
      <label>
        Deadline
        <input name="deadline" type="datetime-local" defaultValue={localInput(task?.deadline || null)} />
      </label>
      <fieldset className="stack compact">
        <legend>
          Fixed event <span className="muted">(optional)</span>
        </legend>
        <div className="form-grid">
          <label>
            Starts
            <input name="start_at" type="datetime-local" defaultValue={localInput(task?.start_at || null)} />
          </label>
          <label>
            Ends
            <input name="end_at" type="datetime-local" defaultValue={localInput(task?.end_at || null)} />
          </label>
        </div>
        <p className="muted small">Set both times to place this task on the calendar. Repeat days use these local times.</p>
        {validationError && (
          <p className="error" role="alert">
            {validationError}
          </p>
        )}
      </fieldset>
      <label>
        Description
        <textarea name="description" defaultValue={task?.description || ""} rows={2} />
      </label>
      <label>
        Notes
        <textarea name="notes" defaultValue={task?.notes || ""} rows={3} />
      </label>
      <fieldset>
        <legend>Checklist</legend>
        <div className="stack compact">
          {checklist.map((item, index) => (
            <div className="checklist-row" key={index}>
              <input
                type="checkbox"
                aria-label={`Complete checklist item ${index + 1}`}
                checked={item.done}
                onChange={(event) => setChecklist(checklist.map((v, i) => (i === index ? { ...v, done: event.target.checked } : v)))}
              />
              <input
                aria-label={`Checklist item ${index + 1}`}
                maxLength={500}
                value={item.text}
                onChange={(event) => setChecklist(checklist.map((v, i) => (i === index ? { ...v, text: event.target.value } : v)))}
              />
              <button
                type="button"
                className="icon-button"
                aria-label={`Remove checklist item ${index + 1}`}
                onClick={() => setChecklist(checklist.filter((_, i) => i !== index))}
              >
                <X />
              </button>
            </div>
          ))}
          <button type="button" onClick={() => setChecklist([...checklist, { text: "", done: false }])}>
            <Plus /> Add checklist item
          </button>
        </div>
      </fieldset>
      <RepeatDays value={days} onChange={setDays} />
      {days.length > 0 && (
        <label>
          Repeat until
          <input type="date" name="repeat_ends_on" defaultValue={task?.repeat_ends_on ? dateKey(new Date(task.repeat_ends_on)) : ""} />
        </label>
      )}
      <button className="primary" disabled={busy}>
        {busy ? "Saving..." : task ? "Save changes" : "Create task"}
      </button>
    </form>
  );
}

function HabitForm({ onSave, busy, habit }: { onSave: (body: unknown) => void; busy: boolean; habit: HabitStats["habit"] | null }) {
  const [days, setDays] = useState<number[]>(habit?.repeat_weekdays || []);
  return (
    <form
      className="stack"
      onSubmit={(event) => {
        event.preventDefault();
        const data = new FormData(event.currentTarget);
        onSave({
          title: String(data.get("title")).trim(),
          daily_goal: Number(data.get("goal")),
          repeat_weekdays: days.length ? days : null,
        });
      }}
    >
      <label>
        Habit name
        <input autoFocus required name="title" defaultValue={habit?.title} maxLength={255} placeholder="A small step, every day" />
      </label>
      <label>
        Daily goal
        <input type="number" name="goal" min={1} max={100} defaultValue={habit?.daily_goal || 1} required />
      </label>
      <RepeatDays value={days} onChange={setDays} />
      <p className="muted">No days selected means every day.</p>
      <button className="primary" disabled={busy}>
        {busy ? "Saving..." : habit ? "Save habit" : "Create habit"}
      </button>
    </form>
  );
}


type Preferences = {
  work_hours_start: number;
  work_hours_end: number;
  buffer_minutes: number;
  energy_level: number;
  max_daily_hours: number;
  default_duration_minutes: number;
  default_priority: string;
};
function SchedulingPreferences({ onSaved }: { onSaved: () => void }) {
  const [preferences, setPreferences] = useState<Preferences | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [saved, setSaved] = useState(false);
  const [retry, setRetry] = useState(0);
  useEffect(() => {
    let active = true;
    setLoading(true);
    setError("");
    api<Preferences>("/preferences")
      .then((result) => {
        if (active) setPreferences(result);
      })
      .catch((e) => {
        if (active) setError(errorText(e));
      })
      .finally(() => {
        if (active) setLoading(false);
      });
    return () => {
      active = false;
    };
  }, [retry]);
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (saving) return;
    const data = new FormData(event.currentTarget);
    const body = {
      work_hours_start: Number(data.get("work_hours_start")),
      work_hours_end: Number(data.get("work_hours_end")),
      buffer_minutes: Number(data.get("buffer_minutes")),
      energy_level: Number(data.get("energy_level")),
      max_daily_hours: Number(data.get("max_daily_hours")),
      default_duration_minutes: Number(data.get("default_duration_minutes")),
      default_priority: String(data.get("default_priority")),
    };
    setError("");
    setSaved(false);
    if (body.work_hours_end <= body.work_hours_start) {
      setError("Work hours must end after they start.");
      return;
    }
    setSaving(true);
    try {
      setPreferences(await api<Preferences>("/preferences", request("PUT", body)));
      setSaved(true);
      onSaved();
    } catch (e) {
      setError(errorText(e));
    } finally {
      setSaving(false);
    }
  }
  return (
    <section className="stack">
      <h3>Scheduling preferences</h3>
      {loading && (
        <p className="muted" role="status">
          Loading preferences...
        </p>
      )}
      {error && (
        <div className="error" role="alert">
          {error}
          {!preferences && (
            <button type="button" disabled={loading} onClick={() => setRetry((v) => v + 1)}>
              Retry
            </button>
          )}
        </div>
      )}
      {preferences && !loading && (
        <form className="stack" onSubmit={submit} onChange={() => setSaved(false)}>
          <fieldset disabled={saving} className="form-grid">
            <label>
              Work starts (hour)
              <input required type="number" name="work_hours_start" min={0} max={24} step={0.5} defaultValue={preferences.work_hours_start} />
            </label>
            <label>
              Work ends (hour)
              <input required type="number" name="work_hours_end" min={0} max={24} step={0.5} defaultValue={preferences.work_hours_end} />
            </label>
            <label>
              Buffer minutes
              <input required type="number" name="buffer_minutes" min={0} max={120} defaultValue={preferences.buffer_minutes} />
            </label>
            <label>
              Energy level (1-5)
              <input required type="number" name="energy_level" min={1} max={5} defaultValue={preferences.energy_level} />
            </label>
            <label>
              Maximum daily hours
              <input required type="number" name="max_daily_hours" min={1} max={24} defaultValue={preferences.max_daily_hours} />
            </label>
            <label>
              Default task minutes
              <input required type="number" name="default_duration_minutes" min={5} max={480} defaultValue={preferences.default_duration_minutes} />
            </label>
            <label>
              Default priority
              <select name="default_priority" defaultValue={preferences.default_priority}>
                <option value="low">Low</option>
                <option value="medium">Medium</option>
                <option value="high">High</option>
              </select>
            </label>
          </fieldset>
          <p className="muted small">
            Hours use 24-hour notation in half-hour steps, for example 9.5 = 09:30. These preferences guide scheduling recommendations.
          </p>
          <button className="primary" disabled={saving}>
            {saving ? "Saving..." : "Save preferences"}
          </button>
          {saved && (
            <p role="status" className="muted">
              Preferences saved.
            </p>
          )}
        </form>
      )}
    </section>
  );
}

export default function Planner({ user, onLogout }: { user: { id: string; name: string | null; email: string | null }; onLogout: () => Promise<void> }) {
  const [availability, setAvailability] = useState(emptyCalendarAvailability);
  const [tab, setTab] = useState<Tab>("Schedule");
  const [reload, setReload] = useState(0);
  const [tasks, setTasks] = useState<Task[]>([]);
  const [archivedTasks, setArchivedTasks] = useState<Task[]>([]);
  const [blocks, setBlocks] = useState<Block[]>([]);
  const [habits, setHabits] = useState<HabitStats[]>([]);
  const [sessions, setSessions] = useState<Session[]>([]);
  const [summary, setSummary] = useState<Summary | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [sheet, setSheet] = useState<"task" | "habit" | "block" | "occurrence" | "reschedule" | "session" | "settings" | "assistant" | null>(null);
  const [editing, setEditing] = useState<Task | null>(null);
  const [editingHabit, setEditingHabit] = useState<HabitStats["habit"] | null>(null);
  const [editingBlock, setEditingBlock] = useState<Block | null>(null);
  const [editingSession, setEditingSession] = useState<Session | null>(null);
  const [occurrence, setOccurrence] = useState<{ task: Task; date: string; start: string; end: string } | null>(null);
  const [focusFilter, setFocusFilter] = useState("all");
  const [search, setSearch] = useState("");
  const [filter, setFilter] = useState("active");
  const [sort, setSort] = useState("created_at");
  const [order, setOrder] = useState("desc");
  const [quickAdd, setQuickAdd] = useState("");
  const [selectedDate, setSelectedDate] = useState(() => dateKey(new Date()));
  const [month, setMonth] = useState(() => new Date(new Date().getFullYear(), new Date().getMonth(), 1));
  const [recommendations, setRecommendations] = useState<Recommendations | null>(null);
  const [recommendBusy, setRecommendBusy] = useState(false);
  const [recommendError, setRecommendError] = useState("");
  const recommendSequence = useRef(0);
  useEffect(() => {
    recommendSequence.current++;
    setRecommendations(null);
    setRecommendError("");
    setRecommendBusy(false);
  }, [selectedDate, tab, reload, availability]);
  const [range, setRange] = useState(7);
  const [run, setRun] = useState<FocusRun | null>(null);
  const [clock, setClock] = useState(Date.now());
  const [timerReady, setTimerReady] = useState(false);
  const [timerIssue, setTimerIssue] = useState("");
  const operationBusy = useRef(false);
  const [focusTask, setFocusTask] = useState("");
  const [focusCategory, setFocusCategory] = useState("");
  const [theme, setTheme] = useState("system");
  const timerKey = `planner.focus.v1:${user.id}`;
  const categoryKey = `planner.categories.v1:${user.id}`;
  const [categoryStore, setCategoryStore] = useState<{ key: string; names: string[]; removed: string[] } | null>(null);
  const [categoryIssue, setCategoryIssue] = useState("");
  const [categoryReload, setCategoryReload] = useState(0);
  const [newCategory, setNewCategory] = useState("");
  useEffect(() => {
    setCategoryStore(null);
    setNewCategory("");
    setCategoryIssue("");
    function syncCategories() {
      try {
        if (!uuidPattern.test(user.id)) throw new Error("Account ID is missing. Category management is disabled.");
        setCategoryStore({ key: categoryKey, ...readCategories(categoryKey) });
        setCategoryIssue("");
      } catch (e) {
        setCategoryStore(null);
        setCategoryIssue(errorText(e));
      }
    }
    function onStorage(event: StorageEvent) {
      if (event.key === categoryKey || event.key === null) syncCategories();
    }
    syncCategories();
    window.addEventListener("storage", onStorage);
    return () => window.removeEventListener("storage", onStorage);
  }, [categoryKey, user.id, categoryReload]);
  function changeCategory(name: string, remove = false) {
    const cleaned = name.trim();
    if (!cleaned || cleaned.length > 100 || categoryStore?.key !== categoryKey) return;
    try {
      const current = readCategories(categoryKey);
      const value = remove
        ? { names: current.names.filter((c) => c !== cleaned), removed: [...new Set([...current.removed, cleaned])] }
        : { names: [...new Set([...current.names, cleaned])], removed: current.removed.filter((c) => c !== cleaned) };
      localStorage.setItem(categoryKey, JSON.stringify(value));
      setCategoryStore({ key: categoryKey, ...value });
      setCategoryIssue("");
      setNewCategory("");
    } catch (e) {
      setCategoryIssue(`Category suggestions could not be saved. ${errorText(e)}`);
    }
  }
  const refresh = () => setReload((v) => v + 1);
  useEffect(() => {
    const onTasksChanged = () => setReload((value) => value + 1);
    window.addEventListener(offlineTasksChangedEvent, onTasksChanged);
    return () => window.removeEventListener(offlineTasksChangedEvent, onTasksChanged);
  }, [user.id]);
  useEffect(() => {
    let active = true;
    setLoading(true);
    setLoadError("");
    async function load() {
      try {
        const taskQuery = `sort=${sort}&order=${order}`;
        const taskResult = await api<{ items: Task[] }>(`/tasks?${taskQuery}`);
        if (!active) return;
        setTasks(taskResult.items);
        if (tab === "Tasks") {
          const result = await api<{ items: Task[] }>(`/tasks?archived=true&${taskQuery}`);
          if (active) setArchivedTasks(result.items);
        }
        if (tab === "Schedule") {
          const result = await api<{ items: Block[] }>("/calendar/blocks");
          if (active) setBlocks(result.items);
        }
        if (tab === "Habits") {
          const result = await api<{ habits: HabitStats[] }>(`/habits/dashboard?timezone=${encodeURIComponent(timezone())}`);
          if (active) setHabits(result.habits);
        }
        if (tab === "Focus") {
          const start = new Date();
          start.setDate(start.getDate() - range + 1);
          start.setHours(0, 0, 0, 0);
          const query = `?after=${encodeURIComponent(start.toISOString())}&before=${encodeURIComponent(new Date().toISOString())}`;
          const [history, stats] = await Promise.all([api<Session[]>(`/focus/sessions${query}`), api<Summary>(`/focus/summary${query}`)]);
          if (active) {
            setSessions(history);
            setSummary(stats);
          }
        }
      } catch (e) {
        if (active) setLoadError(errorText(e));
      } finally {
        if (active) setLoading(false);
      }
    }
    void load();
    return () => {
      active = false;
    };
  }, [tab, reload, range, sort, order]);
  useEffect(() => {
    setRun(null);
    setTimerReady(false);
    function syncTimer() {
      try {
        if (!uuidPattern.test(user.id)) throw new Error("Account ID is missing. Focus timer changes are disabled.");
        const current = readFocusRun(timerKey);
        setRun(current);
        setClock(Date.now());
        setTimerReady(!!navigator.locks);
        setTimerIssue(
          navigator.locks
            ? ""
            : "This browser does not support Web Locks. Timer changes and automatic saving are disabled to prevent duplicate writes. Use a supported browser on this device and check session history and task time before discarding pending work.",
        );
      } catch (e) {
        setTimerReady(false);
        setTimerIssue(
          `Focus storage is unavailable or invalid. Durability cannot be guaranteed, so timer changes and saving are disabled. Existing storage is left untouched. ${errorText(e)}`,
        );
      }
    }
    function onStorage(event: StorageEvent) {
      if (event.key === timerKey || event.key === null) {
        syncTimer();
        refresh();
      }
    }
    syncTimer();
    try {
      const storedTheme = localStorage.getItem("planner.theme");
      if (["system", "light", "dark"].includes(storedTheme || "")) setTheme(storedTheme!);
    } catch {
      /* Theme storage is independent of timer safety. */
    }
    window.addEventListener("storage", onStorage);
    window.addEventListener("focus", syncTimer);
    return () => {
      window.removeEventListener("storage", onStorage);
      window.removeEventListener("focus", syncTimer);
    };
  }, [timerKey]);
  useEffect(() => {
    if (!run || run.ended) return;
    setClock(Date.now());
    const id = window.setInterval(() => setClock(Date.now()), 1000);
    return () => window.clearInterval(id);
  }, [run]);
  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    try {
      localStorage.setItem("planner.theme", theme);
    } catch {
      /* Theme still applies when storage is unavailable. */
    }
  }, [theme]);
  async function act(action: () => Promise<void>, close = false) {
    if (operationBusy.current) return;
    operationBusy.current = true;
    setBusy(true);
    setError("");
    try {
      await action();
      if (close) setSheet(null);
      refresh();
    } catch (e) {
      setError(errorText(e));
    } finally {
      operationBusy.current = false;
      setBusy(false);
    }
  }
  function openTask(task: Task | null = null) {
    setEditing(task);
    setError("");
    setSheet("task");
  }
  function closeSheet() {
    if (!busy) {
      setSheet(null);
      setError("");
    }
  }
  const today = dateKey(new Date());
  const taskDone = (task: Task, date = today) =>
    task.status === "completed" || (task.repeat_weekdays?.length ? !!task.repeat_overrides?.[date]?.completed : false);
  function toggleTask(task: Task, date = today) {
    void act(async () => {
      if (task.repeat_weekdays?.length)
        await api(
          `/tasks/${task.id}/occurrence/completion`,
          request("PATCH", {
            date,
            completed: !taskDone(task, date),
            timezone: timezone(),
          }),
        );
      else if (taskDone(task, date)) await api(`/tasks/${task.id}`, request("PATCH", { status: "pending" }));
      else await api(`/tasks/${task.id}/complete`, request("POST", { timezone: timezone() }));
    });
  }
  async function withFocusLock(action: (current: FocusRun | null) => Promise<void>) {
    if (!uuidPattern.test(user.id)) throw new Error("A valid account ID is required to change the focus timer. No writes were sent.");
    if (!navigator.locks)
      throw new Error(
        "Automatic focus saving is unavailable without Web Locks. No writes were sent. Use a supported browser and check history/task time before discarding pending work.",
      );
    await navigator.locks.request(timerKey, { ifAvailable: true }, async (lock) => {
      if (!lock) throw new Error("Another tab is changing this focus session. Wait for it to finish; no writes were sent from this tab.");
      let current: FocusRun | null;
      try {
        current = readFocusRun(timerKey);
      } catch (e) {
        setTimerReady(false);
        setTimerIssue("Focus storage could not be read. Timer changes are disabled and existing storage is left untouched.");
        throw e;
      }
      setRun(current);
      await action(current);
    });
  }
  function persistFocus(value: FocusRun | null) {
    setRun(value);
    try {
      if (value) localStorage.setItem(timerKey, JSON.stringify(value));
      else localStorage.removeItem(timerKey);
    } catch {
      setTimerReady(false);
      setTimerIssue(
        "Focus state could not be persisted. Durability cannot be guaranteed. Keep this page open, check session history and task time, and do not resend writes.",
      );
      throw new Error("Focus storage failed. No further API writes will be sent.");
    }
  }
  function startFocus(taskId = focusTask) {
    void act(async () =>
      withFocusLock(async (current) => {
        setTab("Focus");
        if (current)
          throw new Error("A focus session already exists in this browser. Continue it or review and discard its pending state before starting another.");
        const started = Date.now();
        persistFocus({
          operationId: crypto.randomUUID(),
          started,
          taskId,
          category: focusCategory.trim() || tasks.find((t) => t.id === taskId)?.category || "",
        });
        setClock(started);
      }),
    );
  }
  async function saveFocus() {
    if (!run) return;
    await act(async () =>
      withFocusLock(async (current) => {
        if (!current || current.id !== run.id || current.operationId !== run.operationId || current.started !== run.started || current.taskId !== run.taskId)
          throw new Error("The focus session changed in another tab. This tab has been synchronized; no writes were sent.");
        // Never invent an operation ID for a legacy write that may already have succeeded.
        if (!current.operationId && (current.ended !== undefined || current.uncertain || current.sessionId))
          throw new Error(
            "This legacy session needs manual review. Check session history and task time, then discard its pending state. It has no operation ID and cannot be retried safely.",
          );
        const pending: FocusRun & { ended: number } = {
          ...current,
          operationId: current.operationId || crypto.randomUUID(),
          ended: current.ended ?? Math.max(Date.now(), current.started + 1000),
          uncertain: "session",
        };
        const seconds = Math.max(1, Math.floor((pending.ended - pending.started) / 1000));
        if (seconds > 2592000) throw new Error("This session exceeds the API's 30-day limit. Discard it and start a new session.");
        persistFocus({ ...pending });
        try {
          const saved = await api<Session>(
            "/focus/sessions",
            request("POST", {
              session_id: pending.operationId,
              record_task_time: true,
              task_id: pending.taskId || null,
              started_at: new Date(pending.started).toISOString(),
              ended_at: new Date(Math.max(pending.ended, pending.started + 1000)).toISOString(),
              duration_seconds: seconds,
              category: pending.category || null,
            }),
          );
          if (saved.id !== pending.operationId) throw new Error("The server did not confirm the requested session ID. Check session history before retrying.");
          pending.sessionId = saved.id;
          pending.uncertain = undefined;
          persistFocus({ ...pending });
          persistFocus(null);
        } catch (e) {
          setRun({ ...pending });
          refresh();
          throw new Error(
            `${errorText(e)} The save outcome may be uncertain. Retry save explicitly to replay the same session ID and stopped times safely. No automatic retry is sent.`,
          );
        }
      }),
    );
  }
  function discardFocus() {
    if (!run) return;
    void act(async () =>
      withFocusLock(async (current) => {
        if (!current || current.id !== run.id || current.operationId !== run.operationId || current.started !== run.started || current.taskId !== run.taskId)
          throw new Error("The focus session changed in another tab. Review the synchronized timer before discarding it.");
        if (
          window.confirm(
            current.ended !== undefined
              ? "Check session history and task time first. Discard only this pending browser state? Saved server data will remain, and no API writes will be sent."
              : "Discard this focus session without saving?",
          )
        )
          persistFocus(null);
      }),
    );
  }
  async function recommend() {
    if (!availabilityCovers(availability, selectedDate)) return;
    const token = ++recommendSequence.current;
    setRecommendBusy(true);
    setRecommendError("");
    setRecommendations(null);
    try {
      const result = await api<Recommendations>(
        "/recommendations/daily",
        request("POST", {
          timezone: timezone(),
          start_date: `${selectedDate}T00:00:00`,
          end_date: `${selectedDate}T23:59:59`,
          busy_times: availability.busyTimes,
        }),
      );
      if (token === recommendSequence.current) setRecommendations(result);
    } catch (e) {
      if (token === recommendSequence.current) setRecommendError(errorText(e));
    } finally {
      if (token === recommendSequence.current) setRecommendBusy(false);
    }
  }
  const displayedTasks = (filter === "archived" ? archivedTasks : tasks).filter(
    (t) =>
      (filter !== "active" || t.status !== "completed") &&
      (filter !== "completed" || t.status === "completed") &&
      `${t.title} ${t.description || ""} ${t.category || ""} ${t.notes || ""}`.toLowerCase().includes(search.toLowerCase()),
  );
  const dayStart = new Date(`${selectedDate}T00:00:00`);
  const dayEnd = new Date(dayStart);
  dayEnd.setDate(dayEnd.getDate() + 1);
  const dayBlocks = blocks.filter((b) => new Date(b.start_at) < dayEnd && new Date(b.end_at) > dayStart).sort((a, b) => a.start_at.localeCompare(b.start_at));
  const dayEntries = [
    ...dayBlocks.map((block) => ({
      block,
      task: undefined,
      occurrence_date: undefined,
      title: block.title,
      start_at: block.start_at,
      end_at: block.end_at,
      completed: !!block.completed_at,
    })),
    ...fixedEventsForDay(tasks, blocks, dayStart).map((event) => ({
      ...event,
      block: undefined,
      title: event.task.title,
      completed: taskDone(event.task, event.occurrence_date),
    })),
  ].sort((a, b) => a.start_at.localeCompare(b.start_at));
  const elapsed = run ? Math.max(0, Math.floor(((run.ended || clock) - run.started) / 1000)) : 0;
  const timerText = `${String(Math.floor(elapsed / 3600)).padStart(2, "0")}:${String(Math.floor(elapsed / 60) % 60).padStart(2, "0")}:${String(elapsed % 60).padStart(2, "0")}`;
  const calendarStart = new Date(month);
  calendarStart.setDate(1 - month.getDay());
  const calendarDates = Array.from({ length: 42 }, (_, i) => {
    const d = new Date(calendarStart);
    d.setDate(d.getDate() + i);
    return d;
  });
  const scheduled = habits.reduce((sum, h) => sum + h.scheduled_7d, 0);
  const completed = habits.reduce((sum, h) => sum + h.completed_7d, 0);
  const localCategories = categoryStore?.key === categoryKey ? categoryStore : null;
  const categories = [...new Set([...(localCategories?.names || []), ...[...tasks, ...archivedTasks].map((t) => t.category).filter((v): v is string => !!v)])]
    .filter((c) => !localCategories?.removed.includes(c))
    .sort();
  const sessionCategory = (s: Session) => s.category || "Uncategorized";
  const focusCategories = [...new Set(sessions.map(sessionCategory))].sort();
  const filteredSessions = sessions.filter((s) => focusFilter === "all" || sessionCategory(s) === focusFilter);
  const dailyFocus = Object.entries(
    filteredSessions.reduce<Record<string, number>>((totals, s) => {
      const day = dateKey(new Date(s.started_at));
      totals[day] = (totals[day] || 0) + s.duration_seconds;
      return totals;
    }, {}),
  ).sort(([a], [b]) => a.localeCompare(b));
  return (
    <div className="planner">
      <datalist id="planner-categories">
        {categories.map((category) => (
          <option key={category} value={category} />
        ))}
      </datalist>
      <header className="app-header">
        <a className="brand" href="#main">
          <CalendarDays /> <span>My Planner</span>
        </a>
        <div className="header-actions">
          <button className="icon-button" aria-label="Open assistant" onClick={() => setSheet("assistant")}>
            <MessageCircle />
          </button>
          <button
            className="icon-button"
            aria-label="Open settings"
            onClick={() => {
              setError("");
              setSheet("settings");
            }}
          >
            <Settings />
          </button>
        </div>
      </header>
      <nav className="tab-nav" aria-label="Main navigation">
        {tabs.map(({ name, icon: Icon }) => (
          <button
            key={name}
            aria-current={tab === name ? "page" : undefined}
            onClick={() => {
              setTab(name);
              setError("");
            }}
          >
            <Icon />
            <span>{name}</span>
            {name === "Focus" && run && <span className="running-dot" aria-label="Session in progress" />}
          </button>
        ))}
      </nav>
      <main id="main">
        <CalendarAvailability value={availability} onChange={setAvailability} />
        <div className="page-heading">
          <div>
            <p className="eyebrow">
              {new Date().toLocaleDateString([], {
                weekday: "long",
                month: "long",
                day: "numeric",
              })}
            </p>
            <h1>{tab}</h1>
          </div>
          <div className="row">
            <button className="icon-button" aria-label={`Refresh ${tab.toLowerCase()}`} disabled={loading || busy} onClick={refresh}>
              <RefreshCw className={loading ? "spinning" : ""} />
            </button>
            {tab !== "Focus" && (
              <button
                className="primary"
                onClick={() => {
                  setError("");
                  setEditingHabit(null);
                  setEditingBlock(null);
                  if (tab === "Tasks") openTask();
                  else setSheet(tab === "Habits" ? "habit" : "block");
                }}
              >
                <Plus />
                <span>{tab === "Tasks" ? "New task" : tab === "Habits" ? "New habit" : "Add block"}</span>
              </button>
            )}
          </div>
        </div>
        {loadError && (
          <div className="error" role="alert">
            {loadError}
            <button onClick={refresh}>Retry</button>
          </div>
        )}
        {error && !sheet && (
          <div className="error" role="alert">
            {error}
            <button onClick={() => setError("")}>Dismiss</button>
          </div>
        )}
        {loading && (
          <p className="muted" role="status">
            Loading {tab.toLowerCase()}...
          </p>
        )}
        {tab === "Schedule" && (
          <div className="schedule-layout">
            <section className="card calendar-card" aria-label="Month calendar">
              <div className="section-heading">
                <h2>
                  {month.toLocaleDateString([], {
                    month: "long",
                    year: "numeric",
                  })}
                </h2>
                <div className="row">
                  <button className="icon-button" aria-label="Previous month" onClick={() => setMonth(new Date(month.getFullYear(), month.getMonth() - 1, 1))}>
                    <ChevronLeft />
                  </button>
                  <button className="icon-button" aria-label="Next month" onClick={() => setMonth(new Date(month.getFullYear(), month.getMonth() + 1, 1))}>
                    <ChevronRight />
                  </button>
                </div>
              </div>
              <div className="calendar-grid">
                {weekdays.map((d) => (
                  <span className="calendar-weekday" key={d}>
                    {d}
                  </span>
                ))}
                {calendarDates.map((d) => {
                  const key = dateKey(d);
                  const hasEvents = blocks.some((b) => dateKey(new Date(b.start_at)) === key) || fixedEventsForDay(tasks, blocks, d).length > 0;
                  return (
                    <button
                      key={key}
                      className={`${d.getMonth() !== month.getMonth() ? "outside" : ""} ${key === today ? "today" : ""}`}
                      aria-pressed={key === selectedDate}
                      aria-label={`${d.toLocaleDateString([], { dateStyle: "full" })}${hasEvents ? ", scheduled events" : ""}`}
                      onClick={() => {
                        setSelectedDate(key);
                        setRecommendations(null);
                        setRecommendError("");
                      }}
                    >
                      <span>{d.getDate()}</span>
                      <span className={`calendar-dot ${hasEvents ? "visible" : ""}`} />
                    </button>
                  );
                })}
              </div>
              <button
                className="text-button"
                onClick={() => {
                  const d = new Date();
                  setMonth(new Date(d.getFullYear(), d.getMonth(), 1));
                  setSelectedDate(dateKey(d));
                  setRecommendations(null);
                }}
              >
                Go to today
              </button>
            </section>
            <div className="stack">
              <ScheduleProposals date={selectedDate} onChanged={refresh} availability={availability} />
              <section className="card">
                <div className="section-heading">
                  <h2>
                    {dayStart.toLocaleDateString([], {
                      weekday: "long",
                      month: "short",
                      day: "numeric",
                    })}
                  </h2>
                  <span className="muted">{dayEntries.length} events</span>
                </div>
                {!dayEntries.length && !loading && !loadError && <p className="empty">No events scheduled. Give your tasks some time.</p>}
                <div className="stack compact">
                  {dayEntries.map((entry) => (
                    <article
                      className={`schedule-block ${entry.completed ? "done" : ""}`}
                      aria-label={entry.task ? `${entry.title} occurrence ${entry.occurrence_date}` : entry.title}
                      key={entry.block ? `block-${entry.block.id}` : `task-${entry.task.id}-${entry.occurrence_date}`}
                    >
                      <div className="grow">
                        <p className="muted">
                          {timeLabel(entry.start_at)} - {timeLabel(entry.end_at)}
                        </p>
                        <h3>{entry.title}</h3>
                        {entry.task && (
                          <p className="muted">
                            {entry.task.repeat_weekdays?.length ? "Repeating event" : "Fixed event"}
                            {entry.completed ? " · Completed" : ""}
                          </p>
                        )}
                      </div>
                      <button
                        className={`icon-button ${entry.completed ? "checked" : ""}`}
                        disabled={busy}
                        aria-label={`${entry.completed ? "Reopen" : "Complete"} ${entry.title} on ${entry.occurrence_date || selectedDate}`}
                        onClick={() => {
                          if (entry.task) toggleTask(entry.task, entry.occurrence_date);
                          else
                            void act(async () => {
                              await api(`/calendar/blocks/${entry.block.id}/${entry.completed ? "reopen" : "complete"}`, request("POST", {}));
                            });
                        }}
                      >
                        <CircleCheck />
                      </button>
                      {entry.task?.repeat_weekdays?.length ? (
                        <button
                          disabled={busy}
                          aria-label={`Edit occurrence ${entry.title}`}
                          onClick={() => {
                            setError("");
                            setOccurrence({ task: entry.task!, date: entry.occurrence_date!, start: entry.start_at, end: entry.end_at });
                            setSheet("occurrence");
                          }}
                        >
                          Edit occurrence
                        </button>
                      ) : entry.block ? (
                        <button
                          disabled={busy}
                          aria-label={`Edit block ${entry.title}`}
                          onClick={() => {
                            setError("");
                            setEditingBlock(entry.block!);
                            setSheet("block");
                          }}
                        >
                          <Pencil />
                        </button>
                      ) : null}
                      {entry.task ? (
                        <button className="icon-button" aria-label={`Edit event series ${entry.title}`} onClick={() => openTask(entry.task)}>
                          <Pencil />
                        </button>
                      ) : (
                        <button
                          className="icon-button danger"
                          disabled={busy}
                          aria-label={`Delete block ${entry.title}`}
                          onClick={() => {
                            if (window.confirm(`Delete schedule block "${entry.title}"?`))
                              void act(async () => {
                                await api(`/calendar/blocks/${entry.block.id}`, request("DELETE"));
                              });
                          }}
                        >
                          <Trash2 />
                        </button>
                      )}
                    </article>
                  ))}
                </div>
              </section>
              <section className="card">
                <div className="section-heading">
                  <h2>Daily recommendations</h2>
                  <button disabled={recommendBusy || !availabilityCovers(availability, selectedDate)} onClick={() => void recommend()}>
                    <RefreshCw />
                    {recommendBusy ? "Planning..." : recommendations ? "Refresh" : "Generate"}
                  </button>
                </div>
                <p className="muted">Suggested work for the selected date, using your planner preferences.</p>
                {recommendError && (
                  <div role="alert" className="error">
                    {recommendError}
                    <button onClick={() => void recommend()}>Retry</button>
                  </div>
                )}
                {recommendBusy && <p role="status">Finding time for your tasks...</p>}
                {!availability.pending && !availability.error && !availabilityCovers(availability, selectedDate) && <p role="alert">This date is outside imported calendar coverage. Clear the import explicitly to plan without external busy times.</p>}
                {recommendations?.days
                  .filter((d) => d.date === selectedDate)
                  .map((d) => (
                    <div className="stack compact" key={d.date}>
                      <p className="muted">{d.available_minutes} available minutes</p>
                      {d.items.length === 0 && <p className="empty">No recommendations for this day.</p>}
                      {d.items.map((item, i) => (
                        <article className="recommendation" key={`${item.task_id}-${i}`}>
                          <div className="grow">
                            <h3>{item.part_title || item.task_title}</h3>
                            {item.part_title && <p className="muted">{item.task_title}</p>}
                            <p className="muted">
                              {item.minutes} min
                              {item.start_at ? ` · ${timeLabel(item.start_at)}` : ""}
                            </p>
                            {item.reason && <p>{item.reason}</p>}
                          </div>
                          <button
                            className="icon-button"
                            aria-label={`Focus on ${item.task_title}`}
                            disabled={!!run || !timerReady}
                            onClick={() => startFocus(item.task_id)}
                          >
                            <Play />
                          </button>
                        </article>
                      ))}
                    </div>
                  ))}
                {recommendations && !recommendations.days.some((d) => d.date === selectedDate) && (
                  <p className="empty">No recommendations returned for this date.</p>
                )}
                {!!recommendations?.unscheduled.length && (
                  <details>
                    <summary>Could not fit ({recommendations.unscheduled.length})</summary>
                    {recommendations.unscheduled.map((item, i) => (
                      <p key={i}>
                        {item.task_title} · {item.minutes} min
                      </p>
                    ))}
                  </details>
                )}
              </section>
            </div>
          </div>
        )}
        {tab === "Tasks" && (
          <div className="stack">
            <form
              className="card row quick-add"
              onSubmit={(event) => {
                event.preventDefault();
                if (!quickAdd.trim()) return;
                void act(async () => {
                  await api(
                    "/tasks/parse",
                    request("POST", {
                      text: quickAdd.trim(),
                      timezone: timezone(),
                    }),
                  );
                  setQuickAdd("");
                });
              }}
            >
              <label className="grow">
                Quick add
                <input
                  required
                  maxLength={2000}
                  value={quickAdd}
                  onChange={(e) => setQuickAdd(e.target.value)}
                  placeholder="e.g. Submit report tomorrow at 3pm, 45 minutes"
                />
              </label>
              <button className="primary" disabled={busy || !quickAdd.trim()}>
                <Plus />
                {busy ? "Adding..." : "Add task"}
              </button>
            </form>
            <div className="task-toolbar">
              <label className="grow">
                <span className="sr-only">Search tasks</span>
                <input type="search" value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Search tasks, categories, notes" />
              </label>
              <label>
                <span className="sr-only">Task filter</span>
                <select value={filter} onChange={(e) => setFilter(e.target.value)}>
                  <option value="active">Active</option>
                  <option value="all">All tasks</option>
                  <option value="completed">Completed</option>
                  <option value="archived">Archived</option>
                </select>
              </label>
              <label>
                <span className="sr-only">Sort tasks</span>
                <select value={sort} onChange={(e) => setSort(e.target.value)}>
                  <option value="created_at">Created date</option>
                  <option value="deadline">Deadline</option>
                  <option value="priority">Priority</option>
                  <option value="updated_at">Last updated</option>
                  <option value="category">Category</option>
                </select>
              </label>
              <label>
                <span className="sr-only">Sort direction</span>
                <select value={order} onChange={(e) => setOrder(e.target.value)}>
                  <option value="asc">Ascending</option>
                  <option value="desc">Descending</option>
                </select>
              </label>
            </div>
            <section className="card task-list" aria-label="Task list">
              {!displayedTasks.length && !loading && !loadError && (
                <div className="empty">
                  <h2>{search ? "No matching tasks" : "Nothing here yet"}</h2>
                  <p>{search ? "Try another search." : "Create a task to get started, or change the filter."}</p>
                </div>
              )}
              {displayedTasks.map((task) => (
                <article className="task-row" key={task.id}>
                  <button
                    className={`completion-button ${taskDone(task) ? "checked" : ""}`}
                    aria-label={`${taskDone(task) ? "Reopen" : "Complete"} ${task.title}${task.repeat_weekdays?.length ? " for today" : ""}`}
                    disabled={busy || task.is_archived}
                    onClick={() => toggleTask(task)}
                  >
                    <CircleCheck />
                  </button>
                  <div className="grow">
                    <button className={`task-title ${taskDone(task) ? "done" : ""}`} onClick={() => openTask(task)}>
                      {task.title}
                    </button>
                    <div className="task-meta">
                      <span className={`priority ${task.priority}`}>{task.priority}</span>
                      <span>{task.status.replace("_", " ")}</span>
                      {task.category && <span>{task.category}</span>}
                      {task.estimated_duration != null && (
                        <span>
                          {task.actual_duration || 0}/{task.estimated_duration} min
                        </span>
                      )}
                      {task.estimated_duration != null && (
                        <span>{task.progress_percent ?? Math.min(100, Math.round(((task.actual_duration || 0) / task.estimated_duration) * 100))}% done</span>
                      )}
                      {task.deadline && (
                        <span className={new Date(task.deadline) < new Date() && !taskDone(task) ? "danger" : ""}>
                          Due {new Date(task.deadline).toLocaleDateString()}
                        </span>
                      )}
                      {!!task.repeat_weekdays?.length && <span>Repeats · completion is for today</span>}
                      {!!task.checklist?.length && (
                        <span>
                          {task.checklist.filter((c) => c.done).length}/{task.checklist.length} checklist
                        </span>
                      )}
                    </div>
                  </div>
                  <div className="task-actions">
                    {!task.is_archived && task.status === "pending" && (
                      <button
                        disabled={busy}
                        aria-label={`Start task ${task.title}`}
                        onClick={() =>
                          void act(async () => {
                            await api(`/tasks/${task.id}/start`, request("POST"));
                          })
                        }
                      >
                        Start
                      </button>
                    )}
                    {!task.is_archived && task.status !== "completed" && (
                      <button
                        disabled={busy}
                        aria-label={`Reschedule ${task.title}`}
                        onClick={() => {
                          setError("");
                          setEditing(task);
                          setSheet("reschedule");
                        }}
                      >
                        Reschedule
                      </button>
                    )}
                    <button className="icon-button" aria-label={`Edit ${task.title}`} onClick={() => openTask(task)}>
                      <Pencil />
                    </button>
                    {!task.is_archived && (
                      <button
                        className="icon-button"
                        disabled={!!run || !timerReady || task.status === "completed"}
                        aria-label={`Focus on ${task.title}`}
                        onClick={() => startFocus(task.id)}
                      >
                        <Play />
                      </button>
                    )}
                    <button
                      className="icon-button"
                      disabled={busy}
                      aria-label={`${task.is_archived ? "Restore" : "Archive"} ${task.title}`}
                      onClick={() =>
                        void act(async () => {
                          await api(`/tasks/${task.id}/${task.is_archived ? "restore" : "archive"}`, request("POST"));
                        })
                      }
                    >
                      {task.is_archived ? <RotateCcw /> : <Archive />}
                    </button>
                    <button
                      className="icon-button danger"
                      disabled={busy}
                      aria-label={`Delete ${task.title}`}
                      onClick={() => {
                        if (window.confirm(`Permanently delete "${task.title}"?`))
                          void act(async () => {
                            await api(`/tasks/${task.id}`, request("DELETE"));
                          });
                      }}
                    >
                      <Trash2 />
                    </button>
                  </div>
                </article>
              ))}
            </section>
          </div>
        )}
        {tab === "Habits" && (
          <div className="stack">
            <section className="card">
              <div className="section-heading">
                <h2>This week</h2>
                <strong>{scheduled ? Math.round((completed / scheduled) * 100) : 0}%</strong>
              </div>
              <progress aria-label="Weekly habit completion" value={completed} max={Math.max(1, scheduled)} />
              <p className="muted">
                {completed} of {scheduled} scheduled completions done
              </p>
            </section>
            {!habits.length && !loading && !loadError && (
              <section className="card empty">
                <h2>Build a little momentum</h2>
                <p>Create a habit, then log your daily progress.</p>
              </section>
            )}
            <div className="habit-grid">
              {habits.map((stats, index) => {
                const h = stats.habit;
                const count = stats.last_7_days.find((d) => d.date === today)?.completed_count || 0;
                const due = !h.repeat_weekdays?.length || h.repeat_weekdays.includes(new Date().getDay());
                return (
                  <article className="card stack" key={h.id}>
                    <div className="section-heading">
                      <div>
                        <h2>{h.title}</h2>
                        <p className="muted">
                          {h.repeat_weekdays?.length ? h.repeat_weekdays.map((d) => weekdays[d]).join(", ") : "Every day"} · goal {h.daily_goal}/day
                        </p>
                      </div>
                      <span className="badge">{stats.current_streak} day streak</span>
                    </div>
                    <div className="habit-bars" aria-label="Last seven days">
                      {stats.last_7_days.map((d) => (
                        <div key={d.date} title={`${d.date}: ${d.completed_count}/${h.daily_goal}${d.scheduled ? "" : " (not scheduled)"}`}>
                          <div className="bar-track">
                            <div
                              className={d.completed_count >= h.daily_goal ? "bar complete" : "bar"}
                              style={{
                                height: `${Math.min(100, (d.completed_count / h.daily_goal) * 100)}%`,
                              }}
                            />
                          </div>
                          <span>{weekdays[new Date(`${d.date}T12:00:00`).getDay()].slice(0, 1)}</span>
                          <span className="sr-only">
                            {d.date}: {d.completed_count} completions
                          </span>
                        </div>
                      ))}
                    </div>
                    <div className="row spread">
                      <span className="muted">
                        30-day rate: {Math.round(stats.completion_rate_30d * 100)}%<br />
                        Best streak: {stats.best_streak} days
                      </span>
                      <span className="badge">{stats.completion_rate_30d >= 0.75 ? "On track" : "Needs work"}</span>
                    </div>
                    <div className="row">
                      <button
                        disabled={busy}
                        aria-label={`Edit habit ${h.title}`}
                        onClick={() => {
                          setError("");
                          setEditingHabit(h);
                          setSheet("habit");
                        }}
                      >
                        Edit
                      </button>
                      {[-1, 1].map((direction) => (
                        <button
                          key={direction}
                          disabled={busy || index + direction < 0 || index + direction >= habits.length}
                          aria-label={`Move ${h.title} ${direction < 0 ? "up" : "down"}`}
                          onClick={() =>
                            void act(async () => {
                              const ids = habits.map((item) => item.habit.id);
                              [ids[index], ids[index + direction]] = [ids[index + direction], ids[index]];
                              await api("/habits/reorder", request("POST", { habit_ids: ids }));
                            })
                          }
                        >
                          {direction < 0 ? "Move up" : "Move down"}
                        </button>
                      ))}
                      <button
                        disabled={busy}
                        aria-label={`Complete habit ${h.title} today`}
                        onClick={() =>
                          void act(async () => {
                            await api(
                              `/habits/${h.id}/logs/day?timezone=${encodeURIComponent(timezone())}`,
                              request("PUT", { date: today, count: h.daily_goal }),
                            );
                          })
                        }
                      >
                        Complete today
                      </button>
                      <button
                        disabled={busy || count === 0}
                        aria-label={`Reset habit ${h.title} today`}
                        onClick={() => {
                          if (window.confirm(`Reset today's count for ${h.title}?`))
                            void act(async () => {
                              await api(`/habits/${h.id}/logs/day?timezone=${encodeURIComponent(timezone())}`, request("PUT", { date: today, count: 0 }));
                            });
                        }}
                      >
                        Reset today
                      </button>
                    </div>
                    <form
                      className="row"
                      onSubmit={(event) => {
                        event.preventDefault();
                        const data = new FormData(event.currentTarget);
                        void act(async () => {
                          await api(
                            `/habits/${h.id}/logs/day?timezone=${encodeURIComponent(timezone())}`,
                            request("PUT", {
                              count: Number(data.get("count")),
                              date: today,
                            }),
                          );
                        });
                      }}
                    >
                      <label className="grow">
                        Today{!due && " (not scheduled)"}
                        <input key={count} type="number" name="count" min={0} max={1000} required defaultValue={count} />
                      </label>
                      <button disabled={busy}>Set count</button>
                      <button
                        type="button"
                        className="icon-button danger"
                        disabled={busy}
                        aria-label={`Delete habit ${h.title}`}
                        onClick={() => {
                          if (window.confirm(`Delete habit "${h.title}" and its history?`))
                            void act(async () => {
                              await api(`/habits/${h.id}`, request("DELETE"));
                            });
                        }}
                      >
                        <Trash2 />
                      </button>
                    </form>
                  </article>
                );
              })}
            </div>
          </div>
        )}
        {tab === "Focus" && (
          <div className="focus-layout">
            <section className="card timer-card">
              <p className="eyebrow">
                {run?.ended !== undefined
                  ? run.operationId
                    ? "Session ready to retry"
                    : "Session needs review"
                  : run
                    ? "One thing at a time"
                    : "Make room for deep work"}
              </p>
              <h2>{run ? tasks.find((t) => t.id === run.taskId)?.title || "Focus session" : "Your focus starts here"}</h2>
              <div className="timer-display" role="timer" aria-label={`Elapsed time ${timerText}`}>
                {timerText}
              </div>
              {timerIssue && (
                <p className="error" role="alert">
                  {timerIssue}
                </p>
              )}
              {!run ? (
                <div className="stack">
                  <label>
                    Task
                    <select value={focusTask} onChange={(e) => setFocusTask(e.target.value)}>
                      <option value="">Free focus (no task)</option>
                      {tasks
                        .filter((t) => t.status !== "completed")
                        .map((t) => (
                          <option key={t.id} value={t.id}>
                            {t.title}
                          </option>
                        ))}
                    </select>
                  </label>
                  <label>
                    Category
                    <input
                      maxLength={100}
                      list="planner-categories"
                      value={focusCategory}
                      onChange={(e) => setFocusCategory(e.target.value)}
                      placeholder="Optional"
                    />
                  </label>
                  <button className="primary" disabled={!timerReady || busy} onClick={() => startFocus()}>
                    <Play />
                    Start focus session
                  </button>
                </div>
              ) : (
                <div className="stack">
                  <p className="muted">
                    Started {new Date(run.started).toLocaleString()}
                    {run.category ? ` · ${run.category}` : ""}
                  </p>
                  <button
                    className="primary"
                    disabled={busy || !timerReady || (!run.operationId && (run.ended !== undefined || !!run.uncertain || !!run.sessionId))}
                    onClick={() => void saveFocus()}
                  >
                    <Square />
                    {busy
                      ? "Working..."
                      : run.ended !== undefined
                        ? run.operationId
                          ? "Retry save"
                          : "Saving disabled: review required"
                        : "Stop & log session"}
                  </button>
                  {run.sessionId && (
                    <p className="muted">
                      Confirmed saved session: {run.sessionId}.{" "}
                      {run.operationId ? "Task time was recorded atomically with this session." : "Legacy task time may or may not have been updated."}
                    </p>
                  )}
                  {run.ended !== undefined && (
                    <div className="stack compact">
                      <p className="muted" role="status">
                        {run.operationId
                          ? "This stopped session can be retried explicitly using the same session ID and timestamps. The server saves history and task time together without duplicate increments."
                          : "This legacy save has no operation ID. Check session history and task time before discarding pending state. Retrying is disabled because its outcome cannot be recovered safely."}
                      </p>
                      <button disabled={busy} onClick={refresh}>
                        <RefreshCw />
                        Check session history
                      </button>
                      {run.taskId && (
                        <button
                          disabled={busy}
                          onClick={() => {
                            setTab("Tasks");
                            setFilter("all");
                            setSearch(tasks.find((t) => t.id === run.taskId)?.title || "");
                            refresh();
                          }}
                        >
                          Check task time
                        </button>
                      )}
                    </div>
                  )}
                  <button className="text-button danger" disabled={busy || !timerReady} onClick={discardFocus}>
                    {run.ended !== undefined ? "Discard pending state (no writes)" : "Discard session"}
                  </button>
                </div>
              )}
              <p className="muted small">
                With browser storage available, the timer resumes across reloads and synchronizes between tabs. Sessions retain seconds; task time includes only
                whole minutes. Sessions shorter than 60 seconds do not add task time.
              </p>
            </section>
            <div className="stack">
              <section className="card">
                <div className="section-heading">
                  <h2>Focus summary</h2>
                  <label>
                    <span className="sr-only">Summary period</span>
                    <select value={range} onChange={(e) => setRange(Number(e.target.value))}>
                      {[1, 3, 7, 14, 28].map((d) => (
                        <option value={d} key={d}>
                          {d === 1 ? "Today" : `Last ${d} days`}
                        </option>
                      ))}
                    </select>
                  </label>
                </div>
                <label>
                  Focus category
                  <select value={focusFilter} onChange={(e) => setFocusFilter(e.target.value)}>
                    <option value="all">All categories</option>
                    {focusCategories.map((c) => (
                      <option key={c} value={c}>
                        {c}
                      </option>
                    ))}
                  </select>
                </label>
                {summary && (
                  <>
                    <div className="stat-grid">
                      <div>
                        <strong>
                          {Math.round(
                            (focusFilter === "all" ? summary.total_duration_seconds : filteredSessions.reduce((total, s) => total + s.duration_seconds, 0)) /
                              60,
                          )}
                        </strong>
                        <span>focused minutes</span>
                      </div>
                      <div>
                        <strong>{focusFilter === "all" ? summary.session_count : filteredSessions.length}</strong>
                        <span>sessions</span>
                      </div>
                    </div>
                  </>
                )}
                <div className="stack compact">
                  <h3>Daily focus</h3>
                  {dailyFocus.map(([day, seconds]) => (
                    <div className="row spread" key={day}>
                      <span>{day}</span>
                      <span>{Math.round(seconds / 60)} min</span>
                      <meter
                        aria-label={`Focus minutes on ${day}`}
                        min={0}
                        max={Math.max(60, ...dailyFocus.map(([, value]) => value / 60))}
                        value={seconds / 60}
                      />
                    </div>
                  ))}
                  <h3>By category</h3>
                  {focusCategories
                    .filter((c) => focusFilter === "all" || c === focusFilter)
                    .map((c) => (
                      <p key={c}>
                        {c}: {Math.round(sessions.filter((s) => sessionCategory(s) === c).reduce((sum, s) => sum + s.duration_seconds, 0) / 60)} min
                      </p>
                    ))}
                </div>
              </section>
              <section className="card">
                <h2>Recent sessions</h2>
                {!filteredSessions.length && !loading && !loadError && <p className="empty">Your saved sessions will appear here.</p>}
                {[...filteredSessions]
                  .sort((a, b) => b.started_at.localeCompare(a.started_at))
                  .map((s) => (
                    <article className="session-row" key={s.id}>
                      <div className="grow">
                        <h3>{tasks.find((t) => t.id === s.task_id)?.title || s.category || "Free focus"}</h3>
                        <p className="muted">
                          {new Date(s.started_at).toLocaleDateString()} · {timeLabel(s.started_at)} - {timeLabel(s.ended_at)}
                        </p>
                      </div>
                      <strong>{Math.round(s.duration_seconds / 60)} min</strong>
                      <button
                        disabled={busy}
                        aria-label={`Edit focus session ${s.id}`}
                        onClick={() => {
                          setEditingSession(s);
                          setError("");
                          setSheet("session");
                        }}
                      >
                        <Pencil />
                      </button>
                      <button
                        disabled={busy}
                        aria-label={`Delete focus session ${s.id}`}
                        className="danger"
                        onClick={() => {
                          if (window.confirm("Delete this focus session? Task actual minutes will not change. Adjust the task separately if needed."))
                            void act(async () => {
                              await api(`/focus/sessions/${s.id}`, request("DELETE"));
                            });
                        }}
                      >
                        <Trash2 />
                      </button>
                    </article>
                  ))}
              </section>
              <p className="muted small">
                Editing or deleting sessions changes focus history only, not task actual minutes. Use Edit task to explicitly replace its tracked total.
              </p>
              <button onClick={() => setSheet("assistant")}>
                <MessageCircle />
                Talk to your assistant
              </button>
            </div>
          </div>
        )}
      </main>
      {sheet === "task" && (
        <Sheet title={editing ? "Edit task" : "New task"} onClose={closeSheet}>
          {error && (
            <p role="alert" className="error">
              {error}
            </p>
          )}
          <TaskForm
            task={editing}
            busy={busy}
            onSave={(body) =>
              void act(async () => {
                const status = body.status;
                const transition =
                  status !== editing?.status && (status === "in_progress" || (status === "completed" && !(body.repeat_weekdays as number[] | null)?.length));
                const saved = await api<Task>(
                  editing ? `/tasks/${editing.id}` : "/tasks",
                  request(editing ? "PATCH" : "POST", {
                    ...body,
                    status: transition ? (editing?.status === "completed" ? "pending" : editing?.status || "pending") : status,
                  }),
                );
                setEditing(saved);
                if (transition) {
                  try {
                    await api(`/tasks/${saved.id}/${status === "in_progress" ? "start" : "complete"}`, request("POST", { timezone: timezone() }));
                  } catch (e) {
                    throw new Error(`Task details were saved, but the status change could not be confirmed. ${errorText(e)} Check the task before retrying.`);
                  }
                }
              }, true)
            }
          />
        </Sheet>
      )}
      {sheet === "habit" && (
        <Sheet title={editingHabit ? "Edit habit" : "New habit"} onClose={closeSheet}>
          {error && (
            <p role="alert" className="error">
              {error}
            </p>
          )}
          <HabitForm
            habit={editingHabit}
            busy={busy}
            onSave={(body) =>
              void act(async () => {
                await api(editingHabit ? `/habits/${editingHabit.id}` : "/habits", request(editingHabit ? "PATCH" : "POST", body));
              }, true)
            }
          />
        </Sheet>
      )}
      {sheet === "block" && (
        <Sheet title={editingBlock ? "Edit schedule block" : "Schedule a task"} onClose={closeSheet}>
          {error && (
            <p role="alert" className="error">
              {error}
            </p>
          )}
          <form
            className="stack"
            onSubmit={(event) => {
              event.preventDefault();
              const data = new FormData(event.currentTarget);
              const start = new Date(String(data.get("start")));
              const end = new Date(String(data.get("end")));
              if (end <= start) {
                setError("End time must be after start time.");
                return;
              }
              const task = tasks.find((t) => t.id === data.get("task"));
              void act(async () => {
                await api(
                  editingBlock ? `/calendar/blocks/${editingBlock.id}` : "/calendar/blocks",
                  request(editingBlock ? "PATCH" : "POST", {
                    ...(editingBlock ? {} : { task_id: task?.id }),
                    title: String(data.get("title") || editingBlock?.title || task?.title).trim(),
                    start_at: String(data.get("start")) === localInput(editingBlock?.start_at || null) ? editingBlock!.start_at : start.toISOString(),
                    end_at: String(data.get("end")) === localInput(editingBlock?.end_at || null) ? editingBlock!.end_at : end.toISOString(),
                  }),
                );
              }, true);
            }}
          >
            {!editingBlock && (
              <label>
                Task
                <select autoFocus required name="task" defaultValue="">
                  <option value="" disabled>
                    Choose a task
                  </option>
                  {tasks
                    .filter((t) => t.status !== "completed")
                    .map((t) => (
                      <option value={t.id} key={t.id}>
                        {t.title}
                      </option>
                    ))}
                </select>
              </label>
            )}
            {!editingBlock && !tasks.some((t) => t.status !== "completed") && <p className="muted">Create an active task in the Tasks tab first.</p>}
            <label>
              Block title
              <input name="title" defaultValue={editingBlock?.title} maxLength={255} placeholder="Defaults to task title" />
            </label>
            <label>
              Start
              <input type="datetime-local" name="start" required defaultValue={editingBlock ? localInput(editingBlock.start_at) : `${selectedDate}T09:00`} />
            </label>
            <label>
              End
              <input type="datetime-local" name="end" required defaultValue={editingBlock ? localInput(editingBlock.end_at) : `${selectedDate}T10:00`} />
            </label>
            <button className="primary" disabled={busy || (!editingBlock && !tasks.some((t) => t.status !== "completed"))}>
              {busy ? "Saving..." : editingBlock ? "Save block" : "Add to schedule"}
            </button>
          </form>
        </Sheet>
      )}
      {sheet === "occurrence" && occurrence && (
        <Sheet title="Edit repeating occurrence" onClose={closeSheet}>
          {error && (
            <p className="error" role="alert">
              {error}
            </p>
          )}
          <form
            className="stack"
            onSubmit={(event) => {
              event.preventDefault();
              const data = new FormData(event.currentTarget);
              const start = new Date(String(data.get("start")));
              const end = new Date(String(data.get("end")));
              if (end <= start) {
                setError("End time must be after start time.");
                return;
              }
              void act(async () => {
                await api(
                  `/tasks/${occurrence.task.id}/occurrence`,
                  request("PATCH", {
                    date: occurrence.date,
                    scope: data.get("scope"),
                    start_at: String(data.get("start")) === localInput(occurrence.start) ? occurrence.start : start.toISOString(),
                    end_at: String(data.get("end")) === localInput(occurrence.end) ? occurrence.end : end.toISOString(),
                    timezone: timezone(),
                  }),
                );
              }, true);
            }}
          >
            <p>
              {occurrence.task.title} on {occurrence.date}
            </p>
            <label>
              Apply to
              <select name="scope">
                <option value="this_event_only">This occurrence only</option>
                <option value="from_now_onwards">This and future occurrences</option>
              </select>
            </label>
            <label>
              Start
              <input required type="datetime-local" name="start" defaultValue={localInput(occurrence.start)} />
            </label>
            <label>
              End
              <input required type="datetime-local" name="end" defaultValue={localInput(occurrence.end)} />
            </label>
            <button disabled={busy} className="primary">
              Save occurrence
            </button>
          </form>
        </Sheet>
      )}
      {sheet === "reschedule" && editing && (
        <Sheet title="Reschedule task" onClose={closeSheet}>
          {error && (
            <p className="error" role="alert">
              {error}
            </p>
          )}
          <p className="muted">Update remaining work and ask the server to replan, or postpone upcoming work. Repeating tasks should use occurrence editing.</p>
          {editing.repeat_weekdays?.length ? (
            <p>Use Schedule to edit an occurrence, or Edit task to change the series.</p>
          ) : (
            <div className="stack">
              <form
                className="stack"
                onSubmit={(event) => {
                  event.preventDefault();
                  const data = new FormData(event.currentTarget);
                  const deadline = String(data.get("deadline") || "");
                  void act(async () => {
                    await api(
                      `/tasks/${editing.id}/reschedule`,
                      request("POST", {
                        minutes_remaining: Number(data.get("minutes")),
                        reason: data.get("reason") || null,
                        timezone: timezone(),
                        ...(deadline ? { deadline: new Date(deadline).toISOString() } : {}),
                      }),
                    );
                  }, true);
                }}
              >
                <label>
                  Remaining minutes
                  <input
                    required
                    name="minutes"
                    type="number"
                    min={1}
                    max={525600}
                    defaultValue={Math.max(1, (editing.estimated_duration || 30) - (editing.actual_duration || 0))}
                  />
                </label>
                <label>
                  Reason
                  <textarea name="reason" maxLength={2000} />
                </label>
                <label>
                  New deadline
                  <input name="deadline" type="datetime-local" defaultValue={localInput(editing.deadline)} />
                </label>
                <button disabled={busy} className="primary">
                  Replan remaining work
                </button>
              </form>
              <form
                className="stack"
                onSubmit={(event) => {
                  event.preventDefault();
                  const data = new FormData(event.currentTarget);
                  void act(async () => {
                    await api(`/tasks/${editing.id}/snooze`, request("POST", { minutes: Number(data.get("minutes")), timezone: timezone() }));
                  }, true);
                }}
              >
                <label>
                  Snooze minutes
                  <input name="minutes" required type="number" min={1} max={1440} defaultValue={15} />
                </label>
                <button disabled={busy}>Snooze task</button>
              </form>
            </div>
          )}
        </Sheet>
      )}
      {sheet === "session" && editingSession && (
        <Sheet title="Edit focus session" onClose={closeSheet}>
          {error && (
            <p className="error" role="alert">
              {error}
            </p>
          )}
          <form
            className="stack"
            onSubmit={(event) => {
              event.preventDefault();
              const data = new FormData(event.currentTarget);
              const start = String(data.get("start"));
              const end = String(data.get("end"));
              const startedAt = start === localInput(editingSession.started_at) ? editingSession.started_at : new Date(start).toISOString();
              const endedAt = end === localInput(editingSession.ended_at) ? editingSession.ended_at : new Date(end).toISOString();
              if (new Date(endedAt) <= new Date(startedAt)) {
                setError("End time must be after start time.");
                return;
              }
              void act(async () => {
                await api(`/focus/sessions/${editingSession.id}`, request("PATCH", { started_at: startedAt, ended_at: endedAt }));
              }, true);
            }}
          >
            <label>
              Started
              <input required type="datetime-local" name="start" defaultValue={localInput(editingSession.started_at)} />
            </label>
            <label>
              Ended
              <input required type="datetime-local" name="end" defaultValue={localInput(editingSession.ended_at)} />
            </label>
            <p className="muted">Duration is recalculated from these times. Task actual minutes are unchanged; adjust the task separately if needed.</p>
            <button disabled={busy} className="primary">
              Save session
            </button>
          </form>
        </Sheet>
      )}
      {sheet === "settings" && (
        <Sheet title="Settings" onClose={closeSheet}>
          <div className="stack">
            {error && (
              <p className="error" role="alert">
                {error}
              </p>
            )}
            <section className="settings-account">
              <h3>{user.name || "Your account"}</h3>
              <p className="muted">{user.email}</p>
            </section>
            <label>
              Appearance
              <select value={theme} onChange={(e) => setTheme(e.target.value)}>
                <option value="system">System</option>
                <option value="light">Light</option>
                <option value="dark">Dark</option>
              </select>
            </label>
            <div>
              <h3>Time zone</h3>
              <p className="muted">{timezone()} · Uses your device time zone.</p>
            </div>
            <SchedulingPreferences
              onSaved={() => {
                setRecommendations(null);
                refresh();
              }}
            />
            <NotificationPreferences />
            <section className="stack">
              <h3>Category suggestions</h3>
              <p className="muted">
                Suggestions are saved in this browser for your account. Removing a suggestion keeps existing task and session labels unchanged.
              </p>
              {categoryIssue && (
                <p className="error" role="alert">
                  {categoryIssue}
                </p>
              )}
              {!localCategories && <button onClick={() => setCategoryReload((v) => v + 1)}>Reload category suggestions</button>}
              {categories.map((category) => (
                <div className="row" key={category}>
                  <p className="grow">{category}</p>
                  <button
                    disabled={!localCategories}
                    aria-label={`Remove category suggestion ${category}`}
                    onClick={() => {
                      if (window.confirm(`Remove "${category}" from suggestions? Existing labels will stay unchanged.`)) changeCategory(category, true);
                    }}
                  >
                    Remove
                  </button>
                </div>
              ))}
              {!categories.length && <p className="muted">No categories yet.</p>}
              <form
                className="stack compact"
                onSubmit={(event) => {
                  event.preventDefault();
                  changeCategory(newCategory);
                }}
              >
                <label>
                  New category
                  <input required maxLength={100} value={newCategory} onChange={(event) => setNewCategory(event.target.value)} />
                </label>
                <button disabled={!localCategories || !newCategory.trim()}>Add category suggestion</button>
              </form>
            </section>
            <section>
              <h3>AI privacy</h3>
              <p className="muted">
                Task details and planner context may be sent to configured AI providers for scheduling, natural-language task parsing, daily advice, and
                assistant conversations. Do not enter sensitive information you do not want processed by these services.
              </p>
            </section>
            <p className="muted">
              Authentication is managed by the app. Planner data is saved to your account. Focus timers use browser storage when available; durability cannot be
              guaranteed if storage fails.
            </p>
            <button
              className="danger"
              disabled={busy}
              onClick={() =>
                void act(async () => {
                  if (run && !window.confirm("A focus session exists. Check any pending save against history and task time before leaving. Sign out?")) return;
                  await onLogout();
                })
              }
            >
              {busy ? "Signing out..." : "Sign out"}
            </button>
          </div>
        </Sheet>
      )}
      {sheet === "assistant" && <Assistant userId={user.id} onClose={() => setSheet(null)}
        onTask={(id) => { void act(async () => { const task = await api<Task>(`/tasks/${id}`); setEditing(task); setSheet("task"); }); }}
        onChanged={() => setReload(v => v + 1)} onStartFocus={(id) => { startFocus(id || ""); setSheet(null); }} />}
    </div>
  );
}
