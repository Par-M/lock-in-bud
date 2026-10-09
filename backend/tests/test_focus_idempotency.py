"""Run serially with the DB suite; worker sessions only overlap within one test."""

import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from datetime import timedelta
from datetime import timezone
from threading import Barrier

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import func
from sqlalchemy import select

from app.db.database import SessionLocal
from app.models.focus_session import FocusSession
from app.models.sync_state import SyncChange
from app.models.task import Task
from app.repositories import focus_session_repository
from app.schemas.reflection import FocusSessionCreate
from app.services.focus_service import FocusService


def _headers(client: TestClient, email: str = "idempotency@test.dev") -> dict[str, str]:
    response = client.post(
        "/api/v1/auth/dev", json={"name": "Focus Tester", "email": email},
    )
    assert response.status_code == 200, response.text
    return {"Authorization": f"Bearer {response.json()['access_token']}"}


def _task(client: TestClient, headers: dict[str, str]) -> dict:
    response = client.post(
        "/api/v1/tasks", headers=headers, json={"title": "Focus task"},
    )
    assert response.status_code == 201, response.text
    task = response.json()
    with SessionLocal() as db:
        task["revision"] = db.get(Task, uuid.UUID(task["id"])).revision
    return task


def _payload(task_id: str | None = None, seconds: int = 125) -> dict:
    started = datetime(2026, 1, 2, 10, tzinfo=timezone.utc)
    return {
        "session_id": str(uuid.uuid4()),
        "task_id": task_id,
        "record_task_time": True,
        "started_at": started.isoformat(),
        "ended_at": (started + timedelta(seconds=seconds)).isoformat(),
        "duration_seconds": seconds,
        "category": "Work",
    }


def _post(client: TestClient, headers: dict[str, str], payload: dict):
    return client.post("/api/v1/focus/sessions", headers=headers, json=payload)


def test_stable_retry_counts_once_and_syncs_task(client: TestClient) -> None:
    headers = _headers(client)
    task = _task(client, headers)
    payload = _payload(task["id"])
    first = _post(client, headers, payload)
    assert first.status_code == 201, first.text
    assert first.json()["id"] == payload["session_id"]
    for _ in range(3):
        retry = _post(client, headers, payload)
        assert retry.status_code == 201, retry.text
        assert retry.json() == first.json()
    updated = client.get(f"/api/v1/tasks/{task['id']}", headers=headers).json()
    assert updated["actual_duration"] == 2
    assert len(client.get("/api/v1/focus/sessions", headers=headers).json()) == 1
    with SessionLocal() as db:
        assert db.get(Task, uuid.UUID(task["id"])).revision == task["revision"] + 1
        assert db.scalar(select(func.count()).select_from(SyncChange).where(
            SyncChange.entity_id == uuid.UUID(task["id"]),
        )) == 2  # Task creation and the single accounting update.


@pytest.mark.parametrize("seconds, expected", [(1, None), (59, None), (60, 1), (119, 1), (125, 2)])
@pytest.mark.parametrize("explicit_duration", [True, False])
def test_whole_minutes_only(
    client: TestClient, seconds: int, expected: int | None, explicit_duration: bool,
) -> None:
    headers = _headers(client)
    task = _task(client, headers)
    payload = _payload(task["id"], seconds)
    if not explicit_duration:
        payload.pop("duration_seconds")
    response = _post(client, headers, payload)
    assert response.status_code == 201, response.text
    assert response.json()["duration_seconds"] == seconds
    assert client.get(f"/api/v1/tasks/{task['id']}", headers=headers).json()["actual_duration"] == expected


def test_legacy_creates_generate_ids_without_recording_time(client: TestClient) -> None:
    headers = _headers(client)
    task = _task(client, headers)
    payload = _payload(task["id"])
    payload.pop("session_id")
    payload.pop("record_task_time")
    first = _post(client, headers, payload)
    second = _post(client, headers, payload)
    assert first.status_code == second.status_code == 201
    assert first.json()["id"] != second.json()["id"]
    assert client.get(f"/api/v1/tasks/{task['id']}", headers=headers).json()["actual_duration"] is None


def test_accounting_adds_to_existing_task_time(client: TestClient) -> None:
    headers = _headers(client)
    task = _task(client, headers)
    response = client.patch(
        f"/api/v1/tasks/{task['id']}/time", headers=headers, json={"minutes": 7},
    )
    assert response.status_code == 200, response.text
    payload = _payload(task["id"])
    assert _post(client, headers, payload).status_code == 201
    assert _post(client, headers, payload).status_code == 201
    assert client.get(f"/api/v1/tasks/{task['id']}", headers=headers).json()["actual_duration"] == 9


def test_stable_id_without_flag_does_not_record_time(client: TestClient) -> None:
    headers = _headers(client)
    task = _task(client, headers)
    payload = _payload(task["id"])
    payload.pop("record_task_time")
    assert _post(client, headers, payload).status_code == 201
    # Without persisted accounting metadata, changing the flag never adds time on replay.
    payload["record_task_time"] = True
    assert _post(client, headers, payload).status_code == 201
    assert client.get(f"/api/v1/tasks/{task['id']}", headers=headers).json()["actual_duration"] is None


