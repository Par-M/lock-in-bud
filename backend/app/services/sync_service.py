"""Replication service.

This is the server half of the offline-first protocol. It is deliberately
separate from the UI-facing task endpoints, which is why the list endpoint's
``archived`` flag no longer has to double as a "give me everything" switch.

Three properties matter:

**A server-issued cursor.** ``sync_changes.seq`` is allocated by the database,
so a client's cursor is a position in a server-ordered log rather than its own
clock reading. A change committed while a download was in flight has a higher
seq than anything the download returned, so it cannot be skipped.

**Idempotent creation.** The client generates task and block ids, so pushing the
same create twice addresses the same row. Retries are additionally deduplicated
by operation id, which covers updates and deletes too.

**Explicit conflicts.** Every record carries a ``revision``. A push states the
revision the client last saw; if the server has moved on, the push is refused
and the current server state is returned rather than being silently
overwritten.
"""

import uuid
from datetime import datetime
from datetime import timezone

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db.tombstone_filter import including_deleted
from app.models.calendar_block import CalendarBlock
from app.models.sync_state import ENTITY_BLOCK
from app.models.sync_state import ENTITY_TASK
from app.models.sync_state import SyncChange
from app.models.sync_state import SyncOperation
from app.models.task import Task
from app.schemas.calendar import CalendarBlockResponse
from app.schemas.sync import BlockSyncPayload
from app.schemas.sync import PullResponse
from app.schemas.sync import PushOperation
from app.schemas.sync import PushResponse
from app.schemas.sync import PushResultOut
from app.schemas.sync import SyncChangeOut
from app.schemas.sync import TaskSyncPayload

STATUS_APPLIED = "applied"
STATUS_CONFLICT = "conflict"
STATUS_REPLAYED = "replayed"


class SyncError(ValueError):
    """A push could not be applied. Surfaced to the client as a 400."""


def _now() -> datetime:
    return datetime.now(timezone.utc)


