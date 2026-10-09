"""Assistant protocol tests use the migrated disposable PostgreSQL database."""
import json
from unittest.mock import Mock
from uuid import uuid4
import httpx
import pytest
from sqlalchemy import select
from app.api.routes import chat
from app.core.config import settings
from app.db.database import SessionLocal
from app.models.task import Task
from app.models.chat import ChatMessage, ChatRole
from app.services.chat_service import ChatService


def response(parts):
    return httpx.Response(200, request=httpx.Request("POST", "https://example.test/gemini"), json={"candidates": [{"content": {"parts": parts}}]})


@pytest.fixture
def account(client, monkeypatch):
    monkeypatch.setattr(chat, "_user_rate", {})
    monkeypatch.setattr(settings, "gemini_api_key", "secret-provider-key")
    login = client.post("/api/v1/auth/dev", json={"name": "Test", "email": "tools@test.dev"}).json()
    headers = {"Authorization": f"Bearer {login['access_token']}"}
    conv = client.post("/api/v1/chat/conversations", headers=headers, json={}).json()
    return headers, f"/api/v1/chat/conversations/{conv['id']}", login["user"]["id"]


def test_read_tool_round_trip_and_thought_signature(client, account, monkeypatch):
    headers, url, _ = account
    task = client.post("/api/v1/tasks", headers=headers, json={"title": "Read chapter"}).json()
    call = {"functionCall": {"name": "get_tasks", "args": {"filter": "all"}}, "thoughtSignature": "opaque-signature"}
    post = Mock(side_effect=[response([call]), response([{"text": "Read chapter first."}])])
    monkeypatch.setattr(httpx, "post", post)
    sent = client.post(url + "/messages", headers=headers, json={"content": "What should I do?", "timezone": "America/Toronto"})
    assert sent.status_code == 200, sent.text
    payload = post.call_args_list[1].kwargs["json"]
    assert payload["contents"][-2]["parts"] == [call]
    assert payload["contents"][-1]["parts"][0]["functionResponse"]["response"]["tasks"][0]["id"] == task["id"]
    assert "America/Toronto" in json.dumps(payload["systemInstruction"])
    saved = client.get(url, headers=headers).json()
    assert [m["role"] for m in saved["messages"]] == ["user", "tool_call", "tool_result", "assistant"]
    assert sent.json()["assistant_message"]["tool_result"]["citations"][0]["id"] == task["id"]


def propose(client, account, monkeypatch, name, args):
    headers, url, _ = account
    monkeypatch.setattr(httpx, "post", Mock(side_effect=[response([{"functionCall": {"name": name, "args": args}}]), response([{"text": "Review the proposed action below."}])]))
    sent = client.post(url + "/messages", headers=headers, json={"content": "Please help"})
    assert sent.status_code == 200, sent.text
    return sent.json()["actions"][0]


def test_create_requires_confirmation_and_confirm_is_idempotent(client, account, monkeypatch):
    headers, url, _ = account
    action = propose(client, account, monkeypatch, "create_task", {"title": "Created once", "estimated_duration_minutes": 30})
    assert client.get("/api/v1/tasks", headers=headers).json()["items"] == []
    endpoint = url + f"/actions/{action['action_id']}/confirm"
    first = client.post(endpoint, headers=headers)
    assert first.status_code == 200, first.text
    second = client.post(endpoint, headers=headers)
    assert first.json() == second.json()
    assert len(client.get("/api/v1/tasks", headers=headers).json()["items"]) == 1


def test_cancel_and_cross_account_access(client, account, monkeypatch):
    headers, url, _ = account
    action = propose(client, account, monkeypatch, "create_task", {"title": "Never created"})
    other = client.post("/api/v1/auth/dev", json={"name": "Other", "email": "other@test.dev"}).json()
    denied = client.post(url + f"/actions/{action['action_id']}/confirm", headers={"Authorization": f"Bearer {other['access_token']}"})
    assert denied.status_code == 404
    cancel = client.post(url + f"/actions/{action['action_id']}/cancel", headers=headers)
    assert cancel.json()["status"] == "cancelled"
    assert client.post(url + f"/actions/{action['action_id']}/confirm", headers=headers).json()["status"] == "cancelled"
    assert client.get("/api/v1/tasks", headers=headers).json()["items"] == []


def test_invalid_tool_rolls_back_entire_turn(client, account, monkeypatch):
    headers, url, _ = account
    monkeypatch.setattr(httpx, "post", Mock(return_value=response([{"functionCall": {"name": "complete_task", "args": {"task_id": str(uuid4())}}}])))
    sent = client.post(url + "/messages", headers=headers, json={"content": "Complete it"})
    assert sent.status_code == 422, sent.text
    assert "secret-provider-key" not in sent.text
    assert client.get(url, headers=headers).json()["messages"] == []


