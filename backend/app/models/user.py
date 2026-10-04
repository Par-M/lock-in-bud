import uuid
from datetime import datetime

from sqlalchemy import DateTime
from sqlalchemy import String
from sqlalchemy import UniqueConstraint
from sqlalchemy import func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped
from sqlalchemy.orm import mapped_column
from sqlalchemy.orm import relationship

from app.db.base import Base


class User(Base):
    __tablename__ = "users"
    __table_args__ = (
        UniqueConstraint(
            "provider",
            "provider_user_id",
            name="uq_users_provider_user_id",
        ),
    )
    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )

    provider: Mapped[str] = mapped_column(
        String,
        nullable=False,
    )

    provider_user_id: Mapped[str] = mapped_column(
        String,
        nullable=False,
        index=True,
    )

    email: Mapped[str | None] = mapped_column(
        String,
        unique=True,
        nullable=True,
    )

    name: Mapped[str | None] = mapped_column(
        String,
        nullable=True,
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

    tasks: Mapped[list["Task"]] = relationship(
        back_populates="user",
        cascade="all, delete-orphan",
    )

    calendar_blocks: Mapped[list["CalendarBlock"]] = relationship(
        back_populates="user",
        cascade="all, delete-orphan",
    )

    recommendations: Mapped[list["AIRecommendation"]] = relationship(
        back_populates="user",
        cascade="all, delete-orphan",
    )

    preferences: Mapped[list["UserPreference"]] = relationship(
        back_populates="user",
        cascade="all, delete-orphan",
    )

    device_tokens: Mapped[list["DeviceToken"]] = relationship(
        back_populates="user",
        cascade="all, delete-orphan",
    )

    notification_preferences: Mapped[list["NotificationPreference"]] = relationship(
        back_populates="user",
        cascade="all, delete-orphan",
    )

    habits: Mapped[list["Habit"]] = relationship(
        back_populates="user",
        cascade="all, delete-orphan",
    )

    task_breakdowns: Mapped[list["TaskBreakdown"]] = relationship(
        back_populates="user",
        cascade="all, delete-orphan",
    )

    daily_task_recommendations: Mapped[list["DailyTaskRecommendation"]] = relationship(
        back_populates="user",
        cascade="all, delete-orphan",
    )

    chat_conversations: Mapped[list["ChatConversation"]] = relationship(
        back_populates="user",
        cascade="all, delete-orphan",
    )
