"""Text-analysis providers for focus sessions and end-of-day reflections.

Mirrors the same structure as the scheduling providers: a Gemini REST
implementation that is used when an API key is configured, and a
deterministic heuristic fallback so the feature works offline (and in tests
when no key is available).
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from datetime import datetime
from datetime import time as dt_time
from datetime import timedelta
from typing import Protocol
from zoneinfo import ZoneInfo

import httpx

from app.core.config import settings
from app.models.task import TaskPriority


@dataclass(frozen=True)
class AnalysisResult:
    """The outcome of analyzing a reflection or a focus session.

    ``insight`` is a human-readable summary paragraph. ``tags`` are short
    keywords (for example "overwhelm", "unblocked", "procrastination")
    that the iOS side can reuse for charts and labels.
    """

    insight: str
    tags: list[str]


@dataclass(frozen=True)
class ParsedTask:
    """Structured fields extracted from a natural-language task string."""

    title: str
    description: str | None = None
    deadline: datetime | None = None
    estimated_duration: int | None = None
    priority: TaskPriority | None = None
    category: str | None = None
    notes: str | None = None


class TextAnalysisError(Exception):
    """Raised when an analysis provider fails."""


class TextAnalysisProvider(Protocol):
    def analyze_text(self, text: str) -> AnalysisResult:
        """Return a short analysis for the given free-form text."""
        ...

    def morning_message(self, reflection_text: str) -> str:
        """Return a warm, short good-morning message inspired by the previous
        evening's reflection."""
        ...


class TaskTextParser(Protocol):
    def parse_task(self, text: str, timezone: str) -> ParsedTask:
        """Extract structured task fields from a natural-language string."""
        ...


def default_analysis_provider() -> TextAnalysisProvider:
    if settings.gemini_api_key:
        return GeminiTextAnalysisProvider()
    return HeuristicTextAnalysisProvider()


def default_task_parser() -> TaskTextParser:
    if settings.gemini_api_key:
        return GeminiTextAnalysisProvider()
    return HeuristicTextAnalysisProvider()


