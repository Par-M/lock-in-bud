from __future__ import annotations

from datetime import datetime
from typing import Any
from uuid import UUID

from pydantic import BaseModel
from pydantic import ConfigDict
from pydantic import Field

from app.models.chat import ChatRole


class ChatMessageCreate(BaseModel):
    content: str = Field(min_length=1, max_length=8000)


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


class ChatConversationResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    user_id: UUID
    title: str | None
    created_at: datetime
    updated_at: datetime
    messages: list[ChatMessageResponse] | None = None


class ChatSendResponse(BaseModel):
    conversation_id: UUID
    message: ChatMessageResponse
    assistant_message: ChatMessageResponse


class ChatToolCall(BaseModel):
    name: str
    args: dict[str, Any]


class ChatToolResult(BaseModel):
    name: str
    result: dict[str, Any]
