import uuid
from datetime import date
from datetime import datetime
from zoneinfo import ZoneInfo
from zoneinfo import ZoneInfoNotFoundError

from pydantic import BaseModel
from pydantic import Field
from pydantic import field_validator
from pydantic import model_validator

from app.models.task import TaskPriority
from app.schemas.calendar import BusyTime

MAX_RECOMMENDATION_DAYS = 366


class DailyRecommendationsRequest(BaseModel):
    timezone: str = "UTC"
    # Accepts full ISO datetimes (e.g. "2026-08-22T07:00:00Z" from iOS's
    # ISO8601 JSONEncoder) as well as plain "2026-08-22" dates.
    start_date: datetime | date | None = None
    end_date: datetime | date | None = None
    busy_times: list[BusyTime] = Field(default_factory=list)

    @field_validator("timezone")
    @classmethod
    def valid_timezone(cls, value: str) -> str:
        try:
            ZoneInfo(value)
        except (ZoneInfoNotFoundError, ValueError) as exc:
            raise ValueError("Invalid timezone") from exc
        return value

    @model_validator(mode="after")
    def local_calendar_dates(self):
        tz = ZoneInfo(self.timezone)
        for field in ("start_date", "end_date"):
            value = getattr(self, field)
            if isinstance(value, datetime):
                if value.tzinfo is not None:
                    value = value.astimezone(tz)
                setattr(self, field, value.date())
        if self.start_date is not None and self.end_date is not None:
            span = (self.end_date - self.start_date).days + 1
            if not 1 <= span <= MAX_RECOMMENDATION_DAYS:
                raise ValueError(
                    f"Recommendation range must be 1-{MAX_RECOMMENDATION_DAYS} days"
                )
        return self


class RecommendedPart(BaseModel):
    task_id: uuid.UUID
    task_title: str
    part_title: str | None
    part_index: int
    part_count: int
    minutes: int
    priority: TaskPriority
    category: str | None = None
    deadline: datetime | None = None
    is_overdue: bool = False
    reason: str = ""
    start_at: datetime | None = None
    end_at: datetime | None = None


class UnscheduledPart(BaseModel):
    task_id: uuid.UUID
    task_title: str
    part_title: str | None
    minutes: int
    priority: TaskPriority
    category: str | None = None


class DayRecommendation(BaseModel):
    date: date
    available_minutes: int
    items: list[RecommendedPart]


class DailyRecommendationsResponse(BaseModel):
    days: list[DayRecommendation]
    unscheduled: list[UnscheduledPart]


class BreakdownPart(BaseModel):
    index: int
    title: str
    minutes: int


class BreakdownResponse(BaseModel):
    task_id: uuid.UUID
    task_title: str
    parts: list[BreakdownPart]
    source: str
