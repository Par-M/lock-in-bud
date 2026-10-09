"use client";

import { useEffect, useRef, useState } from "react";
import { api } from "@/lib/api";
import { type CalendarAvailabilityState } from "@/components/calendar-availability";

type Proposal = {
  id: string;
  status: string;
  reasoning: string | null;
  message?: string;
  failure_reason: string | null;
  retry_at: string | null;
  items: { task_id: string; task_title: string; start: string; end: string; reason: string; accepted: boolean }[];
  meta: { overcommitted: boolean; deferred_tasks: string[]; warnings: string[]; risk?: string | null };
};
const post = (body?: unknown): RequestInit => ({
  method: "POST",
  ...(body === undefined ? {} : { headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) }),
});
const message = (e: unknown) => (e instanceof Error ? e.message : "Request failed. Please try again.");

export function ScheduleProposals({ date, onChanged, availability }: { date: string; onChanged: () => void; availability: CalendarAvailabilityState }) {
  const [proposals, setProposals] = useState<Proposal[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [retry, setRetry] = useState(0);
  const lock = useRef(false);
  const sequence = useRef(0);
  useEffect(() => {
    let active = true;
    const token = ++sequence.current;
    api<{ items: Proposal[] }>("/schedule/recommendations?status=pending")
      .then((result) => {
        if (active && token === sequence.current) setProposals(result.items);
      })
      .catch((e) => {
        if (active && token === sequence.current) setError(message(e));
      });
    return () => {
      active = false;
    };
  }, [retry]);
  async function operate(path: string, body?: unknown) {
    if (lock.current) return;
    lock.current = true;
    sequence.current++;
    setBusy(true);
    setError("");
    try {
      const result = await api<Proposal | { recommendation: Proposal }>(path, post(body));
      const proposal = "recommendation" in result ? result.recommendation : result;
      setProposals((previous) =>
        ["pending", "failed"].includes(proposal.status)
          ? [proposal, ...previous.filter((p) => p.id !== proposal.id)]
          : previous.filter((p) => p.id !== proposal.id),
      );
      onChanged();
    } catch (e) {
      setError(`${message(e)} Your proposal is preserved. Reload pending proposals to check the server outcome before retrying.`);
    } finally {
      lock.current = false;
      setBusy(false);
    }
  }
  return (
    <section className="card stack" aria-label="Schedule proposals">
      <div className="section-heading">
        <h2>Schedule proposals</h2>
        <button
          disabled={busy}
          onClick={() => {
            setError("");
            setRetry((v) => v + 1);
          }}
        >
          Reload pending proposals
        </button>
      </div>
      <p className="muted">
        Review a saved plan before adding it to your calendar. Account events and manual blocks are handled by the server; external busy times use the shared Google Calendar import.
      </p>
      <p className="muted">
        Plans begin today and cover at least the next week, extending to task deadlines. Dates select your calendar view, not the schedule horizon.
      </p>
      <button className="primary" disabled={busy || availability.pending || !!availability.error}
        onClick={() => {
          if (availability.pending || availability.error) return;
          void operate("/schedule/generate", {
            start_date: date,
            end_date: date,
            timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC",
            busy_times: availability.busyTimes,
          });
        }}
      >
          {busy ? "Working..." : "Generate schedule proposal"}
      </button>
      {error && (
        <p className="error" role="alert">
          {error}
        </p>
      )}
      {!proposals.length && <p className="muted">No pending proposals. Generate a plan or reload to resume one.</p>}
      {proposals.map((p) => (
        <article className="stack" key={p.id} aria-label={`Proposal ${p.id}`}>
          {p.message && !p.failure_reason && <p>{p.message}</p>}
          {p.reasoning && <p>{p.reasoning}</p>}
          {p.failure_reason && (
            <p role="status" className="error">
              {p.failure_reason}
              {p.retry_at ? ` Try again after ${new Date(p.retry_at).toLocaleString()}.` : ""}
            </p>
          )}
          {p.meta?.overcommitted && <p role="status">Not all tasks fit in this plan.</p>}
          {p.meta?.risk && <p>{p.meta.risk}</p>}
          {p.meta?.warnings?.map((warning, i) => (
            <p key={i}>{warning}</p>
          ))}
          {!!p.meta?.deferred_tasks?.length && <p>Deferred: {p.meta.deferred_tasks.join(", ")}</p>}
          <p className="proposal-summary">Adds {p.items.filter(i => !i.accepted).length} proposed time blocks. Fixed events keep their times. Review placements below; applying does not complete tasks.</p>
          {p.items.map((item, index) => (
            <div className="recommendation" key={`${item.task_id}-${index}`}>
              <div className="grow">
                <h3>{item.task_title}</h3>
                <p className="muted">
                  {new Date(item.start).toLocaleString()} - {new Date(item.end).toLocaleString()}
                </p>
                <p>{item.reason}</p>
                {item.accepted && <span>Accepted</span>}
              </div>
              <div className="stack compact">
                <button
                  disabled={busy || p.status !== "pending" || item.accepted || !!p.failure_reason}
                  onClick={() => void operate(`/schedule/recommendations/${p.id}/items/${index}/accept`)}
                >
                  Accept {item.task_title}
                </button>
                <button
                  disabled={busy || p.status !== "pending" || item.accepted || !!p.failure_reason}
                  onClick={() => void operate(`/schedule/recommendations/${p.id}/items/${index}/redo`)}
                >
                  Redo {item.task_title}
                </button>
              </div>
            </div>
          ))}
          <div className="row">
            <button
              disabled={busy || p.status !== "pending" || !!p.failure_reason || !p.items.some((i) => !i.accepted)}
              onClick={() => void operate(`/schedule/recommendations/${p.id}/accept`)}
            >
              Accept all
            </button>
            <button disabled={busy || p.status !== "pending"} className="danger" onClick={() => void operate(`/schedule/recommendations/${p.id}/reject`)}>
              Reject proposal
            </button>
          </div>
        </article>
      ))}
    </section>
  );
}
