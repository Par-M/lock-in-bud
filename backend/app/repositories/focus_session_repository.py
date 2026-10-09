import uuid
from datetime import datetime

from sqlalchemy import Select
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models.focus_session import FocusSession
from app.schemas.reflection import FocusSessionCreate


def _base_query(user_id: uuid.UUID) -> Select:
    return select(FocusSession).where(FocusSession.user_id == user_id)


def create_focus_session(
    db: Session, *, user_id: uuid.UUID, data: FocusSessionCreate
) -> FocusSession:
    duration = data.duration_seconds
    if duration is None:
        duration = max(
            0,
            int((data.ended_at - data.started_at).total_seconds()),
        )
    session = FocusSession(
        id=data.session_id or uuid.uuid4(),
        user_id=user_id,
        task_id=data.task_id,
        started_at=data.started_at,
        ended_at=data.ended_at,
        duration_seconds=duration,
        category=data.category,
    )
    db.add(session)
    db.flush()
    db.refresh(session)
    return session


def get_focus_session(
    db: Session, *, user_id: uuid.UUID, session_id: uuid.UUID
) -> FocusSession | None:
    return db.scalar(
        _base_query(user_id).where(FocusSession.id == session_id)
    )


def update_focus_session(
    db: Session,
    *,
    session: FocusSession,
    started_at: datetime | None = None,
    ended_at: datetime | None = None,
) -> FocusSession:
    if started_at is not None:
        session.started_at = started_at
    if ended_at is not None:
        session.ended_at = ended_at
    if started_at is not None or ended_at is not None:
        session.duration_seconds = max(
            0,
            int((session.ended_at - session.started_at).total_seconds()),
        )
    db.flush()
    db.refresh(session)
    return session


def list_focus_sessions(
    db: Session,
    *,
    user_id: uuid.UUID,
    after: datetime | None = None,
    before: datetime | None = None,
) -> list[FocusSession]:
    query = _base_query(user_id)
    if after is not None:
        query = query.where(FocusSession.started_at >= after)
    if before is not None:
        query = query.where(FocusSession.started_at < before)
    return list(
        db.scalars(
            query.order_by(FocusSession.started_at.desc())
        ).all()
    )


def delete_focus_session(
    db: Session, *, session: FocusSession
) -> None:
    db.delete(session)
    db.flush()
