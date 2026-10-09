from datetime import datetime
from uuid import uuid4


def test_repeat_override_dates_persist_through_patch_and_sync(client):
    login = client.post("/api/v1/auth/dev", json={"name": "Parity", "email": "parity@test.dev"})
    assert login.status_code == 200, login.text
    headers = {"Authorization": f"Bearer {login.json()['access_token']}"}
    created = client.post("/api/v1/tasks", headers=headers, json={"title": "Weekly work", "repeat_weekdays": [1]})
    assert created.status_code == 201, created.text
    task_id = created.json()["id"]
    overrides = {"2026-10-05": {"start_at": "2026-10-06T10:00:00Z", "end_at": "2026-10-06T11:00:00Z"}}
    patched = client.patch(f"/api/v1/tasks/{task_id}", headers=headers, json={"repeat_overrides": overrides})
    assert patched.status_code == 200, patched.text
    pulled = client.get("/api/v1/sync/pull", headers=headers)
    assert pulled.status_code == 200, pulled.text
    latest = [change for change in pulled.json()["changes"] if change["entity_id"] == task_id][-1]
    payload = latest["record"]
    payload["title"] = "Edited from web"
    pushed = client.post("/api/v1/sync/push", headers=headers, json={"operations": [{
        "operation_id": str(uuid4()), "entity": "task", "operation": "upsert",
        "base_revision": latest["revision"], "payload": payload,
    }]})
    assert pushed.status_code == 200, pushed.text
    assert pushed.json()["results"][0]["status"] == "applied"
    saved = client.get(f"/api/v1/tasks/{task_id}", headers=headers)
    assert saved.status_code == 200, saved.text
    assert saved.json()["title"] == "Edited from web"
    actual = saved.json()["repeat_overrides"]["2026-10-05"]["start_at"]
    assert datetime.fromisoformat(actual.replace("Z", "+00:00")) == datetime.fromisoformat("2026-10-06T10:00:00+00:00")
