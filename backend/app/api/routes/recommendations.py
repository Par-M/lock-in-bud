import uuid

from fastapi import APIRouter
from fastapi import Depends
from fastapi import HTTPException
from fastapi import status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.db.session import get_db
from app.models.task import Task
from app.models.user import User
from app.schemas.recommendation import BreakdownResponse
from app.schemas.recommendation import DailyRecommendationsRequest
from app.schemas.recommendation import DailyRecommendationsResponse
from app.services.recommendation_service import RecommendationService

router = APIRouter(prefix="/recommendations", tags=["recommendations"])


def _service(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> RecommendationService:
    return RecommendationService(db, current_user.id)


@router.post("/daily", response_model=DailyRecommendationsResponse)
def daily_recommendations(
    payload: DailyRecommendationsRequest,
    service: RecommendationService = Depends(_service),
) -> DailyRecommendationsResponse:
    try:
        result = service.daily_recommendations(
            timezone_name=payload.timezone,
            start_date=payload.start_date,
            end_date=payload.end_date,
            busy_times=payload.busy_times,
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return DailyRecommendationsResponse.model_validate(result)


@router.post("/breakdown/{task_id}", response_model=BreakdownResponse)
def breakdown_task(
    task_id: uuid.UUID,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
    service: RecommendationService = Depends(_service),
) -> BreakdownResponse:
    task = db.scalar(
        select(Task).where(Task.id == task_id, Task.user_id == current_user.id)
    )
    if task is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Task not found",
        )
    return BreakdownResponse.model_validate(service.breakdown_task(task))
