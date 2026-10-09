import copy
import uuid
from datetime import date
from datetime import datetime
from datetime import time
from datetime import timedelta
from datetime import timezone
from zoneinfo import ZoneInfo

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.core.config import settings
from app.models.ai_recommendation import AIRecommendation
from app.models.ai_recommendation import RecommendationStatus
from app.models.calendar_block import CalendarBlock
from app.models.task import Task
from app.models.task import TaskProductivity
from app.models.task import TaskStatus
from app.models.user_preference import UserPreference
from app.schemas.calendar import BusyTime
from app.schemas.schedule import ScheduleGenerateRequest
from app.services.scheduling.context import ProposedBlock
from app.services.scheduling.context import ProviderResult
from app.services.scheduling.context import SchedulingContext
from app.services.scheduling.context import TaskContext
from app.services.scheduling.context import TimeSlot
from app.services.scheduling.free_slots import find_free_slots
from app.services.scheduling.free_slots import merge_intervals
from app.services.scheduling.providers import AIProvider
from app.services.scheduling.providers import HeuristicProvider
from app.services.scheduling.providers import ProviderError
from app.services.scheduling.providers import default_provider
from app.services.scheduling.prompt_builder import build_prompt
from app.services.scheduling.validator import validate_schedule


class RecommendationNotFoundError(Exception):
    pass


class RecommendationNotAcceptableError(Exception):
    pass


class NoTasksToScheduleError(Exception):
    pass


def _parse(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=_utc())
    return parsed


def _utc():
    from zoneinfo import ZoneInfo

    return ZoneInfo("UTC")


DEFAULT_SCHEDULE_HORIZON_DAYS = 7


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _item_to_dict(block: ProposedBlock) -> dict:
    return {
        "task_id": str(block.task_id),
        "task_title": block.task_title,
        "start": block.start.isoformat(),
        "end": block.end.isoformat(),
        "reason": block.reason,
        "accepted": False,
    }


