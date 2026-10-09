"use client";

import Script from "next/script";
import { useEffect, useRef, useState } from "react";

export type BusyInterval = { start: string; end: string };
export type CalendarAvailabilityState = {
  busyTimes: BusyInterval[];
  pending: boolean;
  error: string;
  coverage: { start: string; end: string } | null;
};
export const emptyCalendarAvailability: CalendarAvailabilityState = { busyTimes: [], pending: false, error: "", coverage: null };
export function availabilityCovers(value: CalendarAvailabilityState, day: string) {
  const start = new Date(`${day}T00:00:00`);
  const end = new Date(start);
  end.setDate(end.getDate() + 1);
  return !value.pending && !value.error && (!value.coverage || (start >= new Date(value.coverage.start) && end <= new Date(value.coverage.end)));
}

type GoogleCalendar = { id: string; summary: string };
type GoogleEvent = { status?: string; transparency?: string; start?: { dateTime?: string; date?: string }; end?: { dateTime?: string; date?: string } };
const scopes = ["https://www.googleapis.com/auth/calendar.events.readonly", "https://www.googleapis.com/auth/calendar.calendarlist.readonly"];

export function CalendarAvailability({ value, onChange }: { value: CalendarAvailabilityState; onChange: (value: CalendarAvailabilityState) => void }) {
  const [calendars, setCalendars] = useState<GoogleCalendar[]>([]);
  const [selected, setSelected] = useState<string[]>([]);
  const [ready, setReady] = useState(false);
  const token = useRef<{ access: string; expires: number } | null>(null);
  const sequence = useRef(0);
  const lock = useRef(false);
  const clientId = process.env.NEXT_PUBLIC_GOOGLE_CLIENT_ID;
  useEffect(() => () => { sequence.current++; token.current = null; }, []);

  function fail(message: string) {
    lock.current = false;
    onChange({ ...value, pending: false, error: `${message} Previous busy times are retained. Planning is paused until you reload or clear the import.` });
  }

  async function load(access: string, ids?: string[]) {
    const operation = ++sequence.current;
    lock.current = true;
    onChange({ ...value, pending: true, error: "" });
    try {
      async function pages<T>(path: string, params: Record<string, string>): Promise<T[]> {
        const items: T[] = [];
        const seen = new Set<string>();
        let pageToken = "";
        for (let page = 0; page < 100; page++) {
          const query = new URLSearchParams({ ...params, ...(pageToken ? { pageToken } : {}) });
          const response = await fetch(`https://www.googleapis.com/calendar/v3/${path}?${query}`, {
            headers: { Authorization: `Bearer ${access}` }, cache: "no-store", credentials: "omit",
          });
          if (!response.ok) {
            if (response.status === 401) token.current = null;
            throw new Error(`Google Calendar request failed (${response.status}). Check consent, Calendar API enablement and OAuth configuration; reconnect if access expired.`);
          }
          const data = await response.json() as { items?: T[]; nextPageToken?: string };
          if (!Array.isArray(data.items) && data.items !== undefined) throw new Error("Google returned an invalid calendar response.");
          items.push(...(data.items || []));
          if (!data.nextPageToken) return items;
          if (seen.has(data.nextPageToken)) throw new Error("Google Calendar pagination repeated. Import was not completed.");
          seen.add(data.nextPageToken);
          pageToken = data.nextPageToken;
        }
        throw new Error("Google Calendar import exceeded the safety limit of 100 pages. Select fewer calendars.");
      }
      const listed = await pages<GoogleCalendar>("users/me/calendarList", { maxResults: "250", fields: "items(id,summary),nextPageToken" });
      const chosen = (ids ?? listed.map(c => c.id)).filter(id => listed.some(c => c.id === id));
      if (ids?.some(id => !listed.some(c => c.id === id))) throw new Error("A selected calendar is no longer available. Clear the import and reconnect to select calendars again.");
      const today = new Date();
      today.setHours(0, 0, 0, 0);
      const start = new Date(today);
      start.setDate(start.getDate() - 1);
      const end = new Date(today);
      end.setDate(end.getDate() + 365);
      const coverage = { start: start.toISOString(), end: end.toISOString() };
      const intervals: BusyInterval[] = [];
      for (const id of chosen) {
        const events = await pages<GoogleEvent>(`calendars/${encodeURIComponent(id)}/events`, {
          singleEvents: "true", timeMin: coverage.start, timeMax: coverage.end, maxResults: "2500",
          fields: "items(status,transparency,start,end),nextPageToken",
        });
        for (const event of events) {
          if (event.status === "cancelled" || event.transparency === "transparent" || event.start?.date || event.end?.date) continue;
          if (!event.start?.dateTime || !event.end?.dateTime) throw new Error("Google returned a timed event without valid start/end times.");
          const eventStart = new Date(event.start.dateTime);
          const eventEnd = new Date(event.end.dateTime);
          if (!Number.isFinite(+eventStart) || !Number.isFinite(+eventEnd) || eventEnd <= eventStart) throw new Error("Google returned invalid event times.");
          if (eventStart < end && eventEnd > start) intervals.push({ start: new Date(Math.max(+eventStart, +start)).toISOString(), end: new Date(Math.min(+eventEnd, +end)).toISOString() });
        }
      }
      if (operation !== sequence.current) return;
      intervals.sort((a, b) => a.start.localeCompare(b.start) || a.end.localeCompare(b.end));
      setCalendars(listed);
      setSelected(chosen);
      onChange({ busyTimes: intervals, coverage: chosen.length ? coverage : null, pending: false, error: "" });
    } catch (error) {
      if (operation === sequence.current) fail(error instanceof Error ? error.message : "Calendar import failed.");
    } finally {
      if (operation === sequence.current) lock.current = false;
    }
  }

  function connect() {
    if (lock.current) return;
    if (!clientId || !window.google?.accounts.oauth2) { fail("Google Calendar authorization is unavailable. Check the public client ID and reload."); return; }
    lock.current = true;
    const operation = ++sequence.current;
    onChange({ ...value, pending: true, error: "" });
    try {
      window.google.accounts.oauth2.initTokenClient({
        client_id: clientId, scope: scopes.join(" "),
        callback: response => {
          if (operation !== sequence.current) return;
          if (response.error || !response.access_token || !scopes.every(scope => response.scope?.split(" ").includes(scope))) {
            fail("Google Calendar consent was denied or required read-only scopes were not granted."); return;
          }
          token.current = { access: response.access_token, expires: Date.now() + (response.expires_in || 0) * 1000 };
          void load(response.access_token, calendars.length ? selected : undefined);
        },
        error_callback: error => { if (operation === sequence.current) fail(`Google authorization could not complete (${error.type}). Allow the popup and retry.`); },
      }).requestAccessToken({ prompt: "consent" });
    } catch { fail("Google Calendar authorization could not start. Reload and retry."); }
  }

  function reload(ids = selected) {
    if (lock.current) return;
    if (!token.current || token.current.expires <= Date.now() + 30000) { fail("Google Calendar access has expired. Use Connect Google Calendar to consent again."); return; }
    void load(token.current.access, ids);
  }

  return <section className="card stack" aria-label="External calendar availability" style={{ overflowWrap: "anywhere" }}>
    <Script src="https://accounts.google.com/gsi/client" onReady={() => setReady(true)} onError={() => fail("Google authorization script could not load. Check your connection and reload the page.")} />
    <h2>External calendar availability</h2>
    <p className="muted">Browsers cannot use native EventKit. Import Google Calendar busy times with explicit read-only consent. Only start/end intervals reach the planner, never event names or calendar metadata. Tokens stay in memory; reconnect after a page reload.</p>
    <p className="muted">Import is a snapshot from yesterday through the next 365 days, not live sync. Free, cancelled and all-day events are excluded. Task deadlines beyond coverage are not protected by this import.</p>
    {!clientId && <p role="status">Google Calendar import requires NEXT_PUBLIC_GOOGLE_CLIENT_ID, authorized browser origins and an enabled Google Calendar API.</p>}
    <div className="row">
      <button disabled={!clientId || !ready || value.pending} onClick={connect}>Connect Google Calendar</button>
      {!!calendars.length && <button disabled={value.pending} onClick={() => reload()}>Reload busy times</button>}
      <button disabled={value.pending} onClick={() => { sequence.current++; token.current = null; setCalendars([]); setSelected([]); onChange(emptyCalendarAvailability); }}>Clear calendar import</button>
    </div>
    {!!calendars.length && <fieldset disabled={value.pending} className="stack compact"><legend>Calendars to include</legend>
      {calendars.map(calendar => <label key={calendar.id}><input type="checkbox" checked={selected.includes(calendar.id)} onChange={event => {
        const ids = event.target.checked ? [...selected, calendar.id] : selected.filter(id => id !== calendar.id);
        setSelected(ids);
        if (!ids.length) { onChange(emptyCalendarAvailability); }
        else reload(ids);
      }} /> {calendar.summary}</label>)}
    </fieldset>}
    {value.pending && <p role="status">Importing calendar availability...</p>}
    {value.coverage && <p role="status">{value.busyTimes.length} busy intervals. Coverage: {new Date(value.coverage.start).toLocaleDateString()} to {new Date(value.coverage.end).toLocaleDateString()} (exclusive). Reload to update.</p>}
    {value.error && <p className="error" role="alert">{value.error}</p>}
  </section>;
}
