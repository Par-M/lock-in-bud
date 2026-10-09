import uuid
from datetime import datetime
from datetime import timezone

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.models.focus_session import FocusSession
from app.models.task import Task
from app.repositories import focus_session_repository
from app.schemas.reflection import FocusSessionCreate
from app.schemas.reflection import FocusSessionResponse
from app.schemas.reflection import FocusSessionUpdate
from app.schemas.reflection import FocusSummaryResponse
from app.services.text_analysis import AnalysisResult
from app.services.text_analysis import TextAnalysisError
from app.services.text_analysis import default_analysis_provider


class FocusSessionNotFoundError(Exception):
    pass


class FocusSessionConflictError(Exception):
    pass


class FocusTaskNotFoundError(Exception):
    pass


class FocusService:
    """Owns creating, listing, analyzing, and deleting focus sessions."""

    def __init__(self, db: Session, *, user_id: uuid.UUID) -> None:
        self.db = db
        self.user_id = user_id

    def create_focus_session(self, data: FocusSessionCreate) -> FocusSessionResponse:
        if data.session_id is not None:
            existing = focus_session_repository.get_focus_session(
                self.db, user_id=self.user_id, session_id=data.session_id,
            )
            if existing is not None:
                return self._replay(existing, data)
        try:
            task = None
            if data.task_id is not None:
                task = self.db.scalar(
                    select(Task).where(
                        Task.id == data.task_id,
                        Task.user_id == self.user_id,
                        Task.deleted_at.is_(None),
                    ).with_for_update().execution_options(populate_existing=True)
                )
                if task is None:
                    raise FocusTaskNotFoundError("Task not found")
            session = focus_session_repository.create_focus_session(
                self.db, user_id=self.user_id, data=data,
            )
            # Insert first: a duplicate PK must fail before any task time is added.
            if data.record_task_time and task is not None:
                minutes = session.duration_seconds // 60
                if minutes:
                    task.actual_duration = (task.actual_duration or 0) + minutes
            self.db.commit()
        except IntegrityError as exc:
            self.db.rollback()
            diagnostic = getattr(exc.orig, "diag", None)
            if (
                data.session_id is None
                or getattr(diagnostic, "constraint_name", None) != "focus_sessions_pkey"
            ):
                raise
            existing = focus_session_repository.get_focus_session(
                self.db, user_id=self.user_id, session_id=data.session_id,
            )
            if existing is None:
                raise FocusSessionConflictError("Focus session ID is unavailable") from exc
            return self._replay(existing, data)
        except Exception:
            self.db.rollback()
            raise
        return FocusSessionResponse.model_validate(session)

    @staticmethod
    def _replay(session: FocusSession, data: FocusSessionCreate) -> FocusSessionResponse:
        def utc(value: datetime) -> datetime:
            if value.tzinfo is None:
                return value.replace(tzinfo=timezone.utc)
            return value.astimezone(timezone.utc)

        duration = data.duration_seconds
        if duration is None:
            duration = max(0, int((data.ended_at - data.started_at).total_seconds()))
        # The accounting flag is not stored. Replays never add time, even if it changes.
        if (
            session.task_id != data.task_id
            or utc(session.started_at) != utc(data.started_at)
            or utc(session.ended_at) != utc(data.ended_at)
            or session.duration_seconds != duration
            or session.category != data.category
        ):
            raise FocusSessionConflictError("Focus session payload does not match")
        return FocusSessionResponse.model_validate(session)

    def get_focus_session(self, session_id: uuid.UUID) -> FocusSessionResponse:
        session = focus_session_repository.get_focus_session(
            self.db,
            user_id=self.user_id,
            session_id=session_id,
        )
        if session is None:
            raise FocusSessionNotFoundError("Focus session not found")
        return FocusSessionResponse.model_validate(session)

    def list_focus_sessions(
        self,
        *,
        after: datetime | None = None,
        before: datetime | None = None,
    ) -> list[FocusSessionResponse]:
        sessions = focus_session_repository.list_focus_sessions(
            self.db,
            user_id=self.user_id,
            after=after,
            before=before,
        )
        return [FocusSessionResponse.model_validate(s) for s in sessions]

    def delete_focus_session(self, session_id: uuid.UUID) -> None:
        session = focus_session_repository.get_focus_session(
            self.db,
            user_id=self.user_id,
            session_id=session_id,
        )
        if session is None:
            raise FocusSessionNotFoundError("Focus session not found")
        focus_session_repository.delete_focus_session(self.db, session=session)
        self.db.commit()

    def update_focus_session(
        self,
        session_id: uuid.UUID,
        data: FocusSessionUpdate,
    ) -> FocusSessionResponse:
        session = focus_session_repository.get_focus_session(
            self.db,
            user_id=self.user_id,
            session_id=session_id,
        )
        if session is None:
            raise FocusSessionNotFoundError("Focus session not found")
        session = focus_session_repository.update_focus_session(
            self.db,
            session=session,
            started_at=data.started_at,
            ended_at=data.ended_at,
        )
        self.db.commit()
        self.db.refresh(session)
        return FocusSessionResponse.model_validate(session)

    def focus_summary(
        self,
        *,
        after: datetime | None = None,
        before: datetime | None = None,
    ) -> FocusSummaryResponse:
        sessions = focus_session_repository.list_focus_sessions(
            self.db,
            user_id=self.user_id,
            after=after,
            before=before,
        )
        total = sum(session.duration_seconds for session in sessions)
        count = len(sessions)
        analysis = self._analyze_summary(total_seconds=total, count=count)
        return FocusSummaryResponse(
            user_id=self.user_id,
            date_started=after,
            date_ended=before,
            total_duration_seconds=total,
            session_count=count,
            task_id=None,
            analysis=analysis,
        )

    def _analyze_summary(self, *, total_seconds: int, count: int) -> str:
        if count == 0:
            return (
                "No focus sessions logged yet in this window. Even one "
                "short session is a meaningful start."
            )
        minutes = max(1, total_seconds // 60)
        provider = default_analysis_provider()
        prompt = (
            f"I logged {count} focus session(s) totaling {minutes} minutes of "
            "deep work this period. Write one encouraging 1-2 sentence "
            "observation about momentum and what to protect next."
        )
        try:
            result = provider.analyze_text(prompt)
            return result.insight if isinstance(result, AnalysisResult) else str(result)
        except TextAnalysisError:
            return self._fallback(minutes=minutes, count=count)

    @staticmethod
    def _fallback(*, minutes: int, count: int) -> str:
        hours = minutes // 60
        remainder = minutes % 60
        if hours:
            amount = f"{hours}h {remainder:02d}m"
        else:
            amount = f"{minutes}m"
        return (
            f"You logged {count} session(s) and {amount} of focused work this "
            "period. That momentum compounds — protect the same window "
            "tomorrow."
        )
