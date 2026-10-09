import json
import math
from datetime import date
from datetime import datetime
from datetime import time
from datetime import timedelta
from typing import Protocol
from uuid import UUID
from zoneinfo import ZoneInfo

import httpx

from app.core.config import settings
from app.models.task import TaskPriority
from app.services.scheduling.context import ProposedBlock
from app.services.scheduling.context import ProviderResult
from app.services.scheduling.context import SchedulingContext
from app.services.scheduling.context import TimeSlot

PRIORITY_RANK = {
    TaskPriority.low: 0,
    TaskPriority.medium: 1,
    TaskPriority.high: 2,
}


class ProviderError(Exception):
    pass


class AIProvider(Protocol):
    def generate_schedule(
        self, context: SchedulingContext, prompt: str
    ) -> ProviderResult:
        """Return a proposed schedule for the given context."""
        ...


def default_provider() -> AIProvider:
    if settings.gemini_api_key:
        return GeminiProvider()
    return HeuristicProvider()


def _parse_datetime(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=ZoneInfo("UTC"))
    return parsed


class GeminiProvider:
    """Calls the Gemini generateContent REST API."""

    BASE_URL = "https://generativelanguage.googleapis.com/v1beta"

    def __init__(
        self,
        api_key: str | None = None,
        model: str | None = None,
        timeout: float = 45.0,
    ) -> None:
        self.api_key = api_key or settings.gemini_api_key
        self.model = model or settings.gemini_chat_model
        self.timeout = timeout

    def generate_schedule(
        self, context: SchedulingContext, prompt: str
    ) -> ProviderResult:
        if not self.api_key:
            raise ProviderError("Gemini API key is not configured")

        try:
            response = httpx.post(
                f"{self.BASE_URL}/models/{self.model}:generateContent",
                headers={"x-goog-api-key": self.api_key},
                json={
                    "contents": [
                        {"role": "user", "parts": [{"text": prompt}]}
                    ],
                    "generationConfig": {
                        "responseMimeType": "application/json",
                        "temperature": 0.2,
                    },
                },
                timeout=self.timeout,
            )
            response.raise_for_status()
            payload = response.json()
            text = (
                payload.get("candidates", [{}])[0]
                .get("content", {})
                .get("parts", [{}])[0]
                .get("text", "")
            )
            if not text:
                raise ProviderError("Gemini returned an empty response")
            return self._parse_output(text)
        except httpx.HTTPStatusError as exc:
            raise ProviderError(
                f"Gemini request failed (HTTP {exc.response.status_code})"
            ) from None
        except httpx.HTTPError:
            raise ProviderError("Gemini request failed") from None
        except (KeyError, IndexError, TypeError, ValueError, AttributeError):
            raise ProviderError("Could not parse Gemini response") from None

    def _parse_output(self, text: str) -> ProviderResult:
        try:
            data = json.loads(text)
            if not isinstance(data, dict) or not isinstance(data.get("items"), list):
                raise ProviderError("Gemini output must contain an items array")
            if not isinstance(data.get("reasoning", ""), str):
                raise ProviderError("Gemini output reasoning must be text")
            items = []
            for entry in data["items"]:
                if not isinstance(entry, dict):
                    raise ProviderError("Gemini output item must be an object")
                if any(
                    not isinstance(entry.get(key, ""), str)
                    for key in ("task_title", "reason")
                ):
                    raise ProviderError("Gemini output item labels must be text")
                task_id = entry.get("task_id")
                if not task_id:
                    raise ProviderError("Gemini output item missing task_id")
                items.append(
                    ProposedBlock(
                        task_id=UUID(task_id),
                        task_title=entry.get("task_title", ""),
                        start=_parse_datetime(entry["start"]),
                        end=_parse_datetime(entry["end"]),
                        reason=entry.get("reason", ""),
                    )
                )
            return ProviderResult(items=items, reasoning=data.get("reasoning", ""))
        except (KeyError, TypeError, ValueError, AttributeError):
            raise ProviderError("Could not parse Gemini response") from None