def test_round_limit_rolls_back(client, account, monkeypatch):
    headers, url, _ = account
    monkeypatch.setattr(settings, "chat_max_turns", 2)
    post = Mock(return_value=response([{"functionCall": {"name": "get_tasks", "args": {}}}]))
    monkeypatch.setattr(httpx, "post", post)
    result = client.post(url + "/messages", headers=headers, json={"content": "Tasks?"})
    assert result.status_code == 502
    assert post.call_count == 2
    assert post.call_args.kwargs["json"]["toolConfig"]["functionCallingConfig"]["mode"] == "NONE"
    assert client.get(url, headers=headers).json()["messages"] == []


def test_retry_request_id_replays_without_model_call(client, account, monkeypatch):
    headers, url, _ = account
    post = Mock(return_value=response([{"text": "Normal reply"}]))
    monkeypatch.setattr(httpx, "post", post)
    body = {"content": "how do i get an internship", "request_id": str(uuid4())}
    first = client.post(url + "/messages", headers=headers, json=body)
    retry = client.post(url + "/messages", headers=headers, json=body)
    assert first.status_code == retry.status_code == 200
    assert first.json() == retry.json()
    assert post.call_count == 1
    assert client.post(url + "/messages", headers=headers, json={**body, "content": "Different"}).status_code == 409


def test_titles_summaries_management_and_pagination(client, account, monkeypatch):
    headers, url, _ = account
    monkeypatch.setattr(httpx, "post", Mock(return_value=response([{"text": "Reply"}])))
    client.post(url + "/messages", headers=headers, json={"content": "Make a plan"})
    listing = client.get("/api/v1/chat/conversations?limit=1", headers=headers).json()
    assert listing[0]["title"] == "Make a plan"
    assert "messages" not in listing[0]
    page = client.get(url + "/messages?limit=1", headers=headers).json()
    more = client.get(url + "/messages?after=" + page[0]["id"], headers=headers).json()
    assert len(more) == 1 and more[0]["role"] == "assistant"
    assert client.patch(url, headers=headers, json={"title": "Renamed"}).json()["title"] == "Renamed"
    assert client.delete(url, headers=headers).status_code == 200
    assert client.get(url, headers=headers).status_code == 404


def test_memory_requires_confirmation_and_can_be_cleared(client, account, monkeypatch):
    headers, url, _ = account
    action = propose(client, account, monkeypatch, "remember_fact", {"fact": "I study in the morning"})
    assert client.get("/api/v1/chat/memory", headers=headers).json() == {"facts": []}
    confirm = client.post(url + f"/actions/{action['action_id']}/confirm", headers=headers)
    assert confirm.status_code == 200, confirm.text
    assert client.get("/api/v1/chat/memory", headers=headers).json()["facts"] == ["I study in the morning"]
    assert client.delete("/api/v1/chat/memory", headers=headers).json() == {"facts": []}


def test_rate_windows_and_pruning(monkeypatch):
    monkeypatch.setattr(chat, "_user_rate", {"expired": [0], "a": [89999, 89998]})
    monkeypatch.setattr(chat.time, "time", lambda: 90000)
    monkeypatch.setattr(settings, "chat_rate_limit_rpm", 10)
    monkeypatch.setattr(settings, "chat_rate_limit_rph", 2)
    with pytest.raises(Exception) as error:
        chat._rate_limit("a")
    assert error.value.status_code == 429 and int(error.value.headers["Retry-After"]) > 0
    assert "expired" not in chat._user_rate
    monkeypatch.setattr(settings, "chat_rate_limit_rph", 100)
    monkeypatch.setattr(settings, "chat_rate_limit_rpd", 2)
    with pytest.raises(Exception):
        chat._rate_limit("a")


def test_snapshot_is_bounded_valid_json_and_service_failure_isolated(account):
    with SessionLocal() as db:
        service = ChatService(db, user_id=account[2])
        service.planner_service = Mock()
        service.planner_service.today.side_effect = RuntimeError("private failure")
        text = service._build_context_snapshot("UTC")
        assert text is not None and len(text) <= settings.chat_context_max_chars
        assert "private failure" not in text
        assert "today" not in json.loads(text)


def test_complete_recurring_task_only_one_occurrence(client, account, monkeypatch):
    headers, url, _ = account
    task = client.post("/api/v1/tasks", headers=headers, json={"title": "Daily reading", "repeat_weekdays": [0, 1, 2, 3, 4, 5, 6]}).json()
    action = propose(client, account, monkeypatch, "complete_task", {"task_id": task["id"], "occurrence_date": "2026-10-09"})
    result = client.post(url + f"/actions/{action['action_id']}/confirm", headers=headers)
    assert result.status_code == 200, result.text
    task = result.json()["result"]
    assert task["status"] != "completed"
    assert task["repeat_overrides"]["2026-10-09"]["completed"] is True


