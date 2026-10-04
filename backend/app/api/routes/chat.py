from __future__ import annotations

import time
from uuid import UUID

from fastapi import APIRouter
from fastapi import Depends
from fastapi import HTTPException
from fastapi import status
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.core.config import settings
from app.db.session import get_db
from app.models.user import User
from app.schemas.chat import ChatConversationCreate
from app.schemas.chat import ChatConversationResponse
from app.schemas.chat import ChatMessageCreate
from app.schemas.chat import ChatSendResponse
from app.services.chat_service import ChatService
from app.services.chat_service import ChatServiceError

router = APIRouter(prefix="/chat", tags=["chat"])


_user_rate = {}


def _rate_limit(user_id: str) -> None:
    now = int(time.time())
    key = str(user_id)
    data = _user_rate.get(key, {"count": 0, "window": now})
    if now - data["window"] >= 60:
        data = {"count": 0, "window": now}
    data["count"] += 1
    _user_rate[key] = data
    if data["count"] > settings.chat_rate_limit_rpm:
        raise HTTPException(status_code=status.HTTP_429_TOO_MANY_REQUESTS, detail="Rate limit exceeded")


def _service(db: Session = Depends(get_db), current_user: User = Depends(get_current_user)) -> ChatService:
    return ChatService(db, user_id=current_user.id)


@router.post("/conversations", response_model=ChatConversationResponse, status_code=status.HTTP_201_CREATED)
def create_conversation(
    payload: ChatConversationCreate,
    service: ChatService = Depends(_service),
) -> ChatConversationResponse:
    conv = service.create_conversation(title=payload.title)
    return ChatConversationResponse.model_validate(conv)


@router.get("/conversations", response_model=list[ChatConversationResponse])
def list_conversations(service: ChatService = Depends(_service)) -> list[ChatConversationResponse]:
    convs = service.list_conversations()
    return [ChatConversationResponse.model_validate(c) for c in convs]


@router.get("/conversations/{conversation_id}", response_model=ChatConversationResponse)
def get_conversation(
    conversation_id: UUID,
    service: ChatService = Depends(_service),
) -> ChatConversationResponse:
    try:
        conv = service.get_conversation(conversation_id)
    except ChatServiceError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc))
    return ChatConversationResponse.model_validate(conv)


@router.post("/conversations/{conversation_id}/messages", response_model=ChatSendResponse)
def send_message(
    conversation_id: UUID,
    payload: ChatMessageCreate,
    service: ChatService = Depends(_service),
) -> ChatSendResponse:
    _rate_limit(str(service.user_id))
    try:
        result = service.send_message(conversation_id, payload.content)
    except ChatServiceError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc))
    return ChatSendResponse(
        conversation_id=result["conversation_id"],
        message=result["message"],
        assistant_message=result["assistant_message"],
    )