class SyncService:
    def __init__(self, db: Session, user_id: uuid.UUID):
        self.db = db
        self.user_id = user_id

    # ------------------------------------------------------------------
    # Pull
    # ------------------------------------------------------------------

    def pull(self, cursor: int = 0, limit: int = 200) -> PullResponse:
        """Return changes after ``cursor`` plus the cursor to use next."""
        # Fetch one extra row to learn whether more remain.
        statement = (
            select(SyncChange)
            .where(SyncChange.user_id == self.user_id, SyncChange.seq > cursor)
            .order_by(SyncChange.seq)
            .limit(limit + 1)
        )
        rows = list(self.db.scalars(statement).all())
        has_more = len(rows) > limit
        rows = rows[:limit]

        changes = [
            self._to_change_out(row) for row in rows
        ]

        return PullResponse(
            changes=changes,
            # The highest seq actually returned, so a partially drained log
            # resumes exactly where it stopped.
            cursor=rows[-1].seq if rows else cursor,
            has_more=has_more,
        )

    def _to_change_out(self, row: SyncChange) -> SyncChangeOut:
        return SyncChangeOut(
            seq=row.seq,
            entity=row.entity,
            entity_id=row.entity_id,
            revision=row.revision,
            operation=row.operation,
            changed_at=row.created_at,
            record=self._load_record(row.entity, row.entity_id),
        )

    def _load_record(
        self,
        entity: str,
        entity_id: uuid.UUID,
    ) -> TaskSyncPayload | CalendarBlockResponse | None:
        if entity == ENTITY_TASK:
            task = self._get_task(entity_id)
            return self._task_to_payload(task) if task is not None else None
        block = self._get_block(entity_id)
        if block is None:
            return None
        return CalendarBlockResponse.model_validate(block)

    # ------------------------------------------------------------------
    # Push
    # ------------------------------------------------------------------

    def push(self, operations: list[PushOperation]) -> PushResponse:
        results: list[PushResultOut] = []

        for operation in operations:
            replayed = self._replay(operation)
            if replayed is not None:
                results.append(replayed)
                continue

            if operation.operation == "delete":
                result = self._apply_delete(operation)
            else:
                result = self._apply_upsert(operation)

            self._remember(operation, result)
            results.append(result)

        self.db.commit()
        return PushResponse(results=results)

    def _replay(self, operation: PushOperation) -> PushResultOut | None:
        """Return the stored outcome if this operation id was already applied."""
        existing = self.db.get(SyncOperation, operation.operation_id)
        if existing is None or existing.user_id != self.user_id:
            return None

        stored = existing.result
        return PushResultOut(
            operation_id=operation.operation_id,
            entity=stored["entity"],
            entity_id=stored["entity_id"],
            status=STATUS_REPLAYED,
            revision=stored["revision"],
            record=stored.get("record"),
            detail="Operation was already applied; returning the original result.",
        )

    def _remember(self, operation: PushOperation, result: PushResultOut) -> None:
        """Store the outcome so a retry replays instead of reapplying.

        Conflicts are not remembered: they are a transient disagreement about
        state, and the client is expected to rebase and push again.
        """
        if result.status == STATUS_CONFLICT:
            return

        self.db.add(
            SyncOperation(
                operation_id=operation.operation_id,
                user_id=self.user_id,
                entity=result.entity,
                entity_id=result.entity_id,
                result={
                    "entity": result.entity,
                    "entity_id": str(result.entity_id),
                    "revision": result.revision,
                    "record": (
                        result.record.model_dump(mode="json")
                        if result.record is not None
                        else None
                    ),
                },
            )
        )

    def _apply_upsert(self, operation: PushOperation) -> PushResultOut:
        if operation.entity == ENTITY_TASK:
            return self._upsert_task(operation)
        return self._upsert_block(operation)

    def _upsert_task(self, operation: PushOperation) -> PushResultOut:
        payload = self._require_task_payload(operation)
        task = self._get_task(payload.id, include_deleted=True)

        if task is None:
            task = Task(
                id=payload.id,
                user_id=self.user_id,
                created_at=payload.created_at or _now(),
            )
            # A create restores a record the same client had deleted earlier
            # than the server learned about; clearing the tombstone is correct.
            task.deleted_at = None
            self.db.add(task)
            self._apply_task_payload(task, payload)
            self.db.flush()
            return self._task_result(operation, task, STATUS_APPLIED)

        if not self._revision_matches(task.revision, operation.base_revision):
            return self._conflict_result(operation, task, self._task_to_payload(task))

        task.deleted_at = None
        self._apply_task_payload(task, payload)
        self.db.flush()
        return self._task_result(operation, task, STATUS_APPLIED)

    def _upsert_block(self, operation: PushOperation) -> PushResultOut:
        payload = self._require_block_payload(operation)
        block = self._get_block(payload.id, include_deleted=True)

        if block is None:
            task = self._get_task(payload.task_id, include_deleted=True)
            if task is None:
                raise SyncError(
                    f"block {payload.id} references unknown task {payload.task_id}"
                )
            block = CalendarBlock(
                id=payload.id,
                user_id=self.user_id,
                task_id=payload.task_id,
                created_at=payload.created_at or _now(),
            )
            block.deleted_at = None
            self.db.add(block)
            self._apply_block_payload(block, payload)
            self.db.flush()
            return self._block_result(operation, block, STATUS_APPLIED)

        if not self._revision_matches(block.revision, operation.base_revision):
            return self._conflict_result(
                operation,
                block,
                CalendarBlockResponse.model_validate(block),
            )

        block.deleted_at = None
        self._apply_block_payload(block, payload)
        self.db.flush()
        return self._block_result(operation, block, STATUS_APPLIED)

    def _apply_delete(self, operation: PushOperation) -> PushResultOut:
        if operation.entity == ENTITY_TASK:
            entity_id = self._entity_id_from(operation)
            task = self._get_task(entity_id, include_deleted=True)
            if task is None:
                # Already gone. Idempotent: the desired state is reached.
                return PushResultOut(
                    operation_id=operation.operation_id,
                    entity=ENTITY_TASK,
                    entity_id=entity_id,
                    status=STATUS_APPLIED,
                    revision=0,
                    record=None,
                    detail="Already deleted.",
                )
            if not self._revision_matches(task.revision, operation.base_revision):
                return self._conflict_result(
                    operation, task, self._task_to_payload(task)
                )
            self._tombstone(task)
            self.db.flush()
            return self._task_result(operation, task, STATUS_APPLIED)

        entity_id = self._entity_id_from(operation)
        block = self._get_block(entity_id, include_deleted=True)
        if block is None:
            return PushResultOut(
                operation_id=operation.operation_id,
                entity=ENTITY_BLOCK,
                entity_id=entity_id,
                status=STATUS_APPLIED,
                revision=0,
                record=None,
                detail="Already deleted.",
            )
        if not self._revision_matches(block.revision, operation.base_revision):
            return self._conflict_result(
                operation, block, CalendarBlockResponse.model_validate(block)
            )
        self._tombstone(block)
        self.db.flush()
        return self._block_result(operation, block, STATUS_APPLIED)

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _tombstone(record) -> None:
        record.deleted_at = _now()

    @staticmethod
    def _revision_matches(current: int, base: int | None) -> bool:
        """A client that has never seen the record may write it.

        A client that did see it must state the revision it saw. ``None`` is
        treated as "no opinion", which keeps a first push from a freshly
        reinstalled client working.
        """
        return base is None or current == base

    def _entity_id_from(self, operation: PushOperation) -> uuid.UUID:
        if operation.payload is not None:
            return operation.payload.id
        # A delete may legitimately omit the payload to keep the request small,
        # in which case the id has to come from somewhere else.
        raise SyncError("delete operations must include the record payload id")

    def _require_task_payload(self, operation: PushOperation) -> TaskSyncPayload:
        if not isinstance(operation.payload, TaskSyncPayload):
            raise SyncError("task operations require a task payload")
        return operation.payload

    def _require_block_payload(self, operation: PushOperation) -> BlockSyncPayload:
        if isinstance(operation.payload, BlockSyncPayload):
            return operation.payload
        raise SyncError("block operations require a block payload")

    def _get_task(
        self,
        task_id: uuid.UUID,
        include_deleted: bool = False,
    ) -> Task | None:
        statement = select(Task).where(Task.id == task_id, Task.user_id == self.user_id)
        if include_deleted:
            # Tombstoned rows are hidden from every other query; this component
            # is the one place that has to see them.
            with including_deleted():
                return self.db.scalar(statement)
        return self.db.scalar(statement)

    def _get_block(
        self,
        block_id: uuid.UUID,
        include_deleted: bool = False,
    ) -> CalendarBlock | None:
        statement = select(CalendarBlock).where(
            CalendarBlock.id == block_id,
            CalendarBlock.user_id == self.user_id,
        )
        if include_deleted:
            with including_deleted():
                return self.db.scalar(statement)
        return self.db.scalar(statement)

    def _task_to_payload(self, task: Task) -> TaskSyncPayload:
        return TaskSyncPayload.model_validate(task, from_attributes=True)

    def _apply_task_payload(self, task: Task, payload: TaskSyncPayload) -> None:
        task.title = payload.title
        task.description = payload.description
        task.deadline = payload.deadline
        task.start_at = payload.start_at
        task.end_at = payload.end_at
        task.priority = payload.priority
        task.status = payload.status
        task.estimated_duration = payload.estimated_duration
        task.actual_duration = payload.actual_duration
        task.productivity = payload.productivity
        task.category = payload.category
        task.notes = payload.notes
        task.checklist = (
            [item.model_dump() for item in payload.checklist]
            if payload.checklist is not None
            else None
        )
        task.progress_percent = payload.progress_percent
        task.repeat_weekdays = payload.repeat_weekdays
        task.repeat_ends_on = payload.repeat_ends_on
        task.repeat_overrides = (
            {k: v.model_dump(mode="json") for k, v in payload.repeat_overrides.items()}
            if payload.repeat_overrides is not None
            else None
        )
        task.before_task_ids = payload.before_task_ids
        task.after_task_ids = payload.after_task_ids
        task.is_archived = payload.is_archived
        task.updated_at = _now()
        if task.created_at is None:
            task.created_at = payload.created_at or _now()

    def _apply_block_payload(
        self,
        block: CalendarBlock,
        payload: BlockSyncPayload,
    ) -> None:
        block.task_id = payload.task_id
        block.title = payload.title
        block.start_at = payload.start_at
        block.end_at = payload.end_at
        block.calendar_event_id = payload.calendar_event_id
        block.completed_at = payload.completed_at
        block.completion_note = payload.completion_note
        block.updated_at = _now()

    def _task_result(
        self,
        operation: PushOperation,
        task: Task,
        status: str,
    ) -> PushResultOut:
        return PushResultOut(
            operation_id=operation.operation_id,
            entity=ENTITY_TASK,
            entity_id=task.id,
            status=status,
            revision=task.revision,
            record=self._task_to_payload(task),
        )

    def _block_result(
        self,
        operation: PushOperation,
        block: CalendarBlock,
        status: str,
    ) -> PushResultOut:
        return PushResultOut(
            operation_id=operation.operation_id,
            entity=ENTITY_BLOCK,
            entity_id=block.id,
            status=status,
            revision=block.revision,
            record=CalendarBlockResponse.model_validate(block),
        )

    def _conflict_result(
        self,
        operation: PushOperation,
        record,
        current,
    ) -> PushResultOut:
        return PushResultOut(
            operation_id=operation.operation_id,
            entity=(
                ENTITY_TASK
                if isinstance(record, Task)
                else ENTITY_BLOCK
            ),
            entity_id=record.id,
            status=STATUS_CONFLICT,
            revision=record.revision,
            record=current,
            detail=(
                "The record changed on the server since revision "
                f"{operation.base_revision}. Rebase onto the returned record "
                "and push again."
            ),
        )
