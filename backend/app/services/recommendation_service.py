import re
import uuid
from datetime import date
from datetime import datetime
from datetime import time
from datetime import timedelta
from zoneinfo import ZoneInfo

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models.calendar_block import CalendarBlock
from app.models.task import Task
from app.models.task import TaskPriority
from app.models.task import TaskStatus
from app.models.user_preference import UserPreference
from app.schemas.calendar import BusyTime
from app.schemas.recommendation import MAX_RECOMMENDATION_DAYS
from app.services.scheduling.context import TimeSlot
from app.services.scheduling.free_slots import find_free_slots
from app.services.scheduling.free_slots import merge_intervals

PRIORITY_WEIGHT = {
    TaskPriority.high: 0,
    TaskPriority.medium: 1,
    TaskPriority.low: 2,
}

MAX_PART_MINUTES = 90
MIN_PART_MINUTES = 15

_STEP_LINE = re.compile(r"^\s*(?:\d+[.)\]]|[-*•])\s+")


def _utc_now() -> datetime:
    from datetime import timezone

    return datetime.now(timezone.utc)


def split_description_into_steps(description: str) -> list[str]:
    """Extract ordered steps from a task description.

    Numbered lists ("1.", "1)"), bullets ("- ", "* ", "•") each become a step.
    Plain prose is split into sentences. Blank lines are dropped.
    """
    lines = [line.strip() for line in description.splitlines()]
    stepped = [
        _STEP_LINE.sub("", line).strip()
        for line in lines
        if _STEP_LINE.match(line)
    ]
    if len(stepped) >= 2:
        return [step for step in stepped if step]

    prose = " ".join(line for line in lines if line and not _STEP_LINE.match(line))
    sentences = [
        sentence.strip()
        for sentence in re.split(r"(?<=[.!?;])\s+", prose)
        if sentence.strip()
    ]
    return sentences


def _distribute_minutes(total: int, count: int) -> list[int]:
    """Split ``total`` minutes into ``count`` parts summing to exactly ``total``.

    Parts are allowed to be shorter than ``MIN_PART_MINUTES``. A task estimated
    at 30 minutes that describes four steps is 30 minutes of work; re-applying
    the minimum to each part after the budget runs out silently doubles the
    user's estimate, which is what this used to do.

    If the budget cannot give every step at least one minute the step count is
    capped rather than inflating the total.
    """
    if count <= 0 or total <= 0:
        return []
    count = min(count, total)
    base, extra = divmod(total, count)
    return [base + (1 if index < extra else 0) for index in range(count)]


