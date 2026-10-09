import uuid

from fastapi import APIRouter
from fastapi import Depends
from fastapi import HTTPException
from fastapi import Query
from fastapi import status
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.db.session import get_db
from app.models.ai_recommendation import RecommendationStatus
from app.models.user import User
from app.schemas.schedule import AcceptResponse
from app.schemas.schedule import RecommendationListResponse
from app.schemas.schedule import RecommendationResponse
from app.schemas.schedule import ScheduleGenerateRequest
from app.schemas.schedule import ScheduleProposal
from app.schemas.schedule import build_recommendation_response
from app.services.scheduling_service import RecommendationNotAcceptableError
from app.services.scheduling_service import RecommendationNotFoundError
from app.services.scheduling_service import SchedulingService
from app.services.notification_service import NotificationService

router = APIRouter(prefix="/schedule", tags=["schedule"])


def _service(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> SchedulingService:
    return SchedulingService(db, current_user.id)


def _notification_service(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> NotificationService:
    return NotificationService(db, current_user.id)


def _handle_service_errors(exc: Exception) -> None:
    if isinstance(exc, RecommendationNotFoundError):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=str(exc),
        )
    if isinstance(exc, RecommendationNotAcceptableError):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=str(exc),
        )
    raise exc


def _proposal_response(recommendation, message: str) -> ScheduleProposal:
    base = build_recommendation_response(recommendation).model_dump()
    return ScheduleProposal(**base, message=message)


@router.post("/generate", response_model=ScheduleProposal)
def generate_schedule(
    payload: ScheduleGenerateRequest,
    service: SchedulingService = Depends(_service),
    notification_service: NotificationService = Depends(_notification_service),
) -> ScheduleProposal:
    recommendation = service.generate(payload)
    stored = recommendation.recommendation or {}
    items = stored.get("items", [])
    meta = stored.get("meta", {})
    if recommendation.failure_reason:
        message = (
            "Scheduling was temporarily unavailable. The current schedule was "
            "preserved. Try generating again."
        )
    elif meta.get("overcommitted"):
        message = (
            "Your proposed schedule is ready, but there is not enough free "
            "time for every task. Some tasks were deferred."
        )
    elif not items:
        message = "No active tasks to schedule."
    else:
        message = "Your proposed schedule is ready for review."
    if meta.get("overcommitted"):
        try:
            notification_service.notify_overcommitted(
                service.user_id,
                deferred_titles=meta.get("deferred_tasks") or [],
                required_hours=float(meta.get("required_hours") or 0.0),
                scheduleable_hours=float(meta.get("scheduleable_hours") or 0.0),
            )
        except Exception:  # pragma: no cover - defensive
            pass
    return _proposal_response(recommendation, message)


@router.post("/replan", response_model=ScheduleProposal)
def replan(
    payload: ScheduleGenerateRequest,
    service: SchedulingService = Depends(_service),
    notification_service: NotificationService = Depends(_notification_service),
) -> ScheduleProposal:
    return generate_schedule(payload, service, notification_service)


@router.get("/recommendations", response_model=RecommendationListResponse)
def list_recommendations(
    status_filter: RecommendationStatus | None = Query(
        default=None, alias="status"
    ),
    limit: int = Query(default=50, ge=1, le=200),
    service: SchedulingService = Depends(_service),
) -> RecommendationListResponse:
    recommendations = service.list_recommendations(status_filter, limit)
    items = [
        build_recommendation_response(recommendation)
        for recommendation in recommendations
    ]
    return RecommendationListResponse(items=items, total=len(items))


@router.post("/recommendations/{recommendation_id}/accept", response_model=AcceptResponse)
def accept_recommendation(
    recommendation_id: uuid.UUID,
    service: SchedulingService = Depends(_service),
) -> AcceptResponse:
    try:
        recommendation, blocks = service.accept(recommendation_id)
    except (
        RecommendationNotFoundError,
        RecommendationNotAcceptableError,
    ) as exc:
        _handle_service_errors(exc)
    return AcceptResponse(
        recommendation=build_recommendation_response(recommendation),
        blocks=blocks,
    )


@router.post(
    "/recommendations/{recommendation_id}/reject",
    response_model=RecommendationResponse,
)
def reject_recommendation(
    recommendation_id: uuid.UUID,
    service: SchedulingService = Depends(_service),
) -> RecommendationResponse:
    try:
        recommendation = service.reject(recommendation_id)
    except (
        RecommendationNotFoundError,
        RecommendationNotAcceptableError,
    ) as exc:
        _handle_service_errors(exc)
    return build_recommendation_response(recommendation)


@router.post(
    "/recommendations/{recommendation_id}/items/{item_index}/accept",
    response_model=AcceptResponse,
)
def accept_item(
    recommendation_id: uuid.UUID,
    item_index: int,
    service: SchedulingService = Depends(_service),
) -> AcceptResponse:
    try:
        recommendation, blocks = service.accept_item(
            recommendation_id, item_index
        )
    except (
        RecommendationNotFoundError,
        RecommendationNotAcceptableError,
    ) as exc:
        _handle_service_errors(exc)
    return AcceptResponse(
        recommendation=build_recommendation_response(recommendation),
        blocks=blocks,
    )


@router.post(
    "/recommendations/{recommendation_id}/items/{item_index}/redo",
    response_model=RecommendationResponse,
)
def redo_item(
    recommendation_id: uuid.UUID,
    item_index: int,
    service: SchedulingService = Depends(_service),
) -> RecommendationResponse:
    try:
        recommendation = service.redo_item(recommendation_id, item_index)
    except (
        RecommendationNotFoundError,
        RecommendationNotAcceptableError,
    ) as exc:
        _handle_service_errors(exc)
    return build_recommendation_response(recommendation)
