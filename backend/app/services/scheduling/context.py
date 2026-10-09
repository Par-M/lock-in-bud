from dataclasses import dataclass
from dataclasses import field
from datetime import date
from datetime import datetime
from uuid import UUID

from app.models.task import TaskPriority


@dataclass(frozen=True)
class TimeSlot:
    start: datetime
    end: datetime

    @property
    def duration_minutes(self) -> int:
        return int((self.end - self.start).total_seconds() // 60)


@dataclass(frozen=True)
class TaskContext:
    id: UUID
    title: str
    deadline: datetime | None
    duration_minutes: int
    priority: TaskPriority
    energy_level: int
    start_at: datetime | None = None
    end_at: datetime | None = None
    before_task_titles: tuple[str, ...] = ()
    after_task_titles: tuple[str, ...] = ()
    is_overdue: bool = False

    @property
    def is_fixed(self) -> bool:
        return self.start_at is not None and self.end_at is not None


@dataclass
class SchedulingContext:
    tasks: list[TaskContext]
    dates: list[date]
    timezone: str
    busy_times: list[TimeSlot] = field(default_factory=list)
    work_start_hour: float = 9
    work_end_hour: float = 17
    buffer_minutes: int = 15
    energy_level: int = 3
    max_chunk_minutes: int = 90
    max_daily_hours: int = 8
    free_slots: list[TimeSlot] = field(default_factory=list)
    committed_minutes_by_day: dict[date, int] = field(default_factory=dict)

    @property
    def scheduleable_minutes(self) -> int:
        return sum(slot.duration_minutes for slot in self.free_slots)

    @property
    def required_minutes(self) -> int:
        return sum(task.duration_minutes for task in self.tasks)


@dataclass(frozen=True)
class ProposedBlock:
    task_id: UUID
    task_title: str
    start: datetime
    end: datetime
    reason: str


@dataclass
class ProviderResult:
    items: list[ProposedBlock] = field(default_factory=list)
    reasoning: str = ""
