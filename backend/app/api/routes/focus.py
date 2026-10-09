import uuid
from datetime import datetime

from fastapi import APIRouter
from fastapi import Depends
from fastapi import HTTPException
from fastapi import Query
from fastapi import status
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.db.session import get_db
from app.models.user import User
from app.schemas.reflection import FocusSessionCreate
from app.schemas.reflection import FocusSessionResponse
from app.schemas.reflection import FocusSessionUpdate
from app.schemas.reflection import FocusSummaryResponse
from app.services.focus_service import FocusSessionConflictError
from app.services.focus_service import FocusSessionNotFoundError
from app.services.focus_service import FocusService
from app.services.focus_service import FocusTaskNotFoundError

router = APIRouter(prefix="/focus", tags=["focus"])


def _service(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> FocusService:
    return FocusService(db, user_id=current_user.id)


def _handle_not_found(exc: Exception) -> None:
    raise HTTPException(
        status_code=status.HTTP_404_NOT_FOUND,
        detail=str(exc),
    ) from exc


@router.post(
    "/sessions",
    response_model=FocusSessionResponse,
    status_code=status.HTTP_201_CREATED,
)
def create_focus_session(
    payload: FocusSessionCreate,
    service: FocusService = Depends(_service),
) -> FocusSessionResponse:
    try:
        return service.create_focus_session(payload)
    except FocusTaskNotFoundError as exc:
        _handle_not_found(exc)
    except FocusSessionConflictError as exc:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT, detail=str(exc),
        ) from exc


@router.get("/sessions", response_model=list[FocusSessionResponse])
def list_focus_sessions(
    after: datetime | None = Query(default=None),
    before: datetime | None = Query(default=None),
    service: FocusService = Depends(_service),
) -> list[FocusSessionResponse]:
    return service.list_focus_sessions(after=after, before=before)


@router.get("/summary", response_model=FocusSummaryResponse)
def focus_summary(
    after: datetime | None = Query(default=None),
    before: datetime | None = Query(default=None),
    service: FocusService = Depends(_service),
) -> FocusSummaryResponse:
    return service.focus_summary(after=after, before=before)


@router.get("/sessions/{session_id}", response_model=FocusSessionResponse)
def get_focus_session(
    session_id: uuid.UUID,
    service: FocusService = Depends(_service),
) -> FocusSessionResponse:
    try:
        return service.get_focus_session(session_id)
    except FocusSessionNotFoundError as exc:
        _handle_not_found(exc)


@router.patch("/sessions/{session_id}", response_model=FocusSessionResponse)
def update_focus_session(
    session_id: uuid.UUID,
    payload: FocusSessionUpdate,
    service: FocusService = Depends(_service),
) -> FocusSessionResponse:
    try:
        return service.update_focus_session(session_id, payload)
    except FocusSessionNotFoundError as exc:
        _handle_not_found(exc)


@router.delete("/sessions/{session_id}")
def delete_focus_session(
    session_id: uuid.UUID,
    service: FocusService = Depends(_service),
) -> dict[str, str]:
    try:
        service.delete_focus_session(session_id)
    except FocusSessionNotFoundError as exc:
        _handle_not_found(exc)
    return {"message": "Focus session deleted"}
