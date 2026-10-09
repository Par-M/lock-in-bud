from __future__ import annotations

from datetime import datetime, timezone
from uuid import UUID
from sqlalchemy import select, tuple_
from sqlalchemy.orm import Session
from app.models.chat import ChatConversation, ChatMessage, ChatRole


def create_conversation(db: Session, *, user_id: UUID, title: str | None):
    conv = ChatConversation(user_id=user_id, title=title)
    db.add(conv)
    db.flush()
    return conv


def list_conversations(db: Session, *, user_id: UUID, limit: int = 50, offset: int = 0):
    return list(db.scalars(select(ChatConversation).where(ChatConversation.user_id == user_id)
        .order_by(ChatConversation.updated_at.desc(), ChatConversation.id.desc()).offset(offset).limit(limit)))


def get_conversation(db: Session, *, user_id: UUID, conversation_id: UUID, lock: bool = False):
    stmt = select(ChatConversation).where(ChatConversation.id == conversation_id, ChatConversation.user_id == user_id)
    if lock:
        stmt = stmt.with_for_update().execution_options(populate_existing=True)
    return db.scalar(stmt)


def touch_conversation(db: Session, conv):
    conv.updated_at = datetime.now(timezone.utc)


def add_message(db: Session, *, conversation_id: UUID, role: ChatRole, content=None, tool_name=None, tool_args=None, tool_result=None):
    msg = ChatMessage(conversation_id=conversation_id, role=role, content=content,
                      tool_name=tool_name, tool_args=tool_args, tool_result=tool_result,
                      created_at=datetime.now(timezone.utc))
    db.add(msg)
    db.flush()
    return msg


def list_messages(db: Session, *, conversation_id: UUID, limit: int | None = None):
    stmt = select(ChatMessage).where(ChatMessage.conversation_id == conversation_id)
    if limit:
        rows = list(db.scalars(stmt.order_by(ChatMessage.created_at.desc(), ChatMessage.id.desc()).limit(limit)))
        return list(reversed(rows))
    return list(db.scalars(stmt.order_by(ChatMessage.created_at, ChatMessage.id)))


def get_message(db: Session, *, conversation_id: UUID, message_id: UUID):
    return db.scalar(select(ChatMessage).where(ChatMessage.conversation_id == conversation_id, ChatMessage.id == message_id))


def find_request(db: Session, *, conversation_id: UUID, request_id: UUID):
    return db.scalar(select(ChatMessage).where(ChatMessage.conversation_id == conversation_id,
        ChatMessage.role == ChatRole.user, ChatMessage.tool_result["request_id"].astext == str(request_id)))


def messages_page(db: Session, *, conversation_id: UUID, after: UUID | None, limit: int, before: UUID | None = None):
    stmt = select(ChatMessage).where(ChatMessage.conversation_id == conversation_id)
    if after or before:
        anchor = get_message(db, conversation_id=conversation_id, message_id=after or before)
        if anchor is None:
            from app.services.chat_service import ChatServiceError
            raise ChatServiceError("Message cursor not found", status_code=404)
        key = tuple_(ChatMessage.created_at, ChatMessage.id)
        stmt = stmt.where(key < (anchor.created_at, anchor.id) if before else key > (anchor.created_at, anchor.id))
    if before:
        return list(reversed(list(db.scalars(stmt.order_by(ChatMessage.created_at.desc(), ChatMessage.id.desc()).limit(limit)))))
    return list(db.scalars(stmt.order_by(ChatMessage.created_at, ChatMessage.id).limit(limit)))


def action_results(db: Session, *, conversation_id: UUID):
    return list(db.scalars(select(ChatMessage).where(ChatMessage.conversation_id == conversation_id,
        ChatMessage.role == ChatRole.tool_result, ChatMessage.tool_result["pending_action"].astext == "true")
        .order_by(ChatMessage.created_at, ChatMessage.id)))


def action_result(db: Session, *, conversation_id: UUID, action_id: UUID):
    return db.scalar(select(ChatMessage).where(ChatMessage.conversation_id == conversation_id,
        ChatMessage.role == ChatRole.tool_result, ChatMessage.tool_result["action_id"].astext == str(action_id)).with_for_update())
