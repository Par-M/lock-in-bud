import uuid
from datetime import date
from datetime import datetime
from zoneinfo import ZoneInfo

from pydantic import BaseModel
from pydantic import Field
from pydantic import field_validator
from pydantic import model_validator

from app.models.ai_recommendation import AIRecommendation
from app.models.ai_recommendation import RecommendationStatus
from app.schemas.calendar import BusyTime
from app.schemas.calendar import CalendarBlockResponse
from app.schemas.calendar import TimeSlot


class ScheduleGenerateRequest(BaseModel):
    start_date: date
    end_date: date
    timezone: str = "UTC"
    busy_times: list[BusyTime] = Field(default_factory=list)
    task_ids: list[uuid.UUID] | None = None

    @model_validator(mode="before")
    @classmethod
    def parse_dates(cls, values):
        if not isinstance(values, dict):
            return values
        values = dict(values)
        try:
            tz = ZoneInfo(values.get("timezone", "UTC"))
        except Exception as exc:
            raise ValueError("Invalid IANA timezone") from exc
        for key in ("start_date", "end_date"):
            value = values.get(key)
            if isinstance(value, str):
                try:
                    values[key] = date.fromisoformat(value)
                    continue
                except ValueError:
                    pass
                try:
                    value = datetime.fromisoformat(value.replace("Z", "+00:00"))
                except ValueError as exc:
                    raise ValueError(
                        "Invalid date; expected YYYY-MM-DD or an ISO8601 datetime"
                    ) from exc
            if isinstance(value, datetime):
                values[key] = (
                    value.astimezone(tz).date() if value.tzinfo else value.date()
                )
        return values

    @model_validator(mode="after")
    def validate_dates(self):
        if self.end_date < self.start_date:
            raise ValueError("end_date must be on or after start_date")
        return self

    @field_validator("timezone")
    @classmethod
    def valid_timezone(cls, value: str) -> str:
        try:
            ZoneInfo(value)
        except Exception as exc:
            raise ValueError(f"Invalid IANA timezone: {value}") from exc
        return value


class ScheduleItem(BaseModel):
    task_id: uuid.UUID
    task_title: str
    start: datetime
    end: datetime
    reason: str = ""
    accepted: bool = False


class ScheduleMeta(BaseModel):
    overcommitted: bool = False
    risk: str | None = None
    deferred_tasks: list[str] = Field(default_factory=list)
    free_slots: list[TimeSlot] = Field(default_factory=list)
    scheduleable_hours: float = 0.0
    required_hours: float = 0.0
    provider: str | None = None
    warnings: list[str] = Field(default_factory=list)


class RecommendationResponse(BaseModel):
    id: uuid.UUID
    status: RecommendationStatus
    accepted: bool
    reasoning: str | None
    items: list[ScheduleItem] = Field(default_factory=list)
    meta: ScheduleMeta = Field(default_factory=ScheduleMeta)
    failure_reason: str | None = None
    retry_at: datetime | None = None
    created_at: datetime


class ScheduleProposal(RecommendationResponse):
    message: str | None = None


class AcceptResponse(BaseModel):
    recommendation: RecommendationResponse
    blocks: list[CalendarBlockResponse]


class RecommendationListResponse(BaseModel):
    items: list[RecommendationResponse]
    total: int


def _parse_datetime(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=ZoneInfo("UTC"))
    return parsed


def build_recommendation_response(
    recommendation: AIRecommendation,
) -> RecommendationResponse:
    stored = recommendation.recommendation or {}
    raw_items = stored.get("items", [])
    meta = stored.get("meta") or {}

    items = [
        ScheduleItem(
            task_id=uuid.UUID(item["task_id"]),
            task_title=item["task_title"],
            start=_parse_datetime(item["start"]),
            end=_parse_datetime(item["end"]),
            reason=item.get("reason", ""),
            accepted=item.get("accepted", False),
        )
        for item in raw_items
    ]

    free_slots = [
        TimeSlot(
            start=_parse_datetime(slot["start"]),
            end=_parse_datetime(slot["end"]),
        )
        for slot in meta.get("free_slots", [])
    ]

    return RecommendationResponse(
        id=recommendation.id,
        status=recommendation.status,
        accepted=recommendation.accepted,
        reasoning=recommendation.reasoning,
        items=items,
        meta=ScheduleMeta(
            overcommitted=meta.get("overcommitted", False),
            risk=meta.get("risk"),
            deferred_tasks=meta.get("deferred_tasks", []),
            free_slots=free_slots,
            scheduleable_hours=meta.get("scheduleable_hours", 0.0),
            required_hours=meta.get("required_hours", 0.0),
            provider=meta.get("provider"),
            warnings=meta.get("warnings", []),
        ),
        failure_reason=recommendation.failure_reason,
        retry_at=recommendation.retry_at,
        created_at=recommendation.created_at,
    )
