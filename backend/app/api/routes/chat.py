from __future__ import annotations

import json
import math
import threading
import time
from uuid import UUID
from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.encoders import jsonable_encoder
from fastapi.responses import StreamingResponse
from sqlalchemy.orm import Session
from app.api.deps import get_current_user
from app.core.config import settings
from app.db.session import get_db
from app.models.user import User
from app.schemas.chat import (ChatConversationCreate, ChatConversationResponse, ChatConversationSummary,
                              ChatMessageCreate, ChatMessageResponse, ChatSendResponse, ChatConversationRename)
from app.services.chat_service import ChatService, ChatServiceError

router = APIRouter(prefix="/chat", tags=["chat"])
# Best effort per process. Deploy a shared limiter if global enforcement is needed.
_user_rate: dict[str, list[float]] = {}
_rate_lock = threading.Lock()


def _rate_limit(user_id: str):
    now = time.time()
    with _rate_lock:
        for key in list(_user_rate):
            timestamps = [stamp for stamp in _user_rate[key] if now - stamp < 86400]
            if timestamps:
                _user_rate[key] = timestamps
            else:
                del _user_rate[key]
        stamps = _user_rate.get(str(user_id), [])
        for seconds, cap in ((60, settings.chat_rate_limit_rpm), (3600, settings.chat_rate_limit_rph), (86400, settings.chat_rate_limit_rpd)):
            window = [stamp for stamp in stamps if now - stamp < seconds]
            if len(window) >= cap:
                wait = max(1, math.ceil(seconds - (now - window[0])))
                raise HTTPException(status_code=429, detail="Rate limit exceeded", headers={"Retry-After": str(wait)})
        _user_rate[str(user_id)] = [*stamps, now]


def _service(db: Session = Depends(get_db), current_user: User = Depends(get_current_user)):
    return ChatService(db, user_id=current_user.id)


def _run(operation):
    try:
        return operation()
    except ChatServiceError as exc:
        raise HTTPException(status_code=exc.status_code, detail=str(exc)) from exc


@router.get("/memory")
def memory(service: ChatService = Depends(_service)):
    return _run(service.memory)


@router.delete("/memory")
def clear_memory(service: ChatService = Depends(_service)):
    return _run(service.clear_memory)


@router.post("/conversations", response_model=ChatConversationResponse, status_code=201)
def create_conversation(payload: ChatConversationCreate, service: ChatService = Depends(_service)):
    return service.create_conversation(title=payload.title)


@router.get("/conversations", response_model=list[ChatConversationSummary])
def list_conversations(limit: int = Query(default=50, ge=1, le=100), offset: int = Query(default=0, ge=0), service: ChatService = Depends(_service)):
    return service.list_conversations(limit, offset)


@router.get("/conversations/{conversation_id}", response_model=ChatConversationResponse)
def get_conversation(conversation_id: UUID, service: ChatService = Depends(_service)):
    conv = _run(lambda: service.get_conversation(conversation_id))
    # Bounded detail. Clients load older pages explicitly rather than lazily
    # serializing the entire relationship.
    from app.repositories import chat_repository
    messages = chat_repository.list_messages(service.db, conversation_id=conv.id, limit=100)
    return ChatConversationResponse(id=conv.id, user_id=conv.user_id, title=conv.title,
        created_at=conv.created_at, updated_at=conv.updated_at, messages=messages, actions=service.actions(conv.id))


@router.patch("/conversations/{conversation_id}", response_model=ChatConversationSummary)
def rename_conversation(conversation_id: UUID, payload: ChatConversationRename, service: ChatService = Depends(_service)):
    return _run(lambda: service.rename_conversation(conversation_id, payload.title))


@router.delete("/conversations/{conversation_id}")
def delete_conversation(conversation_id: UUID, service: ChatService = Depends(_service)):
    _run(lambda: service.delete_conversation(conversation_id))
    return {"message": "Conversation deleted"}


@router.get("/conversations/{conversation_id}/messages", response_model=list[ChatMessageResponse])
def messages(conversation_id: UUID, after: UUID | None = None, before: UUID | None = None, limit: int = Query(default=50, ge=1, le=100), service: ChatService = Depends(_service)):
    if after and before:
        raise HTTPException(status_code=422, detail="Use either after or before")
    return _run(lambda: service.messages_page(conversation_id, after, limit, before))


@router.post("/conversations/{conversation_id}/messages", response_model=ChatSendResponse)
def send_message(conversation_id: UUID, payload: ChatMessageCreate, request: Request, service: ChatService = Depends(_service)):
    if "text/event-stream" in request.headers.get("accept", ""):
        return stream_message(conversation_id, payload, service)
    _run(lambda: service.get_conversation(conversation_id))
    _rate_limit(str(service.user_id))
    return _run(lambda: service.send_message(conversation_id, payload.content, payload.timezone, payload.request_id))


@router.post("/conversations/{conversation_id}/messages/stream")
def stream_message(conversation_id: UUID, payload: ChatMessageCreate, service: ChatService = Depends(_service)):
    _run(lambda: service.get_conversation(conversation_id))
    _rate_limit(str(service.user_id))
    def events():
        try:
            for event in service.send_events(conversation_id, payload.content, payload.timezone, payload.request_id):
                if event["type"] == "complete":
                    event["result"] = ChatSendResponse.model_validate(event["result"]).model_dump(mode="json")
                yield "data: " + json.dumps(jsonable_encoder(event)) + "\n\n"
        except Exception as exc:
            service.db.rollback()
            detail = str(exc) if isinstance(exc, ChatServiceError) else "The assistant is unavailable. Your draft was kept."
            yield "data: " + json.dumps({"type": "error", "detail": detail}) + "\n\n"
    return StreamingResponse(events(), media_type="text/event-stream", headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"})


@router.post("/conversations/{conversation_id}/actions/{action_id}/confirm")
def confirm_action(conversation_id: UUID, action_id: UUID, service: ChatService = Depends(_service)):
    return _run(lambda: service.decide_action(conversation_id, action_id, confirm=True))


@router.post("/conversations/{conversation_id}/actions/{action_id}/cancel")
def cancel_action(conversation_id: UUID, action_id: UUID, service: ChatService = Depends(_service)):
    return _run(lambda: service.decide_action(conversation_id, action_id, confirm=False))
