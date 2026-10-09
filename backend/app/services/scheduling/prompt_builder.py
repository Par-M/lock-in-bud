from datetime import date

from app.services.scheduling.context import SchedulingContext
from app.services.scheduling.context import TaskContext
from app.services.scheduling.context import TimeSlot


def _local(ts: TimeSlot, timezone: str) -> str:
    start = ts.start.astimezone(_tz(timezone))
    end = ts.end.astimezone(_tz(timezone))
    return f"{start.strftime('%a %H:%M')}-{end.strftime('%H:%M')} ({start.date().isoformat()})"


def _tz(timezone: str):
    from zoneinfo import ZoneInfo

    return ZoneInfo(timezone)


def _deadline(task: TaskContext) -> str:
    if task.deadline is None:
        return "none"
    return task.deadline.date().isoformat()


def _fixed_window(task: TaskContext, timezone: str) -> str:
    if not task.is_fixed:
        return "none"
    tz = _tz(timezone)
    start = task.start_at.astimezone(tz)
    end = task.end_at.astimezone(tz)
    return (
        f"{start.strftime('%a %H:%M')}-{end.strftime('%H:%M')} "
        f"({start.date().isoformat()}, {timezone})"
    )


def _ordering(task: TaskContext) -> str:
    parts = []
    if task.after_task_titles:
        parts.append(
            "after: " + ", ".join(f'"{title}"' for title in task.after_task_titles)
        )
    if task.before_task_titles:
        parts.append(
            "before: " + ", ".join(f'"{title}"' for title in task.before_task_titles)
        )
    return "; ".join(parts) if parts else "none"


def _hour_text(value: float) -> str:
    hour = int(value)
    minute = int(round((value - hour) * 60))
    if minute == 60:
        hour += 1
        minute = 0
    return f"{hour}:{minute:02d}"


def build_prompt(context: SchedulingContext) -> str:
    lines = [
        "You are an expert scheduling assistant. Build a realistic schedule for the user's tasks.",
        "",
        f"Scheduling window: {context.dates[0].isoformat()} to {context.dates[-1].isoformat()} (local timezone {context.timezone}).",
        f"Working hours: {_hour_text(context.work_start_hour)}-{_hour_text(context.work_end_hour)} local time.",
        f"Daily max hours: schedule at most {context.max_daily_hours} hours of work in any single day "
        "(fixed events count toward this total).",
        f"Buffer between blocks: {context.buffer_minutes} minutes. Do not overlap blocks or busy times.",
        f"User energy level (1-5): {context.energy_level}. Schedule demanding work during the user's most energetic window.",
        f"Tasks longer than {context.max_chunk_minutes} minutes must be split into multiple blocks, "
        f"each at most {context.max_chunk_minutes} minutes and within a single free slot. "
        "All blocks of a task keep the same task_id; the blocks of one task together must cover its full duration.",
        "",
        "Tasks:",
    ]
    for task in context.tasks:
        lines.append(
            f"- id={task.id} | {task.title} | {task.duration_minutes} min "
            f"| deadline={_deadline(task)} "
            f"| overdue={'yes' if task.is_overdue else 'no'} "
            f"| fixed={_fixed_window(task, context.timezone)} "
            f"| ordering={_ordering(task)} "
            f"| energy={task.energy_level}"
        )
    lines.append("")
    if context.committed_minutes_by_day:
        lines.append("Retained commitments already count toward the daily max hours:")
        for day, minutes in sorted(context.committed_minutes_by_day.items()):
            lines.append(
                f"- {day.isoformat()}: {minutes} min committed; "
                f"{max(0, context.max_daily_hours * 60 - minutes):g} min remaining for proposed work."
            )
        lines.append("")
    lines.append("Free time slots (UTC ISO times are given in the schedule):")
    if context.free_slots:
        for slot in context.free_slots:
            lines.append(
                f"- {_local(slot, context.timezone)} "
                f"(UTC {slot.start.isoformat()} to {slot.end.isoformat()})"
            )
    else:
        lines.append("- (none available)")
    lines.append("")
    lines.append(
        "Return ONLY a JSON object with this exact shape (no markdown):"
    )
    lines.append(
        """
{
  "items": [
    {
      "task_id": "<uuid>",
      "task_title": "<title>",
      "start": "<ISO8601 UTC start>",
      "end": "<ISO8601 UTC end>",
      "reason": "<human-readable reason>"
    }
  ],
  "reasoning": "<short overall explanation of the schedule choices>"
}
"""
    )
    lines.append(
        "Constraints: schedule each task with a deadline BEFORE its due date "
        "(every block's end must be <= the deadline). Pick a time that fits "
        "before the due date, not necessarily the next available day. Every "
        "block must be inside working hours and must not overlap another block "
        "or a busy slot. A task may appear as multiple blocks (its chunks); "
        "all of a task's blocks must fit before the deadline and together cover "
        "the full task duration. If a task cannot be fully scheduled before its "
        "deadline, omit it entirely and say so in reasoning."
    )
    lines.append(
        "Overdue tasks (overdue=yes) have a deadline that has already passed. "
        "They are the TOP priority: schedule them as early as possible in the "
        "window, before any non-overdue task, even if that places a block after "
        "their (already past) due date. Only omit an overdue task if there is "
        "genuinely no free slot that fits its duration. Never deprioritize an "
        "overdue task or omit it just because its due date has passed."
    )
    lines.append(
        "Fixed tasks (fixed value other than \"none\") are HARD time constraints: "
        "schedule each one as exactly ONE block spanning its fixed start and end times, "
        "in that exact window. Never move, shorten, split, or extend a fixed task, and "
        "never place any other task's block inside a fixed task's window. If a fixed "
        "window cannot be honoured, omit that task and explain why in reasoning."
    )
    lines.append(
        "Ordering constraints: when a task's ordering lists another task under "
        "\\\"after\\\", its blocks (or at least the first block) must be scheduled AFTER "
        "all blocks of that referenced task. When a task's ordering lists another task "
        "under \\\"before\\\", its blocks must be scheduled BEFORE any block of that "
        "referenced task. Respect every ordering constraint; if the ordering forces an "
        "unschedulable layout, omit the task that cannot be placed and say so in reasoning."
    )
    return "\n".join(lines)
