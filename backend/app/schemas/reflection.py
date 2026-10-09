import uuid
from datetime import date
from datetime import datetime
from datetime import time

from pydantic import BaseModel
from pydantic import ConfigDict
from pydantic import Field
from pydantic import field_validator
from pydantic import model_validator


class FocusSessionCreate(BaseModel):
    session_id: uuid.UUID | None = None
    record_task_time: bool = False
    task_id: uuid.UUID | None = None
    started_at: datetime
    ended_at: datetime
    duration_seconds: int | None = Field(default=None, ge=1, le=2_592_000)
    category: str | None = Field(default=None, max_length=100)

    @field_validator("ended_at")
    @classmethod
    def ended_after_started(cls, value: datetime, info) -> datetime:
        started = info.data.get("started_at")
        if started is not None and value <= started:
            raise ValueError("ended_at must be after started_at")
        return value

    @field_validator("duration_seconds")
    @classmethod
    def duration_positive(cls, value: int | None) -> int | None:
        if value is not None and value <= 0:
            raise ValueError("duration_seconds must be positive")
        return value

    @field_validator("category")
    @classmethod
    def category_stripped(cls, value: str | None) -> str | None:
        if value is None:
            return None
        cleaned = value.strip()
        return cleaned or None


class FocusSessionResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    user_id: uuid.UUID
    task_id: uuid.UUID | None
    started_at: datetime
    ended_at: datetime
    duration_seconds: int
    category: str | None
    created_at: datetime


class FocusSessionUpdate(BaseModel):
    started_at: datetime | None = None
    ended_at: datetime | None = None

    @model_validator(mode="after")
    def check_order(self) -> "FocusSessionUpdate":
        started = self.started_at
        ended = self.ended_at
        if started is not None and ended is not None and ended <= started:
            raise ValueError("ended_at must be after started_at")
        return self


class FocusSummaryResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    user_id: uuid.UUID
    date_started: datetime | None = None
    date_ended: datetime | None = None
    total_duration_seconds: int
    session_count: int
    task_id: uuid.UUID | None
    analysis: str


class ReflectionCreate(BaseModel):
    date: datetime
    text: str = Field(min_length=1, max_length=5000)


class ReflectionCreateDaily(BaseModel):
    date: datetime
    text: str = Field(min_length=1, max_length=5000)


class ReflectionResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    user_id: uuid.UUID
    date: date
    text: str
    analysis: str | None
    created_at: datetime
    updated_at: datetime


class MorningMessageResponse(BaseModel):
    message: str
    date: date
