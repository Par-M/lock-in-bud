from typing import get_type_hints
from unittest.mock import Mock
from uuid import uuid4

import httpx

from app.api.routes import chat
from app.core.config import settings
from app.db.database import SessionLocal
from app.services.chat_service import ChatService
from app.services.chat_service import SYSTEM_PROMPT
from app.services.scheduling_service import SchedulingService


def test_chat_service_initializes_scheduling_service(monkeypatch):
    post = Mock(side_effect=AssertionError("Unexpected Gemini request"))
    monkeypatch.setattr(httpx, "post", post)
    user_id = uuid4()
    with SessionLocal() as db:
        service = ChatService(db, user_id=user_id)
        assert isinstance(service.schedule_service, SchedulingService)
        for dependency in (
            service.task_service,
            service.schedule_service,
            service.planner_service,
            service.focus_service,
        ):
            assert dependency.db is db
            assert dependency.user_id == user_id
        injected = ChatService(db, user_id=user_id, schedule_service=service.schedule_service)
        assert injected.schedule_service is service.schedule_service
    assert get_type_hints(ChatService.__init__)["schedule_service"] == SchedulingService | None
    post.assert_not_called()


def test_chat_rate_limit_is_per_authenticated_user(client, monkeypatch):
    monkeypatch.setattr(chat, "_user_rate", {})
    monkeypatch.setattr(chat.time, "time", lambda: 1000)
    monkeypatch.setattr(settings, "chat_rate_limit_rpm", 1)
    response = httpx.Response(
        200,
        request=httpx.Request("POST", "https://example.test/gemini"),
        json={"candidates": [{"content": {"parts": [{"text": "Mock reply"}]}}]},
    )
    post = Mock(return_value=response)
    monkeypatch.setattr(httpx, "post", post)

    users = []
    for email in ("chat-a@test.dev", "chat-b@test.dev"):
        login = client.post("/api/v1/auth/dev", json={"name": "Chat Tester", "email": email})
        assert login.status_code == 200, login.text
        data = login.json()
        headers = {"Authorization": f"Bearer {data['access_token']}"}
        conversation = client.post("/api/v1/chat/conversations", headers=headers, json={})
        assert conversation.status_code == 201, conversation.text
        assert conversation.json()["user_id"] == data["user"]["id"]
        users.append((data["user"]["id"], headers, conversation.json()["id"]))

    user_a, headers_a, conversation_a = users[0]
    user_b, headers_b, conversation_b = users[1]
    url_a = f"/api/v1/chat/conversations/{conversation_a}/messages"
    first = client.post(url_a, headers=headers_a, json={"content": "Hello"})
    assert first.status_code == 200, first.text
    assert first.json()["assistant_message"]["content"] == "Mock reply"
    limited = client.post(url_a, headers=headers_a, json={"content": "Again"})
    assert limited.status_code == 429, limited.text
    second_user = client.post(
        f"/api/v1/chat/conversations/{conversation_b}/messages",
        headers=headers_b,
        json={"content": "Hello"},
    )
    assert second_user.status_code == 200, second_user.text
    assert chat._user_rate == {
        user_a: {"count": 2, "window": 1000},
        user_b: {"count": 1, "window": 1000},
    }
    assert post.call_count == 2


def test_chat_prompt_matches_registered_tools():
    with SessionLocal() as db:
        declarations = ChatService(db, user_id=uuid4())._build_tools()[0]["functionDeclarations"]
    prompt_tools = SYSTEM_PROMPT.split("Registered tools", 1)[1].split("\n\n", 1)[0]
    names = {line[2:].split("(", 1)[0] for line in prompt_tools.splitlines() if line.startswith("- ")}
    assert names == {tool["name"] for tool in declarations}
    assert "Tool calls are not executed by this chat" in SYSTEM_PROMPT