class GeminiTextAnalysisProvider:
    """Calls the Gemini generateContent REST API for free-form text."""

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

    def analyze_text(self, text: str) -> AnalysisResult:
        if not self.api_key:
            raise TextAnalysisError("Gemini API key is not configured")

        prompt = (
            "You help a busy professional reflect on their day. Given the "
            "free-form reflection below, produce a JSON object with exactly "
            'two keys: "insight" (a 1-3 sentence encouraging, concrete '
            'observation) and "tags" (an array of 1-4 short lowercase '
            'keywords such as "productive", "overwhelm", "distracted", '
            '"planning win"). No other text.\n\nReflection:\n'
            f"{text}"
        )
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
                        "temperature": 0.4,
                    },
                },
                timeout=self.timeout,
            )
            response.raise_for_status()
            payload = response.json()
            raw = (
                payload.get("candidates", [{}])[0]
                .get("content", {})
                .get("parts", [{}])[0]
                .get("text", "")
            )
            if not raw:
                raise TextAnalysisError("Gemini returned an empty response")
            data = json.loads(raw)
            if (
                not isinstance(data, dict)
                or not isinstance(data.get("insight", ""), str)
                or not isinstance(data.get("tags", []), list)
                or any(not isinstance(tag, str) for tag in data.get("tags", []))
            ):
                raise TextAnalysisError("Invalid Gemini analysis response")
            return AnalysisResult(
                insight=str(data.get("insight", "")).strip()
                or "No insight returned.",
                tags=[
                    str(tag).strip().lower()
                    for tag in data.get("tags", [])
                    if str(tag).strip()
                ],
            )
        except httpx.HTTPStatusError as exc:
            raise TextAnalysisError(
                f"Gemini request failed (HTTP {exc.response.status_code})"
            ) from None
        except httpx.HTTPError:
            raise TextAnalysisError("Gemini request failed") from None
        except (KeyError, IndexError, TypeError, ValueError, AttributeError):
            raise TextAnalysisError("Could not parse Gemini response") from None

    def parse_task(self, text: str, timezone: str = "UTC") -> ParsedTask:
        if not self.api_key:
            raise TextAnalysisError("Gemini API key is not configured")

        try:
            tz = ZoneInfo(timezone)
            now = datetime.now(tz)
            now_text = now.strftime("%Y-%m-%d %H:%M %Z")
        except Exception:
            now = datetime.utcnow()
            now_text = now.strftime("%Y-%m-%d %H:%M UTC")

        prompt = (
            "You convert a busy person's natural-language task note into a "
            "structured task. Given the note below and the current local time "
            f"({now_text}), produce a JSON object with exactly these keys:\n"
            '- "title": a short task title (required).\n'
            '- "description": a fuller description, or null.\n'
            '- "deadline": an ISO-8601 datetime if the note implies one '
            '("by tomorrow 9pm", "due friday", "end of the week"), else null.\n'
            '- "estimated_duration": minutes as an integer if the note implies '
            'a duration ("an hour", "should take 30 mins"), else null.\n'
            '- "priority": "high", "medium" or "low", or null.\n'
            '- "category": a short category label like "Work"/"Study"/"Home" '
            "if inferable, else null.\n"
            '- "notes": any extra context worth keeping, else null.\n'
            "Use the given timezone for relative deadlines. No other text.\n\n"
            f"Task note:\n{text}"
        )
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
            raw = (
                payload.get("candidates", [{}])[0]
                .get("content", {})
                .get("parts", [{}])[0]
                .get("text", "")
            )
            if not raw:
                raise TextAnalysisError("Gemini returned an empty response")
            data = json.loads(raw)
            return self._parsed_task(data)
        except httpx.HTTPStatusError as exc:
            raise TextAnalysisError(
                f"Gemini request failed (HTTP {exc.response.status_code})"
            ) from None
        except httpx.HTTPError:
            raise TextAnalysisError("Gemini request failed") from None
        except (KeyError, IndexError, TypeError, ValueError, AttributeError):
            raise TextAnalysisError("Could not parse Gemini response") from None

    def morning_message(self, reflection_text: str) -> str:
        if not self.api_key:
            raise TextAnalysisError("Gemini API key is not configured")

        prompt = (
            "You help a busy professional start their day. Given their "
            "end-of-day reflection from yesterday, write a short, warm "
            "good-morning message (1-2 sentences) that turns what they "
            "shared into a concrete motivation for the day ahead. Keep it "
            "specific, kind, and actionable. Produce a JSON object with "
            'exactly one key: "message". No other text.\n\nYesterday\'s '
            f"reflection:\n{reflection_text}"
        )
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
                        "temperature": 0.7,
                    },
                },
                timeout=self.timeout,
            )
            response.raise_for_status()
            payload = response.json()
            raw = (
                payload.get("candidates", [{}])[0]
                .get("content", {})
                .get("parts", [{}])[0]
                .get("text", "")
            )
            if not raw:
                raise TextAnalysisError("Gemini returned an empty response")
            data = json.loads(raw)
            if not isinstance(data, dict) or not isinstance(data.get("message", ""), str):
                raise TextAnalysisError("Invalid Gemini morning message response")
            message = str(data.get("message", "")).strip()
            return message or "Good morning — make today count."
        except httpx.HTTPStatusError as exc:
            raise TextAnalysisError(
                f"Gemini request failed (HTTP {exc.response.status_code})"
            ) from None
        except httpx.HTTPError:
            raise TextAnalysisError("Gemini request failed") from None
        except (KeyError, IndexError, TypeError, ValueError, AttributeError):
            raise TextAnalysisError("Could not parse Gemini response") from None

    def _parsed_task(self, data: dict) -> ParsedTask:
        if not isinstance(data, dict):
            raise TextAnalysisError("Gemini task response must be an object")
        for key in ("title", "description", "deadline", "priority", "category", "notes"):
            if data.get(key) is not None and not isinstance(data[key], str):
                raise TextAnalysisError("Gemini task fields must be text")
        duration = data.get("estimated_duration")
        if duration is not None and (isinstance(duration, bool) or not isinstance(duration, (int, float, str))):
            raise TextAnalysisError("Invalid Gemini task duration")
        raw_title = str(data.get("title", "")).strip()
        title = raw_title or "Untitled task"
        deadline_raw = data.get("deadline")
        deadline: datetime | None = None
        if deadline_raw:
            try:
                parsed = datetime.fromisoformat(
                    str(deadline_raw).replace("Z", "+00:00")
                )
                if parsed.tzinfo is None:
                    parsed = parsed.replace(tzinfo=ZoneInfo("UTC"))
                deadline = parsed
            except ValueError:
                raise TextAnalysisError("Invalid Gemini task deadline") from None
        duration = data.get("estimated_duration")
        estimated_duration = (
            int(duration) if isinstance(duration, (int, float, str)) and str(duration).strip().lstrip("-").isdigit() else None
        )
        if estimated_duration is not None and estimated_duration <= 0:
            estimated_duration = None
        priority_raw = str(data.get("priority", "")).strip().lower()
        priority = (
            TaskPriority(priority_raw)
            if priority_raw in {p.value for p in TaskPriority}
            else None
        )
        return ParsedTask(
            title=title,
            description=_clean_optional(data.get("description")),
            deadline=deadline,
            estimated_duration=estimated_duration,
            priority=priority,
            category=_clean_optional(data.get("category")),
            notes=_clean_optional(data.get("notes")),
        )


def _clean_optional(value: object) -> str | None:
    if value is None:
        return None
    cleaned = str(value).strip()
    return cleaned or None


