import uuid
from datetime import datetime
from datetime import time as dt_time
from datetime import timedelta
from zoneinfo import ZoneInfo

from sqlalchemy import func
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models.calendar_block import CalendarBlock
from app.models.task import Task
from app.models.task import TaskPriority
from app.models.task import TaskStatus
from app.models.task_miss import TaskMiss
from app.models.user_preference import UserPreference
from app.schemas.planner import CategoryMissed
from app.schemas.planner import DailySummaryResponse
from app.schemas.planner import MissedReasonsResponse
from app.schemas.planner import MissedTaskEntry
from app.schemas.planner import ScheduledTask
from app.schemas.planner import TodayResponse
from app.schemas.task import TaskResponse

PRIORITY_RANK = {
    TaskPriority.low: 0,
    TaskPriority.medium: 1,
    TaskPriority.high: 2,
}


def _as_scheduled(
    task: Task, start: datetime | None = None, end: datetime | None = None
) -> ScheduledTask:
    return ScheduledTask.model_validate(task).model_copy(
        update={"start": start, "end": end}
    )


class PlannerService:
    def __init__(self, db: Session, user_id: uuid.UUID):
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

    def _scheduled_tasks(
        self, window_start: datetime, window_end: datetime
    ) -> dict[uuid.UUID, tuple[Task, CalendarBlock]]:
        blocks = list(
            self.db.scalars(
                select(CalendarBlock)
                .where(
                    CalendarBlock.user_id == self.user_id,
                    CalendarBlock.deleted_at.is_(None),
                    CalendarBlock.start_at >= window_start,
                    CalendarBlock.start_at < window_end,
                )
                .order_by(CalendarBlock.start_at)
            ).all()
        )
        task_ids = {block.task_id for block in blocks}
        tasks = {
            task.id: task
            for task in self.db.scalars(
                select(Task).where(
                    Task.user_id == self.user_id,
                    Task.deleted_at.is_(None),
                    Task.id.in_(task_ids),
                )
            ).all()
        }
        result: dict[uuid.UUID, tuple[Task, CalendarBlock]] = {}
        for block in blocks:
            task = tasks.get(block.task_id)
            if task is None:
                continue
            if block.task_id not in result:
                result[block.task_id] = (task, block)
        return result

    def today(self, timezone_name: str = "UTC") -> TodayResponse:
        tz = ZoneInfo(timezone_name)
        now = datetime.now(tz)
        today_start = datetime.combine(now.date(), dt_time.min, tzinfo=tz)
        tomorrow = today_start + timedelta(days=1)

        preference = self._preference()
        scheduled = self._scheduled_tasks(today_start, tomorrow)

        current_task: ScheduledTask | None = None
        next_tasks: list[ScheduledTask] = []
        priority_task: ScheduledTask | None = None
        priority_rank = -1
        scheduled_minutes_remaining = 0

        for task_id, (task, block) in scheduled.items():
            if task.status == TaskStatus.completed:
                continue
            if block.start_at <= now < block.end_at:
                current_task = _as_scheduled(task, block.start_at, block.end_at)
            elif block.start_at > now:
                next_tasks.append(_as_scheduled(task, block.start_at, block.end_at))
            if block.end_at > now:
                scheduled_minutes_remaining += int(
                    (block.end_at - max(block.start_at, now)).total_seconds() / 60
                )
            rank = PRIORITY_RANK.get(task.priority, 0)
            if rank > priority_rank:
                priority_rank = rank
                priority_task = _as_scheduled(task, block.start_at, block.end_at)

        next_tasks.sort(key=lambda item: item.start)

        if priority_task is None:
            active = list(
                self.db.scalars(
                    select(Task).where(
                        Task.user_id == self.user_id,
                    Task.deleted_at.is_(None),
                        Task.is_archived.is_(False),
                        Task.status != TaskStatus.completed,
                    )
                ).all()
            )
            if active:
                best = max(
                    active, key=lambda t: PRIORITY_RANK.get(t.priority, 0)
                )
                priority_task = _as_scheduled(best)

        completed_today = self.db.scalar(
            select(func.count())
            .select_from(Task)
            .where(
                Task.user_id == self.user_id,
                    Task.deleted_at.is_(None),
                Task.completed_at >= today_start,
                Task.completed_at < tomorrow,
            )
        )

        work_start = today_start + timedelta(
            hours=preference.work_hours_start
        )
        work_end = today_start + timedelta(hours=preference.work_hours_end)
        if work_end > now:
            working_remaining = max(
                0.0,
                (work_end - max(now, work_start)).total_seconds() / 60,
            )
        else:
            working_remaining = 0.0
        focus_time_remaining = max(
            0, int(round(working_remaining - scheduled_minutes_remaining))
        )

        day_progress = max(
            0.0, min(1.0, (now - today_start).total_seconds() / 86400)
        )

        return TodayResponse(
            current_task=current_task,
            priority_task=priority_task,
            next_tasks=next_tasks,
            completed_today=completed_today or 0,
            focus_time_remaining=focus_time_remaining,
            day_progress=day_progress,
        )

    def daily_summary(self, timezone_name: str = "UTC") -> DailySummaryResponse:
        tz = ZoneInfo(timezone_name)
        today = datetime.now(tz).date()
        today_start = datetime.combine(today, dt_time.min, tzinfo=tz)
        tomorrow = today_start + timedelta(days=1)

        completed = list(
            self.db.scalars(
                select(Task)
                .where(
                    Task.user_id == self.user_id,
                    Task.deleted_at.is_(None),
                    Task.completed_at >= today_start,
                    Task.completed_at < tomorrow,
                    Task.is_archived.is_(False),
                )
                .order_by(Task.completed_at)
            ).all()
        )

        scheduled = self._scheduled_tasks(today_start, tomorrow)
        in_progress: list[Task] = []
        pending: list[Task] = []
        for task_id, (task, block) in scheduled.items():
            if task.status == TaskStatus.completed:
                continue
            if task.status == TaskStatus.in_progress:
                in_progress.append(task)
            else:
                pending.append(task)
        in_progress.sort(key=lambda t: scheduled[t.id][1].start_at)
        pending.sort(key=lambda t: scheduled[t.id][1].start_at)

        hours_worked = round(
            sum(task.actual_duration or 0 for task in completed) / 60, 1
        )

        planned_ids = set(scheduled.keys())
        completed_ids = {task.id for task in completed}
        completed_planned = len(planned_ids & completed_ids)
        tasks_remaining = len(in_progress) + len(pending)
        schedule_adherence = (
            round(completed_planned / len(planned_ids), 2)
            if planned_ids
            else 1.0
        )

        moved_blocks = list(
            self.db.scalars(
                select(CalendarBlock)
                .where(
                    CalendarBlock.user_id == self.user_id,
                    CalendarBlock.deleted_at.is_(None),
                    CalendarBlock.updated_at >= today_start,
                    CalendarBlock.updated_at < tomorrow,
                )
            ).all()
        )
        moved_tasks: set[uuid.UUID] = set()
        for block in moved_blocks:
            if block.updated_at <= block.created_at:
                continue
            task = self.db.get(Task, block.task_id)
            if (
                task is not None
                and task.user_id == self.user_id
                and task.status != TaskStatus.completed
            ):
                moved_tasks.add(task.id)
        tasks_moved = len(moved_tasks)

        missed_today = list(
            self.db.scalars(
                select(TaskMiss)
                .where(
                    TaskMiss.user_id == self.user_id,
                    TaskMiss.created_at >= today_start,
                    TaskMiss.created_at < tomorrow,
                )
                .order_by(TaskMiss.created_at)
            ).all()
        )

        return DailySummaryResponse(
            date=today,
            completed=[TaskResponse.model_validate(t) for t in completed],
            in_progress=[
                TaskResponse.model_validate(t) for t in in_progress
            ],
            pending=[TaskResponse.model_validate(t) for t in pending],
            hours_worked=hours_worked,
            tasks_remaining=tasks_remaining,
            tasks_moved=tasks_moved,
            schedule_adherence=schedule_adherence,
            missed_today=[
                MissedTaskEntry.model_validate(m) for m in missed_today
            ],
        )

    def missed_reasons(self) -> MissedReasonsResponse:
        misses = list(
            self.db.scalars(
                select(TaskMiss)
                .where(TaskMiss.user_id == self.user_id)
                .order_by(TaskMiss.created_at.desc())
            ).all()
        )
        grouped: dict[str, list[TaskMiss]] = {}
        for miss in misses:
            grouped.setdefault(miss.category or "Uncategorized", []).append(miss)
        by_category = [
            CategoryMissed(
                category=category,
                count=len(items),
                reasons=[
                    MissedTaskEntry.model_validate(m) for m in items
                ],
            )
            for category, items in sorted(
                grouped.items(), key=lambda item: -len(item[1])
            )
        ]
        return MissedReasonsResponse(total=len(misses), by_category=by_category)
