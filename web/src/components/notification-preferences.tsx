"use client";

import { useEffect, useRef, useState } from "react";
import { api } from "@/lib/api";

type Preferences = {
  morning_briefing_enabled: boolean;
  morning_briefing_time: string;
  deadline_reminder_enabled: boolean;
  deadline_reminder_lead_hours: number;
  overdue_alerts_enabled: boolean;
  fifteen_minute_reminder_enabled: boolean;
  fifteen_minute_reminder_lead_minutes: number;
  reschedule_alerts_enabled: boolean;
};
const toggles = {
  morning_briefing_enabled: "Morning briefing",
  deadline_reminder_enabled: "Deadline reminders",
  overdue_alerts_enabled: "Overdue alerts",
  fifteen_minute_reminder_enabled: "Upcoming task reminders",
  reschedule_alerts_enabled: "Reschedule alerts",
} as const;

export function NotificationPreferences() {
  const [value, setValue] = useState<Preferences | null>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [saved, setSaved] = useState(false);
  const [retry, setRetry] = useState(0);
  const lock = useRef(false);
  useEffect(() => {
    let active = true;
    api<Preferences>("/notifications/preferences")
      .then((p) => {
        if (active) setValue(p);
      })
      .catch((e) => {
        if (active) setError(e instanceof Error ? e.message : "Unable to load notification preferences.");
      });
    return () => {
      active = false;
    };
  }, [retry]);
  return (
    <section className="stack">
      <h3>Notification preferences</h3>
      <p className="muted small">
        These account preferences apply to supported registered devices. This web app does not register for browser push notifications.
      </p>
      {error && (
        <p className="error" role="alert">
          {error}
        </p>
      )}
      {!value ? (
        <button onClick={() => setRetry((v) => v + 1)}>Reload notification preferences</button>
      ) : (
        <form
          className="stack"
          onChange={() => setSaved(false)}
          onSubmit={async (event) => {
            event.preventDefault();
            if (lock.current) return;
            lock.current = true;
            setBusy(true);
            setError("");
            setSaved(false);
            try {
              setValue(
                await api<Preferences>("/notifications/preferences", {
                  method: "PATCH",
                  headers: { "Content-Type": "application/json" },
                  body: JSON.stringify(value),
                }),
              );
              setSaved(true);
            } catch (e) {
              setError(e instanceof Error ? e.message : "Unable to save preferences.");
            } finally {
              lock.current = false;
              setBusy(false);
            }
          }}
        >
          <fieldset className="stack" disabled={busy}>
            {(Object.keys(toggles) as (keyof typeof toggles)[]).map((key) => (
              <label className="row" key={key}>
                <input type="checkbox" checked={value[key]} onChange={(e) => setValue({ ...value, [key]: e.target.checked })} />
                {toggles[key]}
              </label>
            ))}
            <label>
              Morning briefing time
              <input
                required
                type="time"
                value={value.morning_briefing_time.slice(0, 5)}
                onChange={(e) => setValue({ ...value, morning_briefing_time: e.target.value })}
              />
            </label>
            <label>
              Deadline lead hours
              <input
                required
                type="number"
                min={1}
                max={168}
                value={value.deadline_reminder_lead_hours}
                onChange={(e) => setValue({ ...value, deadline_reminder_lead_hours: Number(e.target.value) })}
              />
            </label>
            <label>
              Upcoming reminder lead minutes
              <input
                required
                type="number"
                min={1}
                max={120}
                value={value.fifteen_minute_reminder_lead_minutes}
                onChange={(e) => setValue({ ...value, fifteen_minute_reminder_lead_minutes: Number(e.target.value) })}
              />
            </label>
          </fieldset>
          <button className="primary" disabled={busy}>
            {busy ? "Saving..." : "Save notification preferences"}
          </button>
          {saved && <p role="status">Notification preferences saved.</p>}
        </form>
      )}
    </section>
  );
}
