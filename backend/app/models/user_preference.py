import uuid
from datetime import datetime

from sqlalchemy import DateTime
from sqlalchemy import Float
from sqlalchemy import ForeignKey
from sqlalchemy import Integer
from sqlalchemy import String
from sqlalchemy import UniqueConstraint
from sqlalchemy import func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped
from sqlalchemy.orm import mapped_column
from sqlalchemy.orm import relationship

from app.db.base import Base


class UserPreference(Base):
    __tablename__ = "user_preferences"
    __table_args__ = (
        UniqueConstraint("user_id", name="uq_user_preferences_user_id"),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )

    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )

    assistant_memory: Mapped[list[str] | None] = mapped_column(JSONB, nullable=True)

    work_hours_start: Mapped[float] = mapped_column(
        Float,
        nullable=False,
        default=5.5,
    )

    work_hours_end: Mapped[float] = mapped_column(
        Float,
        nullable=False,
        default=21.5,
    )

    buffer_minutes: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        default=15,
    )

    energy_level: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        default=3,
    )

    max_daily_hours: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        default=8,
    )

    default_duration_minutes: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        default=30,
    )

    default_priority: Mapped[str] = mapped_column(
        String(20),
        nullable=False,
        default="medium",
    )

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        nullable=False,
    )

    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )

    user: Mapped["User"] = relationship(back_populates="preferences")
