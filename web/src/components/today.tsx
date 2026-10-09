"use client";

import { Circle, Play } from "lucide-react";

type TodayTask = {
  id: string;
  title: string;
  deadline: string | null;
  estimated_duration: number | null;
  repeat_weekdays: number[] | null;
};

type Props = {
  tasks: TodayTask[];
  nextTask?: TodayTask;
  nextEvent?: { title: string; start_at: string; end_at: string };
  focusTitle: string | null;
  busy: boolean;
  loading: boolean;
  timerReady: boolean;
  pending: Set<string>;
  errors: Record<string, string>;
  onAdd: () => void;
  onEdit: (id: string) => void;
  onComplete: (id: string) => void;
  onFocus: (id?: string) => void;
  onSchedule: () => void;
  onTasks: () => void;
};

const time = (value: string) => new Date(value).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });

export function TodayScreen(props: Props) {
  return (
    <div className="stack">
      <section className="card today-hero" aria-label="Your next step">
        <p className="eyebrow">One thing at a time</p>
        <h2>{props.focusTitle || props.nextTask?.title || "Make room for what matters"}</h2>
        <p className="muted">
          {!props.focusTitle && props.nextTask?.estimated_duration ? `${props.nextTask.estimated_duration} minutes estimated. ` : ""}
          {props.focusTitle ? "Your timer continues across tabs." : "Choose your next task and begin a focused session."}
        </p>
        <button className="primary" disabled={!props.timerReady || props.busy || props.loading} onClick={() => props.onFocus(props.nextTask?.id)}>
          <Play />{props.focusTitle ? "Return to focus" : "Start focus"}
        </button>
      </section>
      <section className="card" aria-label="Next event">
        <h2>Next event</h2>
        {props.nextEvent ? (
          <>
            <p>{props.nextEvent.title}</p>
            <p className="muted">{time(props.nextEvent.start_at)} – {time(props.nextEvent.end_at)}</p>
            <button onClick={props.onSchedule}>View schedule</button>
          </>
        ) : <p className="muted">No more events today. Your time is yours.</p>}
      </section>
      <section className="card stack" aria-label="Today’s tasks">
        <h2>Today’s tasks</h2>
        {props.loading && !props.tasks.length ? <div role="status" aria-label="Loading your day"><div className="loading-card" /></div> : props.tasks.length ? (
          props.tasks.map(task => (
            <div className="today-task" key={task.id}>
              <button className="completion-button" aria-label={`Complete ${task.title}${task.repeat_weekdays?.length ? " for today" : ""}`} disabled={props.busy || props.pending.has(task.id)} onClick={() => props.onComplete(task.id)}><Circle /></button>
              <button className="task-title grow" onClick={() => props.onEdit(task.id)}>{task.title}</button>
              {!task.repeat_weekdays?.length && task.deadline && new Date(task.deadline) < new Date() && <span className="danger">Overdue</span>}
              <button disabled={props.busy || props.pending.has(task.id) || !props.timerReady || !!props.focusTitle} onClick={() => props.onFocus(task.id)}><Play />Start focus</button>
              {props.pending.has(task.id) && <p role="status">Saving…</p>}
              {props.errors[task.id] && <p className="error" role="alert">{props.errors[task.id]}</p>}
            </div>
          ))
        ) : <div className="empty"><p>You’re clear for today.</p><button onClick={props.onAdd}>Add a task</button></div>}
      </section>
      <button onClick={props.onTasks}>View all tasks</button>
    </div>
  );
}