@pytest.mark.parametrize("field, value", [
    ("duration_seconds", 126),
    ("category", "Different"),
    ("started_at", "2026-01-02T09:59:00+00:00"),
    ("ended_at", "2026-01-02T10:03:00+00:00"),
    ("task_id", None),
])
def test_changed_payload_conflicts(client: TestClient, field: str, value) -> None:
    headers = _headers(client)
    task = _task(client, headers)
    payload = _payload(task["id"])
    assert _post(client, headers, payload).status_code == 201
    response = _post(client, headers, {**payload, field: value})
    assert response.status_code == 409, response.text
    assert client.get(f"/api/v1/tasks/{task['id']}", headers=headers).json()["actual_duration"] == 2


def test_equivalent_payload_replays(client: TestClient) -> None:
    headers = _headers(client)
    payload = _payload()
    first = _post(client, headers, payload)
    payload.pop("duration_seconds")
    payload["category"] = " Work "
    payload["started_at"] = "2026-01-02T11:00:00+01:00"
    payload["ended_at"] = "2026-01-02T11:02:05+01:00"
    retry = _post(client, headers, payload)
    assert first.status_code == retry.status_code == 201
    assert first.json() == retry.json()


def test_foreign_session_collision_is_account_isolated(client: TestClient) -> None:
    owner = _headers(client)
    payload = _payload()
    assert _post(client, owner, payload).status_code == 201
    other = _headers(client, "other-idempotency@test.dev")
    other_task = _task(client, other)
    response = _post(client, other, {**payload, "task_id": other_task["id"]})
    assert response.status_code == 409, response.text
    assert response.json() == {"detail": "Focus session ID is unavailable"}
    assert client.get("/api/v1/focus/sessions", headers=other).json() == []
    assert client.get(f"/api/v1/tasks/{other_task['id']}", headers=other).json()["actual_duration"] is None


@pytest.mark.parametrize("kind", ["unknown", "foreign", "deleted"])
@pytest.mark.parametrize("record_time", [True, False])
def test_invalid_task_rejected(client: TestClient, kind: str, record_time: bool) -> None:
    headers = _headers(client)
    if kind == "unknown":
        task_id = str(uuid.uuid4())
    else:
        owner = _headers(client, "task-owner@test.dev") if kind == "foreign" else headers
        task_id = _task(client, owner)["id"]
        if kind == "deleted":
            assert client.delete(f"/api/v1/tasks/{task_id}", headers=owner).status_code == 200
    response = _post(client, headers, {**_payload(task_id), "record_task_time": record_time})
    assert response.status_code == 404, response.text
    assert response.json() == {"detail": "Task not found"}
    assert client.get("/api/v1/focus/sessions", headers=headers).json() == []


def test_failure_rolls_back_session_task_and_sync_log(client: TestClient, monkeypatch) -> None:
    headers = _headers(client)
    task = _task(client, headers)
    payload = FocusSessionCreate.model_validate(_payload(task["id"]))
    with SessionLocal() as db:
        def fail_commit():
            db.flush()  # Exercise rollback after both writes and sync hooks have run.
            raise RuntimeError("injected commit failure")

        monkeypatch.setattr(db, "commit", fail_commit)
        with pytest.raises(RuntimeError, match="injected commit failure"):
            FocusService(db, user_id=uuid.UUID(task["user_id"])).create_focus_session(payload)
        assert db.is_active
    with SessionLocal() as db:
        assert db.get(FocusSession, payload.session_id) is None
        unchanged = db.get(Task, uuid.UUID(task["id"]))
        assert unchanged.actual_duration is None
        assert unchanged.revision == task["revision"]
        assert db.scalar(select(func.count()).select_from(SyncChange)) == 1
    assert _post(client, headers, payload.model_dump(mode="json")).status_code == 201


@pytest.mark.parametrize("same_id", [True, False])
def test_overlapping_creates_are_safe(client: TestClient, monkeypatch, same_id: bool) -> None:
    headers = _headers(client)
    task = _task(client, headers)
    payloads = [_payload(task["id"]), _payload(task["id"])]
    if same_id:
        payloads[1] = dict(payloads[0])
        barrier = Barrier(2)
        original_get = focus_session_repository.get_focus_session

        def overlapping_get(db, **kwargs):
            result = original_get(db, **kwargs)
            if result is None:
                barrier.wait(timeout=10)  # Both observe a missing session before inserting.
            return result

        monkeypatch.setattr(focus_session_repository, "get_focus_session", overlapping_get)
    else:
        barrier = Barrier(2)

    def create(payload):
        with SessionLocal() as db:
            if not same_id:
                barrier.wait(timeout=10)
            return FocusService(db, user_id=uuid.UUID(task["user_id"])).create_focus_session(
                FocusSessionCreate.model_validate(payload),
            )

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(create, payloads))
    assert (results[0].id == results[1].id) is same_id
    expected_count = 1 if same_id else 2
    assert client.get(f"/api/v1/tasks/{task['id']}", headers=headers).json()["actual_duration"] == 2 * expected_count
    assert len(client.get("/api/v1/focus/sessions", headers=headers).json()) == expected_count


def test_deleted_session_retry_recreates_known_limitation(client: TestClient) -> None:
    headers = _headers(client)
    task = _task(client, headers)
    payload = _payload(task["id"])
    assert _post(client, headers, payload).status_code == 201
    assert client.delete(f"/api/v1/focus/sessions/{payload['session_id']}", headers=headers).status_code == 200
    assert _post(client, headers, payload).status_code == 201
    assert client.get(f"/api/v1/tasks/{task['id']}", headers=headers).json()["actual_duration"] == 4
