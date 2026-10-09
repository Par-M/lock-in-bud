from dataclasses import dataclass
from dataclasses import field
from datetime import date
from datetime import datetime
from datetime import time
from datetime import timedelta
from zoneinfo import ZoneInfo

from app.services.scheduling.context import ProposedBlock
from app.services.scheduling.context import SchedulingContext


@dataclass
class ValidationResult:
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    @property
    def is_valid(self) -> bool:
        return not self.errors


def _normalize(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=ZoneInfo("UTC"))
    return value


def _hour_minute(value: float) -> tuple[int, int]:
    hour = int(value)
    minute = int(round((value - hour) * 60))
    if minute == 60:
        hour += 1
        minute = 0
    return hour, minute


def _window_for(block_start: datetime, context: SchedulingContext):
    tz = ZoneInfo(context.timezone)
    local = block_start.astimezone(tz)
    day = local.date()
    start_h, start_m = _hour_minute(context.work_start_hour)
    end_h, end_m = _hour_minute(context.work_end_hour)
    midnight = datetime.combine(day, time(), tzinfo=tz)
    start = midnight + timedelta(hours=start_h, minutes=start_m)
    end = midnight + timedelta(hours=end_h, minutes=end_m)
    return start, end


def validate_schedule(
    result: ProposedBlock | list[ProposedBlock],
    context: SchedulingContext,
    *,
    strict_availability: bool = False,
) -> ValidationResult:
    blocks = result if isinstance(result, list) else [result]
    validation = ValidationResult()

    tasks_by_id = {task.id: task for task in context.tasks}
    busy = [
        (_normalize(slot.start), _normalize(slot.end))
        for slot in context.busy_times
        if _normalize(slot.start) < _normalize(slot.end)
    ]
    fixed_windows = [
        (
            task,
            _normalize(task.start_at),
            _normalize(task.end_at),
        )
        for task in context.tasks
        if task.is_fixed
    ]

    normalized: list[tuple[ProposedBlock, datetime, datetime]] = []
    scheduled_minutes: dict[object, int] = {}

    for block in blocks:
        if not isinstance(block, ProposedBlock) or not isinstance(
            block.start, datetime
        ) or not isinstance(block.end, datetime):
            validation.errors.append("Malformed schedule block")
            continue
        start = _normalize(block.start)
        end = _normalize(block.end)

        if start >= end:
            validation.errors.append(
                f"Invalid time for '{block.task_title}': end is not after start"
            )
            continue
        if block.task_id not in tasks_by_id:
            validation.errors.append(
                f"Unknown task_id {block.task_id} in schedule output"
            )
            continue

        task = tasks_by_id[block.task_id]
        if strict_availability and not task.is_fixed:
            tz = ZoneInfo(context.timezone)
            horizon_end = (
                datetime.combine(max(context.dates) + timedelta(days=1), time(), tzinfo=tz)
                if context.dates else None
            )
            if (
                not context.dates
                or start.astimezone(tz).date() not in context.dates
                or end > horizon_end
                or not any(
                    _normalize(slot.start) <= start and end <= _normalize(slot.end)
                    for slot in context.free_slots
                )
            ):
                validation.errors.append(
                    f"'{block.task_title}' is outside available free slots or the scheduling horizon"
                )
        if task.deadline is not None and end > _normalize(task.deadline):
            if task.is_overdue:
                validation.warnings.append(
                    f"'{block.task_title}' is overdue and scheduled after its "
                    "already-passed deadline, which is allowed."
                )
            else:
                validation.errors.append(
                    f"Deadline violation for '{block.task_title}': "
                    f"block ends after its deadline"
                )

        if task.is_fixed and (
            start != _normalize(task.start_at) or end != _normalize(task.end_at)
        ):
            validation.errors.append(
                f"Fixed task '{block.task_title}' must be scheduled exactly "
                f"at its fixed window {_normalize(task.start_at).isoformat()}-"
                f"{_normalize(task.end_at).isoformat()}"
            )

        window_start, window_end = _window_for(start, context)
        if start < window_start or end > window_end:
            if task.is_fixed:
                validation.warnings.append(
                    f"'{block.task_title}' is scheduled outside working hours (fixed event)"
                )
            else:
                validation.errors.append(
                    f"'{block.task_title}' is scheduled outside working hours"
                )

        for busy_start, busy_end in busy:
            if start < busy_end and end > busy_start:
                validation.warnings.append(
                    f"'{block.task_title}' overlaps a busy calendar event"
                )
                break

        block_minutes = int((end - start).total_seconds() // 60)
        if block_minutes > context.max_chunk_minutes:
            validation.warnings.append(
                f"Block for '{block.task_title}' is longer than the "
                f"{context.max_chunk_minutes} minute chunk limit"
            )

        scheduled_minutes[block.task_id] = (
            scheduled_minutes.get(block.task_id, 0) + block_minutes
        )
        normalized.append((block, start, end))

    for task in context.tasks:
        scheduled = scheduled_minutes.get(task.id, 0)
        if scheduled > task.duration_minutes:
            validation.errors.append(
                f"Task '{task.title}' is scheduled for {scheduled} minutes, "
                f"which exceeds its {task.duration_minutes} minute duration"
            )
        elif scheduled < task.duration_minutes:
            validation.warnings.append(
                f"Task '{task.title}' is only partially scheduled "
                f"({scheduled} of {task.duration_minutes} minutes)"
            )
        if task.is_fixed:
            count = sum(
                1 for block, _, _ in normalized if block.task_id == task.id
            )
            if count > 1:
                validation.errors.append(
                    f"Fixed task '{task.title}' must be scheduled as a single "
                    f"block at its fixed window"
                )

    for index, (block, start, end) in enumerate(normalized):
        for other_block, other_start, other_end in normalized[(index + 1) :]:
            if start < other_end and end > other_start:
                if strict_availability and (
                    not tasks_by_id[block.task_id].is_fixed
                    or not tasks_by_id[other_block.task_id].is_fixed
                ):
                    validation.errors.append(
                        f"'{block.task_title}' overlaps another scheduled block"
                    )
                validation.warnings.append(
                    f"'{block.task_title}' overlaps another scheduled block"
                )

    for block, start, end in normalized:
        task = tasks_by_id[block.task_id]
        if task.is_fixed:
            continue
        for fixed_task, fixed_start, fixed_end in fixed_windows:
            if start < fixed_end and end > fixed_start:
                validation.warnings.append(
                    f"'{block.task_title}' overlaps the fixed window of "
                    f"'{fixed_task.title}'"
                )
                break

    if context.max_daily_hours > 0:
        cap_minutes = context.max_daily_hours * 60
        tz = ZoneInfo(context.timezone)
        daily_total = dict(context.committed_minutes_by_day) if strict_availability else {}
        daily_fixed: dict[date, int] = {}
        daily_flexible: dict[date, int] = {}
        for block, start, end in normalized:
            cursor = start.astimezone(tz)
            local_end = end.astimezone(tz)
            while cursor < local_end:
                day = cursor.date()
                day_end = datetime.combine(day + timedelta(days=1), time(), tzinfo=tz)
                segment_end = min(local_end, day_end) if strict_availability else local_end
                minutes = int((segment_end - cursor).total_seconds() // 60)
                daily_total[day] = daily_total.get(day, 0) + minutes
                if tasks_by_id[block.task_id].is_fixed:
                    daily_fixed[day] = daily_fixed.get(day, 0) + minutes
                else:
                    daily_flexible[day] = daily_flexible.get(day, 0) + minutes
                cursor = segment_end
        for day, total in daily_total.items():
            if strict_availability and total > cap_minutes and daily_flexible.get(day, 0) > 0:
                validation.errors.append(
                    f"Schedules more than {context.max_daily_hours} hours of work "
                    f"on {day.isoformat()} including retained commitments"
                )
            if total > cap_minutes and daily_fixed.get(day, 0) <= cap_minutes:
                validation.warnings.append(
                    f"Schedules more than {context.max_daily_hours} hours of "
                    f"work on {day.isoformat()}"
                )

    if context.buffer_minutes > 0:
        ordered = sorted(normalized, key=lambda entry: entry[1])
        for (first, f_start, f_end), (second, s_start, s_end) in zip(
            ordered, ordered[1:]
        ):
            if first.task_id == second.task_id:
                continue
            gap = (s_start - f_end).total_seconds() / 60
            if 0 <= gap < context.buffer_minutes:
                validation.warnings.append(
                    f"Buffer of {context.buffer_minutes} minutes not kept between "
                    f"'{first.task_title}' and '{second.task_title}'"
                )

    scheduled_ids = {block.task_id for block, _, _ in normalized}
    for task in context.tasks:
        if task.id not in scheduled_ids:
            validation.warnings.append(
                f"Task '{task.title}' was not scheduled"
            )

    return validation