def split_task_into_parts(
    title: str,
    description: str | None,
    duration_minutes: int,
) -> list[dict]:
    """Break a task into parts whose durations sum to the task's duration.

    Description steps become named parts. Without a usable description the task
    is chunked into <= MAX_PART_MINUTES pieces. Either way the parts are a
    partition of the budget, never an expansion of it.
    """
    total = max(MIN_PART_MINUTES, duration_minutes)

    if description:
        steps = split_description_into_steps(description)
        if len(steps) >= 2:
            parts = []
            for index, (step, minutes) in enumerate(
                zip(steps, _distribute_minutes(total, len(steps)))
            ):
                label = step if len(step) <= 80 else step[:77] + "…"
                parts.append({"index": index, "title": label, "minutes": minutes})
            return parts

    chunk = min(total, MAX_PART_MINUTES)
    parts = []
    remaining = total
    index = 0
    while remaining > 0:
        minutes = min(chunk, remaining)
        part_count_guess = -(-total // chunk)
        label = title if part_count_guess == 1 else f"{title} (part {index + 1})"
        parts.append({"index": index, "title": label, "minutes": minutes})
        remaining -= minutes
        index += 1
    return parts


class RecommendationService:
    def __init__(self, db: Session, user_id: uuid.UUID) -> None:
        self.db = db
        self.user_id = user_id

    def _preference(self) -> UserPreference:
        preference = self.db.scalar(
            select(UserPreference).where(UserPreference.user_id == self.user_id)
        )
        if preference is None:
            preference = UserPreference(user_id=self.user_id)
            self.db.add(preference)
            self.db.flush()
        return preference

    def _active_tasks(self) -> list[Task]:
        return list(
            self.db.scalars(
                select(Task).where(
                    Task.user_id == self.user_id,
                    Task.is_archived.is_(False),
                    Task.deleted_at.is_(None),
                    Task.status != TaskStatus.completed,
                    # Tasks with an explicit start time are already placed
                    # (fixed events); never re-recommend them.
                    Task.start_at.is_(None),
                )
            ).all()
        )

    @staticmethod
    def _sort_tasks(tasks: list[Task], now: datetime) -> list[Task]:
        return sorted(
            tasks,
            key=lambda t: (
                not (t.deadline is not None and t.deadline < now),
                t.deadline or now + timedelta(days=3650),  # soonest deadline
                PRIORITY_WEIGHT.get(t.priority, 1),
            ),
        )

    @staticmethod
    def _reason(task: Task, part_index: int, part_count: int, tz: ZoneInfo) -> str:
        reasons: list[str] = []
        if task.deadline is not None:
            local_deadline = task.deadline.astimezone(tz)
            if task.deadline < _utc_now():
                reasons.append("Overdue")
            else:
                days_left = (local_deadline.date() - datetime.now(tz).date()).days
                if days_left <= 0:
                    reasons.append("Due today")
                elif days_left == 1:
                    reasons.append("Due tomorrow")
                else:
                    reasons.append(f"Due in {days_left} days")
        if task.priority == TaskPriority.high:
            reasons.append("high priority")
        elif task.priority == TaskPriority.low:
            reasons.append("low priority")
        if part_count > 1:
            reasons.append(f"part {part_index + 1} of {part_count}")
        return ", ".join(reasons) if reasons else "fits your free time"

    @staticmethod
    def _allocate_window(
        slots: list[TimeSlot],
        used_by_slot: list[int],
        minutes: int,
        *,
        buffer_minutes: int = 0,
        deadline: datetime | None = None,
        earliest: datetime | None = None,
    ) -> tuple[datetime | None, datetime | None]:
        """Place a whole part in one free slot; failure consumes no capacity."""
        for index, slot in enumerate(slots):
            cursor = slot.start + timedelta(minutes=used_by_slot[index])
            if earliest is not None:
                cursor = max(cursor, earliest)
            end = cursor + timedelta(minutes=minutes)
            if end > slot.end or (deadline is not None and end > deadline):
                continue
            used_by_slot[index] = (
                int((end - slot.start).total_seconds() // 60) + buffer_minutes
            )
            return cursor, end
        return None, None

    def daily_recommendations(
        self,
        *,
        timezone_name: str,
        start_date: date | None,
        end_date: date | None,
        busy_times: list[BusyTime],
    ) -> dict:
        tz = ZoneInfo(timezone_name)
        now = _utc_now()
        today = now.astimezone(tz).date()

        window_start = start_date or today
        try:
            window_end = end_date or (window_start + timedelta(days=6))
            range_end = datetime.combine(
                window_end + timedelta(days=1), time.min, tzinfo=tz
            )
        except OverflowError as exc:
            raise ValueError("Recommendation range exceeds supported dates") from exc
        if not 1 <= (window_end - window_start).days + 1 <= MAX_RECOMMENDATION_DAYS:
            raise ValueError(
                f"Recommendation range must be 1-{MAX_RECOMMENDATION_DAYS} days"
            )

        dates = [
            window_start + timedelta(days=offset)
            for offset in range((window_end - window_start).days + 1)
        ]

        preference = self._preference()
        tasks = self._sort_tasks(self._active_tasks(), now)
        buffer = max(0, preference.buffer_minutes)
        range_start = datetime.combine(window_start, time.min, tzinfo=tz)
        blocks = list(self.db.scalars(
            select(CalendarBlock).where(
                CalendarBlock.user_id == self.user_id,
                CalendarBlock.deleted_at.is_(None),
                CalendarBlock.end_at > range_start,
                CalendarBlock.start_at < range_end,
            )
        ).all())
        internal_busy = [TimeSlot(block.start_at, block.end_at) for block in blocks]
        block_days = {
            (block.task_id, block.start_at.astimezone(tz).date()) for block in blocks
        }
        fixed_tasks = self.db.scalars(
            select(Task).where(
                Task.user_id == self.user_id,
                Task.is_archived.is_(False),
                Task.deleted_at.is_(None),
                Task.status != TaskStatus.completed,
                Task.start_at.is_not(None),
                Task.end_at.is_not(None),
            )
        ).all()
        for task in fixed_tasks:
            local_start = task.start_at.astimezone(tz)
            local_end = task.end_at.astimezone(tz)
            if not task.repeat_weekdays:
                if (task.id, local_start.date()) not in block_days:
                    internal_busy.append(TimeSlot(local_start, local_end))
                continue
            # Include the preceding day for overnight occurrences. Weekdays use
            # the native Sunday=0 convention, not Python's Monday=0.
            occurrence_days = set(dates)
            if window_start > date.min:
                occurrence_days.add(window_start - timedelta(days=1))
            overrides = task.repeat_overrides or {}
            # A moved occurrence can overlap this window even when its original
            # local-date key is outside it. Timed overrides are absolute dates.
            for key, override in overrides.items():
                if override and (override.get("start_at") or override.get("end_at")):
                    occurrence_days.add(date.fromisoformat(key))
            for day in sorted(occurrence_days):
                if (
                    day < local_start.date()
                    or (day.weekday() + 1) % 7 not in task.repeat_weekdays
                ):
                    continue
                if (
                    task.repeat_ends_on
                    and day > task.repeat_ends_on.astimezone(tz).date()
                ):
                    continue
                if (task.id, day) in block_days:
                    continue
                override = overrides.get(day.isoformat()) or {}
                default_start = datetime.combine(day, local_start.timetz(), tzinfo=tz)
                default_end = datetime.combine(
                    day + (local_end.date() - local_start.date()),
                    local_end.timetz(), tzinfo=tz,
                )
                if default_end <= default_start:
                    default_end += timedelta(days=1)
                occurrence_times = []
                for field, default in (("start_at", default_start), ("end_at", default_end)):
                    value = override.get(field)
                    parsed = (
                        datetime.fromisoformat(value.replace("Z", "+00:00"))
                        if value else default
                    )
                    if parsed.tzinfo is None:
                        parsed = parsed.replace(tzinfo=tz)
                    occurrence_times.append(parsed.astimezone(tz))
                start, end = occurrence_times
                if start < end:
                    internal_busy.append(TimeSlot(start, end))

        committed_by_date: dict[date, int] = {}
        merged_internal = merge_intervals(internal_busy)
        for day in dates:
            start = datetime.combine(day, time.min, tzinfo=tz)
            end = datetime.combine(day + timedelta(days=1), time.min, tzinfo=tz)
            committed_by_date[day] = sum(
                int((min(slot.end, end) - max(slot.start, start)).total_seconds() // 60)
                for slot in merged_internal
                if slot.start < end and slot.end > start
            )
        committed_by_task: dict[uuid.UUID, int] = {}
        pending_blocks = self.db.scalars(
            select(CalendarBlock).where(
                CalendarBlock.user_id == self.user_id,
                CalendarBlock.deleted_at.is_(None),
                CalendarBlock.completed_at.is_(None),
                CalendarBlock.end_at > now,
            )
        ).all()
        for block in pending_blocks:
            committed_by_task[block.task_id] = (
                committed_by_task.get(block.task_id, 0)
                + max(0, int((block.end_at - block.start_at).total_seconds() // 60))
            )

        # Free time is only computed for today onward. The window commonly
        # starts at the beginning of the current month (before today), and
        # treating those already-elapsed days as free made the recommender
        # anchor on the past, leaving today's recommendations empty.
        free_dates = [day for day in dates if day >= today]
        free_slots = find_free_slots(
            dates=free_dates,
            busy=[
                TimeSlot(
                    slot.start - timedelta(minutes=buffer),
                    slot.end + timedelta(minutes=buffer),
                )
                for slot in [*internal_busy, *busy_times]
            ],
            start_hour=preference.work_hours_start,
            end_hour=preference.work_hours_end,
            timezone=timezone_name,
            min_duration=timedelta(minutes=1),
        )
        slots_by_day: dict[date, list[TimeSlot]] = {}
        for slot in free_slots:
            slots_by_day.setdefault(slot.start.astimezone(tz).date(), []).append(slot)

        pending: list[tuple[Task, dict, int]] = []  # (task, part, part_count)
        for task in tasks:
            # Do not re-recommend completed work or work already committed to
            # pending calendar blocks, including blocks outside this window.
            estimated = task.estimated_duration or preference.default_duration_minutes
            completed = task.actual_duration or 0
            amount_left = max(
                0, estimated - completed - committed_by_task.get(task.id, 0)
            )
            if amount_left <= 0:
                continue
            parts = split_task_into_parts(task.title, task.description, amount_left)
            if amount_left < MIN_PART_MINUTES:
                for part, minutes in zip(
                    parts, _distribute_minutes(amount_left, len(parts))
                ):
                    part["minutes"] = minutes
                parts = parts[:amount_left]
            for part in parts:
                pending.append((task, part, len(parts)))

        slots_by_date: dict[date, list[TimeSlot]] = {
            day: sorted(
                slots_by_day.get(day, []),
                key=lambda slot: (slot.start, slot.end),
            )
            for day in dates
        }
        capacity_by_date: dict[date, int] = {
            day: min(
                sum(slot.duration_minutes for slot in slots_by_date[day]),
                max(0, preference.max_daily_hours * 60 - committed_by_date[day]),
            )
            for day in dates
        }
        used_by_slot: dict[date, list[int]] = {
            day: [0] * len(slots_by_date[day]) for day in dates
        }
        items_by_date: dict[date, list[dict]] = {day: [] for day in dates}
        used_by_date: dict[date, int] = {day: 0 for day in dates}

        days: list[dict] = []
        unscheduled: list[dict] = []

        def unscheduled_item(task: Task, part: dict) -> dict:
            return {
                "task_id": str(task.id),
                "task_title": task.title,
                "part_title": part["title"],
                "part_index": part["index"],
                "minutes": part["minutes"],
                "priority": task.priority.value,
                "category": task.category,
            }

        # Group each task's parts so all parts of a task are placed together in
        # index order: a later part is only scheduled on the same day or a later
        # day than the part before it, so part 9 never shows a time block before
        # parts 1-8.
        pending_by_task: list[tuple[Task, list[tuple[dict, int]]]] = []
        for task, part, part_count in pending:
            if pending_by_task and pending_by_task[-1][0].id == task.id:
                pending_by_task[-1][1].append((part, part_count))
            else:
                pending_by_task.append((task, [(part, part_count)]))

        def _pack(
            task: Task,
            parts: list[tuple[dict, int]],
            eligible: set[int],
            start_index: int,
            used_date: dict[date, int],
            used_slot: dict[date, list[int]],
        ) -> list[tuple[dict, int, date, datetime, datetime]] | None:
            """Pack every part into the earliest eligible day with room,
            holding on to that day until it is full before moving to the next
            one, so the recommended section fills today (then tomorrow, ...)
            with the full time each task needs. Parts stay in index order and
            never get placed on days before their earliest eligible day.
            Returns None if any part cannot be placed."""
            last = len(dates) - 1
            current = start_index
            placed: list[tuple[dict, int, date, datetime, datetime]] = []
            earliest = None
            deadline = task.deadline if task.deadline and task.deadline >= now else None
            for part, part_count in parts:
                minutes = part["minutes"]
                day_index = current
                block_start = block_end = None
                while day_index <= last:
                    day = dates[day_index]
                    if (
                        day_index in eligible
                        and capacity_by_date[day] - used_date[day] >= minutes
                    ):
                        block_start, block_end = self._allocate_window(
                            slots_by_date[day], used_slot[day], minutes,
                            buffer_minutes=buffer, deadline=deadline, earliest=earliest,
                        )
                        if block_start is not None:
                            break
                    day_index += 1
                if day_index > last or block_start is None:
                    return None
                used_date[dates[day_index]] += minutes
                placed.append(
                    (part, part_count, dates[day_index], block_start, block_end)
                )
                current = day_index
                earliest = block_end + timedelta(minutes=buffer)
            return placed

        for task, parts in pending_by_task:
            eligible = self._eligible_days(
                task, dates, tz, window_start, window_end
            )
            if not eligible:
                unscheduled.extend(
                    unscheduled_item(task, part) for part, _ in parts
                )
                continue

            # Pack the task's parts into the earliest eligible days, holding a
            # day until it is full before moving forward, so the recommended
            # section fills today (then tomorrow, ...) with the full time each
            # task needs. Anchoring at the least-loaded day instead made empty
            # future days win and starved today.
            used_date = dict(used_by_date)
            used_slot = {d: list(v) for d, v in used_by_slot.items()}
            placed = _pack(
                task, parts, set(eligible), eligible[0], used_date, used_slot
            )
            if placed is None:
                unscheduled.extend(
                    unscheduled_item(task, part) for part, _ in parts
                )
                continue

            used_by_date = used_date
            used_by_slot = used_slot
            for part, part_count, day, block_start, block_end in placed:
                items_by_date[day].append(
                    {
                        "task_id": str(task.id),
                        "task_title": task.title,
                        "part_title": part["title"],
                        "part_index": part["index"],
                        "part_count": part_count,
                        "minutes": part["minutes"],
                        "priority": task.priority.value,
                        "category": task.category,
                        "deadline": (
                            task.deadline.isoformat()
                            if task.deadline
                            else None
                        ),
                        "is_overdue": (
                            task.deadline is not None and task.deadline < now
                        ),
                        "reason": self._reason(
                            task, part["index"], part_count, tz
                        ),
                        "start_at": (
                            block_start.isoformat() if block_start else None
                        ),
                        "end_at": (
                            block_end.isoformat() if block_end else None
                        ),
                    }
                )

        # Stable chained sort within each day: overdue first, then soonest
        # deadline, then highest priority, then part order, so items read most-
        # urgent first and multi-part tasks appear in sequence.
        priority_string_weight = {
            "high": PRIORITY_WEIGHT[TaskPriority.high],
            "medium": PRIORITY_WEIGHT[TaskPriority.medium],
            "low": PRIORITY_WEIGHT[TaskPriority.low],
        }
        for day in dates:
            items_by_date[day].sort(
                key=lambda item: (
                    not item["is_overdue"],
                    item["deadline"] or "9999",
                    priority_string_weight.get(item.get("priority"), 1),
                    item["part_index"],
                )
            )
            days.append(
                {
                    "date": day.isoformat(),
                    "available_minutes": capacity_by_date[day],
                    "items": items_by_date[day],
                }
            )

        return {"days": days, "unscheduled": unscheduled}

    @staticmethod
    def _eligible_days(
        task: Task,
        dates: list[date],
        tz,
        window_start: date,
        window_end: date,
    ) -> list[int]:
        """Day indices a part may be placed on while still finishing before the
        deadline. Overdue work is restricted to the earliest usable days so it
        is prioritized; otherwise the window runs from today through the
        deadline (or the whole window when there is no deadline). Days before
        today are never eligible: the window commonly starts at the beginning
        of the current month, and recommending into the past leaves today
        empty."""
        last = len(dates) - 1
        today_local = _utc_now().astimezone(tz).date()
        first_usable = next(
            (i for i, day in enumerate(dates) if day >= today_local), last + 1
        )
        if first_usable > last:
            return []
        if task.deadline is None:
            return list(range(first_usable, last + 1))
        deadline_day = task.deadline.astimezone(tz).date()
        if task.deadline < _utc_now():
            return (
                list(range(first_usable, min(first_usable + 2, last + 1)))
                or [first_usable]
            )
        for index, day in enumerate(dates):
            if day > deadline_day:
                return list(range(max(first_usable, 0), max(index, first_usable)))
        return list(range(first_usable, last + 1))

    def breakdown_task(self, task: Task) -> dict:
        duration = task.estimated_duration or 30
        parts = split_task_into_parts(task.title, task.description, duration)
        return {
            "task_id": str(task.id),
            "task_title": task.title,
            "parts": parts,
            "source": "description" if len(parts) > 1 and task.description else "chunked",
        }