class SchedulingService:
    def __init__(
        self,
        db: Session,
        user_id: uuid.UUID,
        provider: AIProvider | None = None,
    ) -> None:
        self.db = db
        self.user_id = user_id
        self.provider = provider or default_provider()
        self.heuristic = HeuristicProvider()

    # ------------------------------------------------------------------
    # Input gathering
    # ------------------------------------------------------------------
    def _active_tasks(self, task_ids: list[uuid.UUID] | None) -> list[Task]:
        statement = select(Task).where(
            Task.user_id == self.user_id,
            Task.is_archived.is_(False),
            Task.deleted_at.is_(None),
            Task.status != TaskStatus.completed,
        )
        if task_ids:
            statement = statement.where(Task.id.in_(task_ids))
        tasks = list(self.db.scalars(statement).all())

        # Fluid: keep tasks with pending blocks as reschedulable so they can move
        # Only exclude tasks whose blocks are all completed (task already done) - but those are already filtered by status != completed
        # For pending blocks, we keep the task in the pool and handle busy exclusion in _build_context
        return tasks

    def _preferences(self) -> UserPreference:
        preference = self.db.scalar(
            select(UserPreference).where(UserPreference.user_id == self.user_id)
        )
        if preference is None:
            preference = UserPreference(user_id=self.user_id)
            self.db.add(preference)
            self.db.flush()
        return preference

    PRODUCTIVITY_FACTORS = {
        TaskProductivity.fast: 0.8,
        TaskProductivity.moderate: 1.0,
        TaskProductivity.slow: 1.35,
    }

    def _productivity_factors(self, tasks: list[Task]) -> dict[uuid.UUID, float]:
        """Duration multipliers derived from the user's productivity history.

        A rated task uses its own rating; unrated tasks inherit the user's
        average pace so the schedule gives more (or less) time accordingly.
        """
        rated = list(
            self.db.scalars(
                select(Task).where(
                    Task.user_id == self.user_id,
                    Task.status == TaskStatus.completed,
                    Task.productivity.isnot(None),
                )
            ).all()
        )
        if rated:
            aggregate = sum(
                self.PRODUCTIVITY_FACTORS.get(task.productivity, 1.0)
                for task in rated
            ) / len(rated)
        else:
            aggregate = 1.0
        return {
            task.id: self.PRODUCTIVITY_FACTORS.get(task.productivity, aggregate)
            for task in tasks
        }

    def _build_context(
        self,
        tasks: list[Task],
        preference: UserPreference,
        request: ScheduleGenerateRequest,
    ) -> SchedulingContext:
        now = _utc_now()
        tz = ZoneInfo(request.timezone)
        today = now.astimezone(tz).date()
        effective_end = today + timedelta(days=DEFAULT_SCHEDULE_HORIZON_DAYS)
        for task in tasks:
            for when in (task.deadline, task.end_at):
                if when is not None:
                    day = when.astimezone(tz).date()
                    if day > effective_end:
                        effective_end = day
        dates = [
            today + timedelta(days=offset)
            for offset in range((effective_end - today).days + 1)
        ]
        fixed_tasks = {
            task.id: task
            for task in self.db.scalars(select(Task).where(
                Task.user_id == self.user_id,
                Task.is_archived.is_(False),
                Task.deleted_at.is_(None),
                Task.status != TaskStatus.completed,
                Task.start_at.is_not(None),
                Task.end_at.is_not(None),
            )).all()
        }
        fixed_tasks.update({
            task.id: task for task in tasks
            if task.start_at is not None and task.end_at is not None
        })
        new_fixed_windows = self._fixed_windows(list(fixed_tasks.values()), dates, tz)
        tasks = [task for task in tasks if not (
            task.repeat_weekdays and task.start_at is not None and task.end_at is not None
        )]
        factors = self._productivity_factors(tasks)
        remaining = {
            task.id: max(
                0,
                (task.estimated_duration or preference.default_duration_minutes)
                - (task.actual_duration or 0),
            )
            for task in tasks
        }
        tasks = [task for task in tasks if remaining[task.id] > 0]
        by_id = {task.id: task for task in tasks}
        context = SchedulingContext(
            tasks=[
                TaskContext(
                    id=task.id,
                    title=task.title,
                    deadline=task.deadline,
                    duration_minutes=max(
                        5, round(remaining[task.id] * factors.get(task.id, 1.0))
                    ),
                    priority=task.priority,
                    energy_level=preference.energy_level,
                    start_at=task.start_at,
                    end_at=task.end_at,
                    before_task_titles=tuple(
                        by_id[t].title
                        for t in (task.before_task_ids or [])
                        if t in by_id
                    ),
                    after_task_titles=tuple(
                        by_id[t].title
                        for t in (task.after_task_ids or [])
                        if t in by_id
                    ),
                    is_overdue=(
                        task.deadline is not None and task.deadline < now
                    ),
                )
                for task in tasks
            ],
            dates=dates,
            timezone=request.timezone,
            busy_times=request.busy_times,
            work_start_hour=preference.work_hours_start,
            work_end_hour=preference.work_hours_end,
            buffer_minutes=preference.buffer_minutes,
            energy_level=preference.energy_level,
            max_daily_hours=preference.max_daily_hours,
        )
        existing_blocks = list(
            self.db.scalars(
                select(CalendarBlock).where(
                    CalendarBlock.user_id == self.user_id,
                    CalendarBlock.deleted_at.is_(None),
                )
            ).all()
        )
        # Fluid: only flexible pending blocks are movable; fixed blocks are hard and never move
        # Already-planned flexible tasks shouldn't show in proposal unless they need to move.
        # Check which flexible pending blocks still fit in free slots (with new fixed/busy); only those that overlap need rescheduling.
        flexible_ids = {t.id for t in tasks if t.start_at is None or t.end_at is None}
        # Initial hard busy: fixed blocks + external busy + past + NEW fixed tasks windows
        hard_blocks_initial = [
            b for b in existing_blocks
            if b.task_id not in flexible_ids or b.completed_at is not None
        ]
        initial_free = find_free_slots(
            dates=dates,
            busy=[
                *context.busy_times,
                *[
                    TimeSlot(block.start_at, block.end_at)
                    for block in hard_blocks_initial
                    if block.start_at is not None and block.end_at is not None
                ],
                *new_fixed_windows,
                TimeSlot(start=now - timedelta(days=1), end=now),
                TimeSlot(start=now, end=now + timedelta(minutes=5)),
            ],
            start_hour=context.work_start_hour,
            end_hour=context.work_end_hour,
            timezone=context.timezone,
        )

        def _block_fits(block: CalendarBlock, free_slots: list[TimeSlot]) -> bool:
            if block.start_at is None or block.end_at is None:
                return False
            for slot in free_slots:
                if slot.start <= block.start_at and block.end_at <= slot.end:
                    return True
            return False

        # Group flexible pending blocks by task
        from collections import defaultdict

        flexible_blocks_by_task: dict[uuid.UUID, list[CalendarBlock]] = defaultdict(list)
        for blk in existing_blocks:
            if blk.task_id in flexible_ids and blk.completed_at is None:
                flexible_blocks_by_task[blk.task_id].append(blk)

        # Build required duration map for checking partial (deleted part) case
        required_by_id = {tc.id: tc.duration_minutes for tc in context.tasks}
        tasks_needing_move: set[uuid.UUID] = set()
        hard_flexible_blocks: list[CalendarBlock] = []
        for task_id, blks in flexible_blocks_by_task.items():
            # If any block doesn't fit, whole task needs rescheduling
            needs_move = any(not _block_fits(b, initial_free) for b in blks)
            # Also if total scheduled < required (e.g., one of two parts deleted), need to reschedule missing part
            if not needs_move:
                required = required_by_id.get(task_id, 0)
                scheduled_total = sum(
                    int((b.end_at - b.start_at).total_seconds() / 60)
                    for b in blks
                    if b.start_at and b.end_at
                )
                if required and scheduled_total + 5 < required:  # 5m tolerance
                    needs_move = True
            if needs_move:
                tasks_needing_move.add(task_id)
            else:
                # Still fits and fully scheduled - keep as hard busy, don't reschedule
                hard_flexible_blocks.extend(blks)

        # Final tasks: only new tasks (no existing block) or flexible tasks needing move + all fixed tasks
        # Fixed tasks are always in tasks list and always need scheduling (they have no existing block yet)
        tasks_staying = {task_id for task_id in flexible_blocks_by_task.keys() if task_id not in tasks_needing_move}
        # Fixed already planned never shows again (fixed never moves) - if fixed already has pending block, don't re-propose
        existing_block_task_ids = {b.task_id for b in existing_blocks}
        for t in tasks:
            if t.start_at is not None and t.end_at is not None and t.id in existing_block_task_ids:
                tasks_staying.add(t.id)
        # Remove tasks that already have a fitting block and don't need to move
        tasks = [t for t in tasks if t.id not in tasks_staying]
        # Also filter context.tasks to match (so proposal only shows moved tasks)
        context.tasks = [tc for tc in context.tasks if tc.id not in tasks_staying]

        # Final hard busy: fixed blocks + flexible blocks that still fit
        fluid_blocks = hard_blocks_initial + hard_flexible_blocks
        proposed_fixed_ids = {task.id for task in context.tasks if task.is_fixed}
        retained = merge_intervals([
            *[
                TimeSlot(block.start_at, block.end_at)
                for block in fluid_blocks
                if block.start_at is not None and block.end_at is not None
            ],
            *self._fixed_windows([
                task for task in fixed_tasks.values() if task.id not in proposed_fixed_ids
            ], dates, tz),
        ])
        for day in dates:
            start = datetime.combine(day, time(), tzinfo=tz)
            end = datetime.combine(day + timedelta(days=1), time(), tzinfo=tz)
            context.committed_minutes_by_day[day] = sum(
                int((min(slot.end, end) - max(slot.start, start)).total_seconds() // 60)
                for slot in retained if slot.start < end and slot.end > start
            )
        context.free_slots = find_free_slots(
            dates=dates,
            busy=[
                *context.busy_times,
                *new_fixed_windows,
                *[
                    TimeSlot(block.start_at, block.end_at)
                    for block in fluid_blocks
                    if block.start_at is not None and block.end_at is not None
                ],
                TimeSlot(
                    start=now - timedelta(days=1),
                    end=now,
                ),
                TimeSlot(
                    start=now,
                    end=now + timedelta(minutes=5),
                ),
            ],
            start_hour=context.work_start_hour,
            end_hour=context.work_end_hour,
            timezone=context.timezone,
        )
        return context

    def _fixed_windows(
        self, tasks: list[Task], dates: list[date], tz: ZoneInfo
    ) -> list[TimeSlot]:
        windows = []
        for task in tasks:
            local_start = task.start_at.astimezone(tz)
            local_end = task.end_at.astimezone(tz)
            if not task.repeat_weekdays:
                windows.append(TimeSlot(local_start, local_end))
                continue
            days = set(dates)
            if dates[0] > date.min:
                days.add(dates[0] - timedelta(days=1))
            overrides = task.repeat_overrides or {}
            # Overrides contain absolute times, including moves from outside the horizon.
            for key, override in overrides.items():
                if override and (override.get("start_at") or override.get("end_at")):
                    days.add(date.fromisoformat(key))
            for day in sorted(days):
                if day < local_start.date() or (day.weekday() + 1) % 7 not in task.repeat_weekdays:
                    continue
                if task.repeat_ends_on and day > task.repeat_ends_on.astimezone(tz).date():
                    continue
                start = datetime.combine(day, local_start.timetz(), tzinfo=tz)
                end = datetime.combine(
                    day + (local_end.date() - local_start.date()),
                    local_end.timetz(), tzinfo=tz,
                )
                if end <= start:
                    end += timedelta(days=1)
                override = overrides.get(day.isoformat()) or {}
                times = []
                for field, default in (("start_at", start), ("end_at", end)):
                    value = override.get(field)
                    parsed = datetime.fromisoformat(value.replace("Z", "+00:00")) if value else default
                    if parsed.tzinfo is None:
                        parsed = parsed.replace(tzinfo=tz)
                    times.append(parsed.astimezone(tz))
                if times[0] < times[1]:
                    windows.append(TimeSlot(*times))
        return windows

    # ------------------------------------------------------------------
    # Schedule generation
    # ------------------------------------------------------------------
    def generate(self, request: ScheduleGenerateRequest) -> AIRecommendation:
        tasks = self._active_tasks(request.task_ids)
        preference = self._preferences()
        context = self._build_context(tasks, preference, request)

        if not context.tasks:
            return self._store_pending(
                context,
                reasoning="No active tasks to schedule.",
                items=[],
                meta={
                    "overcommitted": False,
                    "risk": None,
                    "deferred_tasks": [],
                    "free_slots": self._serialize_free_slots(context),
                    "scheduleable_hours": round(context.scheduleable_minutes / 60, 1),
                    "required_hours": 0.0,
                    "provider": "none",
                    "warnings": [],
                },
                request=request,
            )

        prompt = build_prompt(context)
        result = None
        validation = None
        failure: str | None = None
        provider_used = "gemini"

        if settings.gemini_api_key:
            try:
                result = self.provider.generate_schedule(context, prompt)
                validation = validate_schedule(result.items, context, strict_availability=True)
                if not validation.is_valid:
                    result = self.provider.generate_schedule(context, prompt)
                    validation = validate_schedule(result.items, context, strict_availability=True)
            except (ProviderError, ValueError, TypeError, AttributeError) as exc:
                failure = str(exc)
                result = None

        if result is None or (validation is not None and not validation.is_valid):
            provider_used = "heuristic_fallback"
            try:
                result = self.heuristic.generate_schedule(context, prompt)
                validation = validate_schedule(result.items, context, strict_availability=True)
            except Exception as exc:  # pragma: no cover - defensive
                failure = str(exc)
                result = None

        if result is None or validation is None or not validation.is_valid:
            if validation is not None and validation.errors:
                failure = "; ".join(validation.errors)
            return self._store_failed(context, failure, request=request)

        meta = self._build_meta(context, result, validation, provider_used)
        return self._store_pending(
            context,
            reasoning=result.reasoning,
            items=result.items,
            meta=meta,
            request=request,
        )

    def _build_meta(self, context, result, validation, provider_used: str) -> dict:
        scheduled_ids = {block.task_id for block in result.items}
        deferred = [
            task.title for task in context.tasks if task.id not in scheduled_ids
        ]
        overcommitted = False
        risk = None
        warnings = list(validation.warnings) if validation else []
        return {
            "overcommitted": overcommitted,
            "risk": risk,
            "deferred_tasks": deferred,
            "free_slots": self._serialize_free_slots(context),
            "scheduleable_hours": round(context.scheduleable_minutes / 60, 1),
            "required_hours": round(context.required_minutes / 60, 1),
            "provider": provider_used,
            "warnings": warnings,
        }

    def _serialize_free_slots(self, context) -> list[dict]:
        return [
            {"start": slot.start.isoformat(), "end": slot.end.isoformat()}
            for slot in context.free_slots
        ]

    def _store_pending(
        self,
        context,
        *,
        reasoning,
        items,
        meta,
        request: ScheduleGenerateRequest,
    ) -> AIRecommendation:
        recommendation = AIRecommendation(
            user_id=self.user_id,
            status=RecommendationStatus.pending,
            accepted=False,
            reasoning=reasoning,
            recommendation={
                "items": [_item_to_dict(block) for block in items],
                "meta": meta,
                "request": request.model_dump(mode="json"),
            },
        )
        self.db.add(recommendation)
        self.db.commit()
        self.db.refresh(recommendation)
        return recommendation

    def _store_failed(
        self,
        context,
        failure: str | None,
        *,
        request: ScheduleGenerateRequest,
    ) -> AIRecommendation:
        recommendation = AIRecommendation(
            user_id=self.user_id,
            status=RecommendationStatus.pending,
            accepted=False,
            reasoning="Schedule generation failed. The current schedule was "
            "preserved. Try generating again.",
            failure_reason=failure or "Unknown scheduling error",
            retry_at=datetime.now(_utc()) + timedelta(minutes=5),
            recommendation={
                "items": [],
                "meta": {
                    "overcommitted": False,
                    "risk": None,
                    "deferred_tasks": [],
                    "free_slots": self._serialize_free_slots(context),
                    "scheduleable_hours": round(
                        context.scheduleable_minutes / 60, 1
                    ),
                    "required_hours": round(context.required_minutes / 60, 1),
                    "provider": "failed",
                    "warnings": [],
                },
                "request": request.model_dump(mode="json"),
            },
        )
        self.db.add(recommendation)
        self.db.commit()
        self.db.refresh(recommendation)
        return recommendation

    def auto_regenerate(self, trigger: str = "schedule change") -> AIRecommendation | None:
        """Auto-regenerate a pending proposal and request user approval.

        Called when a task finishes early or a fixed event is added last-minute
        so the calendar stays fluid. The new proposal is stored as pending and
        must be approved via the normal accept flow.
        """
        try:
            request = None
            saved = self.db.scalars(
                select(AIRecommendation).where(AIRecommendation.user_id == self.user_id)
                .order_by(AIRecommendation.created_at.desc(), AIRecommendation.id.desc())
            )
            for recommendation in saved:
                stored = recommendation.recommendation or {}
                if not isinstance(stored, dict):
                    continue
                raw = stored.get("request")
                if not isinstance(raw, dict) or not {"timezone", "busy_times"} <= raw.keys():
                    continue
                try:
                    request = self._restore_request(stored)
                except (ValueError, TypeError, KeyError, RecommendationNotAcceptableError):
                    continue
                break
            if request is None:
                return None
            rec = self.generate(request)
            if rec and rec.reasoning and trigger:
                rec.reasoning = f"[Auto] {trigger}: " + rec.reasoning
                self.db.commit()
                self.db.refresh(rec)
            return rec
        except Exception:
            return None

    def _restore_request(self, stored: dict) -> ScheduleGenerateRequest:
        raw = stored.get("request")
        if not raw:
            raise RecommendationNotAcceptableError(
                "This proposal has no stored request data, so a single "
                "item cannot be regenerated. Generate a fresh proposal instead."
            )
        return ScheduleGenerateRequest.model_validate(raw)

    # ------------------------------------------------------------------
    # Recommendations lifecycle
    # ------------------------------------------------------------------
    def get_recommendation(
        self, recommendation_id: uuid.UUID, *, lock: bool = False
    ) -> AIRecommendation:
        statement = select(AIRecommendation).where(
            AIRecommendation.id == recommendation_id,
            AIRecommendation.user_id == self.user_id,
        )
        if lock:
            statement = statement.with_for_update().execution_options(
                populate_existing=True
            )
        recommendation = self.db.scalar(statement)
        if recommendation is None:
            raise RecommendationNotFoundError("Recommendation not found")
        return recommendation

    def list_recommendations(
        self, status: RecommendationStatus | None = None, limit: int = 50
    ) -> list[AIRecommendation]:
        statement = select(AIRecommendation).where(
            AIRecommendation.user_id == self.user_id
        )
        if status is not None:
            statement = statement.where(AIRecommendation.status == status)
        statement = statement.order_by(
            AIRecommendation.created_at.desc()
        ).limit(limit)
        return list(self.db.scalars(statement).all())

    def accept(
        self, recommendation_id: uuid.UUID
    ) -> tuple[AIRecommendation, list[CalendarBlock]]:
        recommendation = self.get_recommendation(recommendation_id, lock=True)
        if recommendation.status != RecommendationStatus.pending:
            raise RecommendationNotAcceptableError(
                "Only pending recommendations can be accepted"
            )
        items = copy.deepcopy((recommendation.recommendation or {}).get("items", []))
        if not items:
            raise RecommendationNotAcceptableError(
                "Recommendation has no schedule items to accept"
            )

        # If a task is being rescheduled (already had pending blocks), delete originals
        moving_task_ids = {
            uuid.UUID(item["task_id"]) for item in items if not item.get("accepted")
        }
        if moving_task_ids:
            old_blocks = list(
                self.db.scalars(
                    select(CalendarBlock).where(
                        CalendarBlock.user_id == self.user_id,
                        CalendarBlock.task_id.in_(moving_task_ids),
                        CalendarBlock.completed_at.is_(None),
                    )
                ).all()
            )
            self._delete_replaced_blocks(old_blocks, items)
            self.db.flush()

        blocks: list[CalendarBlock] = []
        for item in items:
            if item.get("accepted"):
                continue
            block = CalendarBlock(
                user_id=self.user_id,
                task_id=uuid.UUID(item["task_id"]),
                title=item["task_title"],
                start_at=_parse(item["start"]),
                end_at=_parse(item["end"]),
            )
            self.db.add(block)
            self.db.flush()
            item["block_id"] = str(block.id)
            blocks.append(block)
            item["accepted"] = True

        stored = copy.deepcopy(recommendation.recommendation or {})
        stored["items"] = items
        recommendation.recommendation = stored
        recommendation.status = RecommendationStatus.accepted
        recommendation.accepted = True
        self.db.flush()
        self.db.commit()
        for block in blocks:
            self.db.refresh(block)
        self.db.refresh(recommendation)
        return recommendation, blocks

    def _delete_replaced_blocks(
        self, blocks: list[CalendarBlock], items: list[dict]
    ) -> None:
        accepted = [item for item in items if item.get("accepted")]
        for block in blocks:
            # Older persisted proposals lack block IDs; match their accepted windows.
            keep = any(
                str(block.id) == item["block_id"]
                if item.get("block_id")
                else (
                    str(block.task_id) == item["task_id"]
                    and block.start_at == _parse(item["start"])
                    and block.end_at == _parse(item["end"])
                )
                for item in accepted
            )
            if not keep:
                self.db.delete(block)

    def reject(self, recommendation_id: uuid.UUID) -> AIRecommendation:
        recommendation = self.get_recommendation(recommendation_id, lock=True)
        if recommendation.status != RecommendationStatus.pending:
            raise RecommendationNotAcceptableError(
                "Only pending recommendations can be rejected"
            )
        recommendation.status = RecommendationStatus.rejected
        recommendation.accepted = False
        self.db.commit()
        self.db.refresh(recommendation)
        return recommendation

    def accept_item(
        self, recommendation_id: uuid.UUID, item_index: int
    ) -> tuple[AIRecommendation, list[CalendarBlock]]:
        recommendation = self.get_recommendation(recommendation_id, lock=True)
        if recommendation.status != RecommendationStatus.pending:
            raise RecommendationNotAcceptableError(
                "Only pending recommendations can be approved"
            )
        items = copy.deepcopy((recommendation.recommendation or {}).get("items", []))
        if not 0 <= item_index < len(items):
            raise RecommendationNotAcceptableError(
                "Proposed item not found"
            )
        item = items[item_index]
        if item.get("accepted"):
            raise RecommendationNotAcceptableError(
                "This item has already been approved"
            )

        # If this task already had pending blocks (being moved), delete originals
        moving_id = uuid.UUID(item["task_id"])
        old_blocks = list(
            self.db.scalars(
                select(CalendarBlock).where(
                    CalendarBlock.user_id == self.user_id,
                    CalendarBlock.task_id == moving_id,
                    CalendarBlock.completed_at.is_(None),
                )
            ).all()
        )
        self._delete_replaced_blocks(old_blocks, items)
        self.db.flush()

        block = CalendarBlock(
            user_id=self.user_id,
            task_id=uuid.UUID(item["task_id"]),
            title=item["task_title"],
            start_at=_parse(item["start"]),
            end_at=_parse(item["end"]),
        )
        self.db.add(block)
        self.db.flush()
        item["block_id"] = str(block.id)
        item["accepted"] = True
        stored = copy.deepcopy(recommendation.recommendation or {})
        stored["items"] = items
        recommendation.recommendation = stored
        if all(entry.get("accepted") for entry in items):
            recommendation.status = RecommendationStatus.accepted
            recommendation.accepted = True
        self.db.flush()
        self.db.commit()
        self.db.refresh(block)
        self.db.refresh(recommendation)
        return recommendation, [block]

    def redo_item(
        self, recommendation_id: uuid.UUID, item_index: int
    ) -> AIRecommendation:
        recommendation = self.get_recommendation(recommendation_id, lock=True)
        if recommendation.status != RecommendationStatus.pending:
            raise RecommendationNotAcceptableError(
                "Only pending recommendations can be regenerated"
            )
        stored = copy.deepcopy(recommendation.recommendation or {})
        items = stored.get("items", [])
        if not 0 <= item_index < len(items):
            raise RecommendationNotAcceptableError("Proposed item not found")

        target_id = uuid.UUID(items[item_index]["task_id"])
        if any(
            entry.get("accepted")
            for entry in items
            if entry["task_id"] == str(target_id)
        ):
            raise RecommendationNotAcceptableError(
                "Approved items cannot be regenerated. Redo a proposal item "
                "before approving it."
            )
        request = self._restore_request(stored)
        task = self.db.scalar(
            select(Task).where(
                Task.id == target_id,
                Task.user_id == self.user_id,
            )
        )
        if task is None:
            raise RecommendationNotFoundError("Task not found")
        preference = self._preferences()

        # For redo, only the specific chunk being redone is forced to move (its old time as busy),
        # other chunks for same task remain free so the whole task can be rescheduled with correct chunking.
        # This ensures a task broken into 2 still reschedules as 2, not 1, and the new time is actually different.
        redo_request = ScheduleGenerateRequest(
            start_date=request.start_date,
            end_date=request.end_date,
            timezone=request.timezone,
            busy_times=[
                *request.busy_times,
                *[
                    BusyTime(start=_parse(entry["start"]), end=_parse(entry["end"]))
                    for idx, entry in enumerate(items)
                    if entry["task_id"] != str(target_id) or idx == item_index
                ],
            ],
            task_ids=[target_id],
        )
        redo_context = self._build_context([task], preference, redo_request)

        result = None
        provider_used = "gemini"
        if settings.gemini_api_key:
            try:
                result = self.provider.generate_schedule(
                    redo_context, build_prompt(redo_context)
                )
                if not validate_schedule(result.items, redo_context, strict_availability=True).is_valid:
                    result = None
            except (ProviderError, ValueError, TypeError, AttributeError):
                result = None
        if result is None:
            provider_used = "heuristic_fallback"
            try:
                result = self.heuristic.generate_schedule(
                    redo_context, build_prompt(redo_context)
                )
                if not validate_schedule(result.items, redo_context, strict_availability=True).is_valid:
                    result = None
            except Exception as exc:  # pragma: no cover - defensive
                result = None

        new_blocks = (
            [block for block in result.items if block.task_id == target_id]
            if result is not None
            else []
        )
        if not new_blocks:
            note = (
                "Could not find a better slot for this task; the original "
                "proposal was kept."
            )
            recommendation.reasoning = "\n".join(
                part for part in [recommendation.reasoning, note] if part
            )
            self.db.commit()
            self.db.refresh(recommendation)
            return recommendation

        replaced = [
            entry for entry in items if entry["task_id"] != str(target_id)
        ]
        first_index = next(
            (
                index
                for index, entry in enumerate(items)
                if entry["task_id"] == str(target_id)
            ),
            0,
        )
        fresh_items = [_item_to_dict(block) for block in new_blocks]
        replaced[first_index:first_index] = fresh_items

        full_context = self._build_context(
            self._active_tasks(request.task_ids), preference, request
        )
        full_result = ProviderResult(
            items=[
                ProposedBlock(
                    task_id=uuid.UUID(entry["task_id"]),
                    task_title=entry["task_title"],
                    start=_parse(entry["start"]),
                    end=_parse(entry["end"]),
                    reason=entry.get("reason", ""),
                )
                for entry in replaced
                if not entry.get("accepted")
            ],
            reasoning=result.reasoning,
        )
        validation = validate_schedule(full_result.items, full_context, strict_availability=True)
        if not validation.is_valid:
            self.db.commit()
            self.db.refresh(recommendation)
            return recommendation
        meta = self._build_meta(full_context, full_result, validation, provider_used)

        stored["items"] = replaced
        stored["meta"] = meta
        recommendation.recommendation = stored
        recommendation.reasoning = result.reasoning or recommendation.reasoning
        self.db.commit()
        self.db.refresh(recommendation)
        return recommendation
