from __future__ import annotations

from datetime import datetime
from typing import Any
from uuid import UUID

from pydantic import BaseModel
from pydantic import ConfigDict
from pydantic import Field
from pydantic import field_validator
from zoneinfo import ZoneInfo

from app.models.chat import ChatRole


class ChatMessageCreate(BaseModel):
    content: str = Field(min_length=1, max_length=8000)
    timezone: str = Field(default="UTC", max_length=64)
    request_id: UUID | None = None

    @field_validator("content")
    @classmethod
    def nonblank(cls, value):
        if not value.strip():
            raise ValueError("Message must not be blank")
        return value.strip()

    @field_validator("timezone")
    @classmethod
    def valid_timezone(cls, value):
        try:
            ZoneInfo(value)
        except (ValueError, KeyError):
            raise ValueError("Invalid timezone")
        return value


class ChatConversationCreate(BaseModel):
    title: str | None = Field(default=None, max_length=80)


class ChatMessageResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    conversation_id: UUID
    role: ChatRole
    content: str | None
    tool_name: str | None = None
    tool_args: dict[str, Any] | None = None
    tool_result: dict[str, Any] | None = None
    created_at: datetime


class ChatConversationRename(BaseModel):
    title: str = Field(min_length=1, max_length=80)

    @field_validator("title")
    @classmethod
    def nonblank(cls, value):
        if not value.strip():
            raise ValueError("Title must not be blank")
        return value.strip()


class ChatConversationResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    user_id: UUID
    title: str | None
    created_at: datetime
    updated_at: datetime
    messages: list[ChatMessageResponse] | None = None
    actions: list[dict[str, Any]] = Field(default_factory=list)


class ChatConversationSummary(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    user_id: UUID
    title: str | None
    created_at: datetime
    updated_at: datetime


class ChatSendResponse(BaseModel):
    conversation_id: UUID
    message: ChatMessageResponse
    assistant_message: ChatMessageResponse
    actions: list[dict[str, Any]] = Field(default_factory=list)


class ChatToolCall(BaseModel):
    name: str
    args: dict[str, Any]


class ChatToolResult(BaseModel):
    name: str
    result: dict[str, Any]