def test_streaming_uses_sse_and_persists_only_complete_reply(client, account, monkeypatch):
    headers, url, _ = account
    def events(self, payload, streaming):
        assert streaming
        yield {"candidates": [{"content": {"parts": [{"text": "Hello "}]}}]}
        yield {"candidates": [{"content": {"parts": [{"text": "world"}]}}]}
    monkeypatch.setattr(ChatService, "_provider_events", events)
    result = client.post(url + "/messages", headers={**headers, "Accept": "text/event-stream"}, json={"content": "Hello"})
    assert result.status_code == 200
    assert "text/event-stream" in result.headers["content-type"]
    chunks = [json.loads(line[5:]) for line in result.text.splitlines() if line.startswith("data:")]
    assert [c["text"] for c in chunks if c["type"] == "delta"] == ["Hello ", "world"]
    assert chunks[-1]["type"] == "complete"
    assert client.get(url, headers=headers).json()["messages"][-1]["content"] == "Hello world"


def test_stream_failure_rolls_back_partial_reply(client, account, monkeypatch):
    headers, url, _ = account
    def events(self, payload, streaming):
        yield {"candidates": [{"content": {"parts": [{"text": "Partial"}]}}]}
        raise RuntimeError("secret-provider-key")
    monkeypatch.setattr(ChatService, "_provider_events", events)
    result = client.post(url + "/messages/stream", headers=headers, json={"content": "Hello"})
    assert '"type": "error"' in result.text
    assert "secret-provider-key" not in result.text
    assert client.get(url, headers=headers).json()["messages"] == []


def test_confirmation_receipt_failure_rolls_back_service_commit(client, account, monkeypatch):
    headers, url, user = account
    action = propose(client, account, monkeypatch, "create_task", {"title": "Must roll back"})
    from app.repositories import chat_repository
    monkeypatch.setattr(chat_repository, "touch_conversation", Mock(side_effect=RuntimeError("receipt failed")))
    # The endpoint fails, but the nested service commit must not leave a task.
    with pytest.raises(RuntimeError):
        client.post(url + f"/actions/{action['action_id']}/confirm", headers=headers)
    assert client.get("/api/v1/tasks", headers=headers).json()["items"] == []


def test_context_budget_retains_whole_tool_turns(account, monkeypatch):
    from types import SimpleNamespace
    monkeypatch.setattr(settings, "chat_history_max_chars", 9000)
    history = []
    for index in range(20):
        history.extend([SimpleNamespace(role=ChatRole.user, content=f"User {index}: " + "a" * 1000, tool_result=None),
                        SimpleNamespace(role=ChatRole.assistant, content=f"Reply {index}: " + "b" * 1000, tool_result=None)])
    with SessionLocal() as db:
        context = ChatService(db, user_id=account[2])._history_context(history)
    assert len(json.dumps(context)) <= 9000
    assert context[-2]["role"] == "user" and context[-1]["role"] == "model"
    assert "User 19" in json.dumps(context[-2])


def test_unknown_and_cross_user_tools_cannot_read_data(client, account, monkeypatch):
    headers, url, _ = account
    other = client.post("/api/v1/auth/dev", json={"name": "Other", "email": "hidden@test.dev"}).json()
    private = client.post("/api/v1/tasks", headers={"Authorization": f"Bearer {other['access_token']}"}, json={"title": "Private task"}).json()
    call = {"functionCall": {"name": "get_tasks", "args": {}}}
    post = Mock(side_effect=[response([call]), response([{"text": "No tasks"}])])
    monkeypatch.setattr(httpx, "post", post)
    assert client.post(url + "/messages", headers=headers, json={"content": "List tasks"}).status_code == 200
    assert "Private task" not in json.dumps(post.call_args.kwargs["json"])
    monkeypatch.setattr(httpx, "post", Mock(return_value=response([{"functionCall": {"name": "delete_all", "args": {}}}])))
    assert client.post(url + "/messages", headers=headers, json={"content": "Bad tool"}).status_code == 502


def test_invalid_timezone_and_blank_message_are_rejected_before_provider(client, account, monkeypatch):
    headers, url, _ = account
    post = Mock(); monkeypatch.setattr(httpx, "post", post)
    for body in ({"content": "  "}, {"content": "Hi", "timezone": "Invalid/Zone"}):
        assert client.post(url + "/messages", headers=headers, json=body).status_code == 422
    post.assert_not_called()


def test_history_before_cursor_and_cross_conversation_cursor_rejected(client, account, monkeypatch):
    headers, url, _ = account
    monkeypatch.setattr(httpx, "post", Mock(return_value=response([{"text": "Reply"}])))
    sent = client.post(url + "/messages", headers=headers, json={"content": "Hi"}).json()
    page = client.get(url + "/messages?before=" + sent["assistant_message"]["id"], headers=headers).json()
    assert [m["id"] for m in page] == [sent["message"]["id"]]
    other = client.post("/api/v1/chat/conversations", headers=headers, json={}).json()
    denied = client.get(f"/api/v1/chat/conversations/{other['id']}/messages?before=" + sent["message"]["id"], headers=headers)
    assert denied.status_code == 404


def test_compact_keeps_some_tasks_and_valid_json():
    from app.services.chat_service import compact
    result = compact({"tasks": [{"id": str(uuid4()), "title": "x" * 255} for _ in range(30)], "total": 30}, 6000)
    assert 0 < len(result["tasks"]) < 30
    assert result["truncated"]
    assert len(json.dumps(result)) <= 6000
