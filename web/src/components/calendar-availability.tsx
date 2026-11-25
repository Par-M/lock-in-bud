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
            throw new Error(`Couldn’t read Google Calendar (error ${response.status}). Reconnect and try again.`);
          }
          const data = await response.json() as { items?: T[]; nextPageToken?: string };
          if (!Array.isArray(data.items) && data.items !== undefined) throw new Error("Google returned calendar data the app couldn’t read. Try again.");
          items.push(...(data.items || []));
          if (!data.nextPageToken) return items;
          if (seen.has(data.nextPageToken)) throw new Error("Google Calendar returned the same page twice. Try again.");
          seen.add(data.nextPageToken);
          pageToken = data.nextPageToken;
        }
        throw new Error("This calendar has too many events to import. Select fewer calendars.");
      }
      const listed = await pages<GoogleCalendar>("users/me/calendarList", { maxResults: "250", fields: "items(id,summary),nextPageToken" });
      const chosen = (ids ?? listed.map(c => c.id)).filter(id => listed.some(c => c.id === id));
      if (ids?.some(id => !listed.some(c => c.id === id))) throw new Error("A selected calendar is no longer available. Clear the import and choose calendars again.");
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
          if (!Number.isFinite(+eventStart) || !Number.isFinite(+eventEnd) || eventEnd <= eventStart) throw new Error("Google returned an event with invalid times. Try again.");
          if (eventStart < end && eventEnd > start) intervals.push({ start: new Date(Math.max(+eventStart, +start)).toISOString(), end: new Date(Math.min(+eventEnd, +end)).toISOString() });
        }
      }
      if (operation !== sequence.current) return;
      intervals.sort((a, b) => a.start.localeCompare(b.start) || a.end.localeCompare(b.end));
      setCalendars(listed);
      setSelected(chosen);
      onChange({ busyTimes: intervals, coverage: chosen.length ? coverage : null, pending: false, error: "" });
    } catch (error) {
      if (operation === sequence.current) fail(error instanceof Error ? error.message : "Couldn’t import calendar busy times.");
    } finally {
      if (operation === sequence.current) lock.current = false;
    }
  }

  function connect() {
    if (lock.current) return;
    if (!clientId || !window.google?.accounts.oauth2) { fail("Google Calendar isn’t configured for this site. Check the setup and reload."); return; }
    lock.current = true;
    const operation = ++sequence.current;
    onChange({ ...value, pending: true, error: "" });
    try {
      window.google.accounts.oauth2.initTokenClient({
        client_id: clientId, scope: scopes.join(" "),
        callback: response => {
          if (operation !== sequence.current) return;
          if (response.error || !response.access_token || !scopes.every(scope => response.scope?.split(" ").includes(scope))) {
            fail("Google Calendar access wasn’t granted. Try again and allow read-only access."); return;
          }
          token.current = { access: response.access_token, expires: Date.now() + (response.expires_in || 0) * 1000 };
          void load(response.access_token, calendars.length ? selected : undefined);
        },
        error_callback: error => { if (operation === sequence.current) fail(`Google Calendar sign-in didn’t finish (${error.type}). Allow the popup and try again.`); },
      }).requestAccessToken({ prompt: "consent" });
    } catch { fail("Google Calendar sign-in couldn’t start. Reload and try again."); }
  }

  function reload(ids = selected) {
    if (lock.current) return;
    if (!token.current || token.current.expires <= Date.now() + 30000) { fail("Google Calendar access expired. Connect again to refresh busy times."); return; }
    void load(token.current.access, ids);
  }

  return <section className="card stack" aria-label="External calendar availability" style={{ overflowWrap: "anywhere" }}>
    <Script src="https://accounts.google.com/gsi/client" onReady={() => setReady(true)} onError={() => fail("Couldn’t load Google sign-in. Check your connection and reload.")} />
    <h2>Calendar availability</h2>
    <p className="muted">Connect Google Calendar so the planner can avoid your busy times. Only event start and end times are imported — never titles, guests, or notes.</p>
    <details>
      <summary>How the import works</summary>
      <p className="muted">This is a snapshot from yesterday through the next 365 days, not a live sync. Free, cancelled, and all-day events are skipped. Access tokens stay in memory, so reconnect after a reload. Deadlines beyond the imported dates aren’t protected.</p>
    </details>
    {!clientId && <p role="status">Calendar import isn’t configured for this site yet.</p>}
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
    {value.coverage && <p role="status">{value.busyTimes.length} busy intervals. Imported through {new Date(value.coverage.end).toLocaleDateString()}. Reload to update.</p>}
    {value.error && <p className="error" role="alert">{value.error}</p>}
  </section>;
}
