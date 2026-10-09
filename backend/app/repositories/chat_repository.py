from __future__ import annotations

from datetime import datetime
from uuid import UUID

from sqlalchemy.orm import Session
from sqlalchemy import select, desc

from app.models.chat import ChatConversation
from app.models.chat import ChatMessage
from app.models.chat import ChatRole


def create_conversation(db: Session, *, user_id: UUID, title: str | None) -> ChatConversation:
    conv = ChatConversation(user_id=user_id, title=title)
    db.add(conv)
    db.flush()
    db.refresh(conv)
    return conv


def list_conversations(db: Session, *, user_id: UUID, limit: int = 50) -> list[ChatConversation]:
    stmt = (
        select(ChatConversation)
        .where(ChatConversation.user_id == user_id)
        .order_by(desc(ChatConversation.updated_at), desc(ChatConversation.created_at))
        .limit(limit)
    )
    return list(db.scalars(stmt).all())


def get_conversation(db: Session, *, user_id: UUID, conversation_id: UUID) -> ChatConversation | None:
    stmt = select(ChatConversation).where(
        ChatConversation.id == conversation_id,
        ChatConversation.user_id == user_id,
    )
    return db.scalars(stmt).first()


def touch_conversation(db: Session, conv: ChatConversation) -> None:
    conv.updated_at = datetime.utcnow()  # will be overridden by onupdate in DB, but set for clarity


def add_message(
    db: Session,
    *,
    conversation_id: UUID,
    role: ChatRole,
    content: str | None = None,
    tool_name: str | None = None,
    tool_args: dict | None = None,
    tool_result: dict | None = None,
) -> ChatMessage:
    msg = ChatMessage(
        conversation_id=conversation_id,
        role=role,
        content=content,
        tool_name=tool_name,
        tool_args=tool_args,
        tool_result=tool_result,
    )
    db.add(msg)
    db.flush()
    db.refresh(msg)
    return msg


def list_messages(db: Session, *, conversation_id: UUID, limit: int | None = None) -> list[ChatMessage]:
    stmt = select(ChatMessage).where(ChatMessage.conversation_id == conversation_id).order_by(ChatMessage.created_at)
    if limit:
        stmt = stmt.limit(limit)
    return list(db.scalars(stmt).all())