class HeuristicTextAnalysisProvider:
    """Deterministic fallback that works without any API key."""

    POSITIVE = {
        "done",
        "finished",
        "completed",
        "focused",
        "proud",
        "win",
        "great",
        "good",
        "progress",
        "unblocked",
        "flow",
    }
    NEGATIVE = {
        "overwhel",
        "chaos",
        "distracted",
        "procrastinat",
        "stuck",
        "stressed",
        "behind",
        "missed",
        "exhausted",
        "cancelled",
        "delayed",
    }

    def analyze_text(self, text: str) -> AnalysisResult:
        lowered = text.lower()
        hits_pos = sum(1 for word in self.POSITIVE if word in lowered)
        hits_neg = sum(1 for word in self.NEGATIVE if word in lowered)

        tags: list[str] = []
        if hits_pos > hits_neg:
            tags.append("productive")
            insight = (
                "A good day: you got meaningful work done and can carry this "
                "momentum into tomorrow."
            )
        elif hits_neg > hits_pos:
            tags.append("overwhelm")
            insight = (
                "A heavy day. Pick the single most important task tomorrow "
                "and lower your expectations elsewhere."
            )
        else:
            insight = (
                "A steady day. Restating what went well and what to improve "
                "makes tomorrow more intentional."
            )
        return AnalysisResult(insight=insight, tags=tags)

    def morning_message(self, reflection_text: str) -> str:
        lowered = reflection_text.lower()
        hits_pos = sum(1 for word in self.POSITIVE if word in lowered)
        hits_neg = sum(1 for word in self.NEGATIVE if word in lowered)

        if hits_pos > hits_neg:
            return (
                "Good morning. Yesterday ended with real momentum — carry it "
                "into today by starting with your most meaningful task."
            )
        if hits_neg > hits_pos:
            return (
                "Good morning. Yesterday was heavy, so today give yourself a "
                "small win first — one task done early will change the whole day."
            )
        return (
            "Good morning. A steady day behind you is a solid start — pick one "
            "intention for today and protect the focus time to make it real."
        )

    def parse_task(self, text: str, timezone: str = "UTC") -> ParsedTask:
        cleaned = re.sub(r"\s+", " ", text).strip()
        if not cleaned:
            raise TextAnalysisError("Nothing to parse")

        try:
            tz = ZoneInfo(timezone)
            now = datetime.now(tz)
        except Exception:
            tz = ZoneInfo("UTC")
            now = datetime.now(tz)

        lower = cleaned.lower()

        deadline = self._extract_deadline(cleaned, lower, now, tz)
        estimated_duration = self._extract_duration(lower)
        priority: TaskPriority | None = None
        if any(word in lower for word in ("urgent", "asap", "high priority", "important")):
            priority = TaskPriority.high
        elif any(word in lower for word in ("low priority", "when i can", "no rush")):
            priority = TaskPriority.low

        title = self._extract_title(cleaned)

        return ParsedTask(
            title=title,
            description=cleaned if len(cleaned) > len(title) else None,
            deadline=deadline,
            estimated_duration=estimated_duration,
            priority=priority,
            notes=cleaned,
        )

    def _extract_title(self, text: str) -> str:
        split_markers = re.split(
            r"\s*,|\s+should take|\s+by\s+\d| by | due |\s+duration", text, maxsplit=1
        )
        title = split_markers[0].strip().strip(".,;:")
        return title[:255] or "Untitled task"

    def _extract_duration(self, lower: str) -> int | None:
        if "an hour" in lower or "a hour" in lower:
            return 60
        if "half an hour" in lower:
            return 30
        if "quarter hour" in lower:
            return 15
        match = re.search(r"(?:should take|takes|approx(?:imately)?|about)?\s*(\d+(?:\.\d+)?)\s*(?:hrs?|hours?|hr|h|mins?|minutes?)", lower)
        if not match:
            return None
        value = float(match.group(1))
        unit_text = match.group(0)
        minutes = value * 60 if re.search(r"hr", unit_text) else value
        minutes = int(round(minutes))
        return minutes if 1 <= minutes <= 525600 else None

    def _extract_deadline(
        self, text: str, lower: str, now: datetime, tz: ZoneInfo
    ) -> datetime | None:
        match = re.search(
            r"(?:by|due|before)\s+(.*?)(?:[.,;]|$)", lower, re.IGNORECASE
        )
        if not match:
            return None
        expr = match.group(1).strip()

        days_ahead = 0
        if "tomorrow" in expr:
            days_ahead = 1
        elif "tonight" in expr or "today" in expr:
            days_ahead = 0
        time_match = re.search(r"(\d{1,2})(?::(\d{2}))?\s*(am|pm|AM|PM)?", expr)
        if not time_match:
            if days_ahead == 0 and any(w in expr for w in ("today", "tonight")):
                return None
            target = (now + timedelta(days=days_ahead)).replace(hour=0, minute=0, second=0, microsecond=0)
            return target if target > now else None

        hour = int(time_match.group(1))
        minute = int(time_match.group(2) or 0)
        meridiem = time_match.group(3)
        if meridiem:
            meridiem = meridiem.lower()
            if meridiem == "pm" and hour < 12:
                hour += 12
            elif meridiem == "am" and hour == 12:
                hour = 0
        elif hour < 8:
            hour = 12 if "noon" in expr else hour
        target = (now + timedelta(days=days_ahead)).replace(
            hour=hour, minute=minute, second=0, microsecond=0
        )
        return target if target > now else None