class HeuristicProvider:
    """Deterministic fallback scheduler: first-fit by deadline (priority removed per user).

    This keeps the product working when no Gemini key is configured or when
    the model is unavailable, and doubles as a deterministic test double.
    """

    def generate_schedule(
        self, context: SchedulingContext, prompt: str
    ) -> ProviderResult:
        fixed_tasks = [task for task in context.tasks if task.is_fixed]
        # Priority removed: sort purely by deadline (overdue first, then earliest deadline)
        def _weighted_key(task):
            if task.deadline is None:
                eff = datetime.max.replace(tzinfo=ZoneInfo("UTC"))
                is_none = True
            else:
                eff = task.deadline
                is_none = False
            return (not task.is_overdue, is_none, eff)

        flexible = sorted(
            (task for task in context.tasks if not task.is_fixed),
            key=_weighted_key,
        )

        available = list(context.free_slots)
        blocks: list[ProposedBlock] = []
        deferred: list[str] = []
        self._buffer = context.buffer_minutes
        self._max_chunk = context.max_chunk_minutes
        self._max_daily = context.max_daily_hours * 60
        self._tz = ZoneInfo(context.timezone)
        day_used = dict(context.committed_minutes_by_day)

        for task in fixed_tasks:
            placement = self._place_fixed_task(task, available)
            if placement is None:
                deferred.append(task.title)
                continue
            placed, remaining = placement
            blocks.extend(placed)
            available = remaining
            for block in placed:
                cursor = block.start.astimezone(self._tz)
                end = block.end.astimezone(self._tz)
                while cursor < end:
                    day = cursor.date()
                    day_end = datetime.combine(day + timedelta(days=1), time(), tzinfo=self._tz)
                    segment_end = min(end, day_end)
                    minutes = int((segment_end - cursor).total_seconds() // 60)
                    day_used[day] = day_used.get(day, 0) + minutes
                    cursor = segment_end

        for task in flexible:
            placement = self._place_task(task, available, day_used)
            if placement is None:
                deferred.append(task.title)
                continue
            placed, remaining = placement
            blocks.extend(placed)
            available = remaining

        scheduled_ids = {block.task_id for block in blocks}
        total_count = len(context.tasks)
        scheduled_count = len(scheduled_ids)
        if scheduled_count == total_count:
            summary = (
                f"Scheduled all {total_count} task(s) into the available time, "
                f"keeping a {context.buffer_minutes} minute buffer between blocks."
            )
        else:
            summary = (
                f"Scheduled {scheduled_count} of {total_count} task(s). "
                f"{len(deferred)} task(s) could not fit and were deferred: "
                f"{', '.join(deferred)}."
            )
        return ProviderResult(items=blocks, reasoning=summary)

    def _place_fixed_task(
        self,
        task,
        available: list[TimeSlot],
    ) -> tuple[list[ProposedBlock], list[TimeSlot]] | None:
        window = TimeSlot(task.start_at, task.end_at)
        if window.end <= window.start:
            return None
        if task.deadline is not None and window.end > task.deadline:
            return None
        for index, slot in enumerate(available):
            if slot.start <= window.start and window.end <= slot.end:
                blocks = [
                    ProposedBlock(
                        task_id=task.id,
                        task_title=task.title,
                        start=window.start,
                        end=window.end,
                        reason="fixed event, scheduled at its exact window",
                    )
                ]
                remaining = list(available)
                carved: list[TimeSlot] = []
                if slot.start < window.start:
                    carved.append(TimeSlot(slot.start, window.start))
                if window.end < slot.end:
                    carved.append(TimeSlot(window.end, slot.end))
                remaining[index:index + 1] = carved
                remaining.sort(key=lambda slot: (slot.start, slot.end))
                return blocks, remaining
        # Fluid: if no free slot fully contains the fixed window, still schedule it
        # at its exact window with a warning (overlaps busy). Carve any overlapping slots.
        blocks = [
            ProposedBlock(
                task_id=task.id,
                task_title=task.title,
                start=window.start,
                end=window.end,
                reason="fixed event, scheduled at its exact window (overlaps busy time - fluid schedule)",
            )
        ]
        remaining: list[TimeSlot] = []
        for slot in available:
            if slot.end <= window.start or slot.start >= window.end:
                remaining.append(slot)
            else:
                if slot.start < window.start:
                    remaining.append(TimeSlot(slot.start, window.start))
                if window.end < slot.end:
                    remaining.append(TimeSlot(window.end, slot.end))
        remaining.sort(key=lambda slot: (slot.start, slot.end))
        return blocks, remaining

    def _place_task(
        self,
        task,
        available: list[TimeSlot],
        day_used: dict[date, int],
    ) -> tuple[list[ProposedBlock], list[TimeSlot]] | None:
        duration = task.duration_minutes
        deadline = task.deadline
        max_chunk = self._max_chunk_minutes()
        max_daily = self._daily_cap_minutes()
        remaining_slots = list(available)
        blocks: list[ProposedBlock] = []
        remaining_duration = duration
        total_parts = max(1, math.ceil(duration / max_chunk))

        while remaining_duration > 0:
            placed_in_this_pass = False
            for index, slot in enumerate(remaining_slots):
                day = slot.start.astimezone(self._tz).date()
                daily_remaining = max_daily - day_used.get(day, 0)
                if daily_remaining <= 0:
                    continue
                chunk = min(remaining_duration, max_chunk, daily_remaining)
                if slot.duration_minutes < chunk:
                    continue
                if (
                    deadline is not None
                    and not task.is_overdue
                    and slot.start + timedelta(minutes=chunk) > deadline
                ):
                    continue
                part = len(blocks) + 1
                title = f"{task.title} (Part {part}/{total_parts})" if total_parts > 1 else task.title
                blocks.append(
                    ProposedBlock(
                        task_id=task.id,
                        task_title=title,
                        start=slot.start,
                        end=slot.start + timedelta(minutes=chunk),
                        reason=self._reason_for(task, slot.start, part, total_parts),
                    )
                )
                remaining_duration -= chunk
                day_used[day] = day_used.get(day, 0) + chunk
                after = slot.start + timedelta(
                    minutes=chunk + self._buffer_minutes()
                )
                if after < slot.end:
                    remaining_slots[index] = TimeSlot(after, slot.end)
                else:
                    del remaining_slots[index]
                remaining_slots.sort(key=lambda slot: (slot.start, slot.end))
                placed_in_this_pass = True
                break
            if not placed_in_this_pass:
                break

        if not blocks:
            return None
        return blocks, remaining_slots

    def _buffer_minutes(self) -> int:
        return getattr(self, "_buffer", 0)

    def _max_chunk_minutes(self) -> int:
        return getattr(self, "_max_chunk", 90)

    def _daily_cap_minutes(self) -> int:
        return getattr(self, "_max_daily", 480)

    def _reason_for(
        self, task, start: datetime, part: int = 1, total_parts: int = 1
    ) -> str:
        reasons = []
        if task.is_overdue:
            reasons.append("overdue, scheduled ASAP")
        if task.deadline is not None and not task.is_overdue:
            reasons.append(
                f"deadline {task.deadline.date().isoformat()}, scheduled before it"
            )
        if not reasons:
            reasons.append("first available slot")
        reason = (
            f"Scheduled at {start.strftime('%a %H:%M')} due to "
            f"{' and '.join(reasons)}"
        )
        if total_parts > 1:
            reason = f"{reason} (part {part} of {total_parts})"
        return reason
