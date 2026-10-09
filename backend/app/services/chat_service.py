from __future__ import annotations

import json
from datetime import datetime
from uuid import UUID
from zoneinfo import ZoneInfo

import httpx

from app.core.config import settings
from app.models.chat import ChatRole
from app.repositories import chat_repository
from app.services.task_service import TaskService
from app.services.scheduling_service import SchedulingService
from app.services.planner_service import PlannerService
from app.services.focus_service import FocusService
from app.services.habit_service import HabitService
from sqlalchemy.orm import Session


SYSTEM_PROMPT = """You are a concise, practical personal assistant for the Lock-in Bud app.

Goals:
- Help plan realistically using task information provided in the conversation.
- Answer questions about tasks and deadlines using that information.
- Tool calls are not executed by this chat. Do not claim to have retrieved data or made changes through tools.
- Be terse, actionable. Cite dates/times when relevant.
- Never fabricate IDs. Ask for clarification if ambiguous.
- Do not make changes outside the available tools.

Registered tools (declarations only; execution is not supported):
- get_tasks(filter: today/upcoming/overdue/all)
- create_task(title, description, estimated_duration_minutes, priority, deadline, category)
- complete_task(task_id)

If actions are needed, propose a short plan for the user rather than claiming to execute it. Keep responses under 4-5 sentences unless asked for detail.
"""


class ChatServiceError(Exception):
    def __init__(self, message: str, *, status_code: int = 400):
        super().__init__(message)
        self.status_code = status_code


class ChatService:
    BASE_URL = "https://generativelanguage.googleapis.com/v1beta"

    def __init__(
        self,
        db: Session,
        *,
        user_id: UUID,
        task_service: TaskService | None = None,
        schedule_service: SchedulingService | None = None,
        planner_service: PlannerService | None = None,
        focus_service: FocusService | None = None,
        habit_service: HabitService | None = None,
    ) -> None:
        self.db = db
        self.user_id = user_id
        self.task_service = task_service or TaskService(db, user_id=user_id)
        self.schedule_service = schedule_service or SchedulingService(db, user_id)
        self.planner_service = planner_service or PlannerService(db, user_id=user_id)
        self.focus_service = focus_service or FocusService(db, user_id=user_id)
        self.habit_service = habit_service or HabitService(db, user_id=user_id)

    def _validate_timezone(self, value: str | None) -> str:
        if not value:
            return "UTC"
        try:
            ZoneInfo(value)
            return value
        except Exception:
            return "UTC"

    def _build_context_snapshot(self, timezone: str | None = None) -> str | None:
        if not settings.chat_include_context:
            return None
        tz = self._validate_timezone(timezone)
        try:
            snapshot: dict[str, Any] = {
                "generated_at": datetime.utcnow().isoformat() + "Z",
                "timezone": tz,
            }
            try:
                today = self.planner_service.today(tz)
                snapshot["today"] = today.model_dump(mode="json") if hasattr(today, "model_dump") else today.dict()
            except Exception:
                pass
            try:
                overdue = self.task_service.list_overdue()
                snapshot["overdue_count"] = len(overdue)
            except Exception:
                pass
            try:
                from datetime import timedelta
                focus = self.focus_service.focus_summary(timedelta(days=1), tz)
                snapshot["focus_summary"] = focus.model_dump(mode="json") if hasattr(focus, "model_dump") else focus.dict()
            except Exception:
                pass
            try:
                habits = self.habit_service.list_habits()
                snapshot["habit_count"] = len(habits)
            except Exception:
                pass
            text = json.dumps(snapshot, indent=2, default=str)
            if len(text) > settings.chat_context_max_chars:
                text = text[: settings.chat_context_max_chars] + "\n... (truncated)"
            return text
        except Exception:
            return None

    def create_conversation(self, title: str | None = None):
        conv = chat_repository.create_conversation(self.db, user_id=self.user_id, title=title)
        if not conv.title and title is None:
            pass
        self.db.commit()
        self.db.refresh(conv)
        return conv

    def list_conversations(self):
        return chat_repository.list_conversations(self.db, user_id=self.user_id)

    def get_conversation(self, conversation_id: UUID):
        conv = chat_repository.get_conversation(self.db, user_id=self.user_id, conversation_id=conversation_id)
        if conv is None:
            raise ChatServiceError("Conversation not found")
        return conv

    def _build_tools(self):
        return [
            {
                "functionDeclarations": [
                    {
                        "name": "get_tasks",
                        "description": "List tasks for the user, optionally filtered.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "filter": {
                                    "type": "string",
                                    "enum": ["today", "upcoming", "overdue", "all"],
                                }
                            },
                        },
                    },
                    {
                        "name": "create_task",
                        "description": "Create a new task.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "title": {"type": "string"},
                                "description": {"type": "string"},
                                "estimated_duration_minutes": {"type": "integer"},
                                "priority": {"type": "string", "enum": ["low", "medium", "high"]},
                                "deadline": {"type": "string"},
                                "category": {"type": "string"},
                            },
                            "required": ["title"],
                        },
                    },
                    {
                        "name": "complete_task",
                        "description": "Mark a task complete.",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "task_id": {"type": "string"},
                            },
                            "required": ["task_id"],
                        },
                    },
                ]
            }
        ]

    def send_message(self, conversation_id: UUID, content: str, timezone: str | None = None):
        conv = self.get_conversation(conversation_id)
        if not settings.gemini_api_key.strip():
            raise ChatServiceError(
                "The assistant is not configured. Set GEMINI_API_KEY on the backend.",
                status_code=503,
            )
        user_msg = chat_repository.add_message(
            self.db, conversation_id=conv.id, role=ChatRole.user, content=content
        )
        if not conv.title:
            try:
                trimmed = content.strip()
                if len(trimmed) > 40:
                    trimmed = trimmed[:37].rstrip() + "..."
                conv.title = trimmed or None
            except Exception:
                pass

        pass  # removed hardcoded shortcut

        history = chat_repository.list_messages(self.db, conversation_id=conv.id)
        context = []
        for m in history[-settings.chat_max_context_messages:]:
            if m.role == ChatRole.user:
                context.append({"role": "user", "parts": [{"text": m.content or ""}]})
            elif m.role == ChatRole.assistant:
                context.append({"role": "model", "parts": [{"text": m.content or ""}]})
            elif m.role == ChatRole.tool_call:
                context.append(
                    {
                        "role": "model",
                        "parts": [
                            {
                                "functionCall": {
                                    "name": m.tool_name or "tool",
                                    "args": m.tool_args or {},
                                }
                            }
                        ],
                    }
                )
            elif m.role == ChatRole.tool_result:
                context.append(
                    {
                        "role": "user",
                        "parts": [
                            {
                                "functionResponse": {
                                    "name": m.tool_name or "tool",
                                    "response": m.tool_result or {},
                                }
                            }
                        ],
                    }
                )

        system_parts = [{"text": SYSTEM_PROMPT}]
        snapshot = self._build_context_snapshot(timezone)
        system_parts = [{"text": SYSTEM_PROMPT}]

        payload = {
            "systemInstruction": {"parts": system_parts},
            "contents": context,
            "generationConfig": {"temperature": 0.2},
            "tools": self._build_tools(),
            "toolConfig": {"functionCallingConfig": {"mode": "NONE"}},
        }

        try:
            resp = httpx.post(
                f"{self.BASE_URL}/models/{settings.gemini_chat_model}:generateContent",
                headers={"x-goog-api-key": settings.gemini_api_key},
                json=payload,
                timeout=45.0,
            )
            resp.raise_for_status()
            data = resp.json()
        except httpx.HTTPStatusError as exc:
            self.db.rollback()
            code = exc.response.status_code
            if code in (401, 403):
                raise ChatServiceError(
                    "Gemini rejected the backend API credentials. Check GEMINI_API_KEY and its API permissions.",
                    status_code=503,
                ) from exc
            if code == 429:
                raise ChatServiceError("The assistant's usage limit was reached. Try again later.", status_code=429) from exc
            raise ChatServiceError("The assistant provider is unavailable. Please try again later.", status_code=502) from exc
        except (httpx.RequestError, ValueError) as exc:
            self.db.rollback()
            raise ChatServiceError("Unable to reach the assistant. Please try again later.", status_code=502) from exc

        assistant_text = ""
        try:
            candidates = data.get("candidates", [{}])
            content_part = candidates[0].get("content", {})
            parts = content_part.get("parts", [])
            for p in parts:
                if "text" in p:
                    assistant_text += p["text"]
        except (AttributeError, IndexError, TypeError):
            assistant_text = ""

        if not assistant_text.strip():
            self.db.rollback()
            raise ChatServiceError("The assistant returned no text. Please try again.", status_code=502)

        assistant_msg = chat_repository.add_message(
            self.db, conversation_id=conv.id, role=ChatRole.assistant, content=assistant_text
        )
        chat_repository.touch_conversation(self.db, conv)
        self.db.commit()
        self.db.refresh(user_msg)
        self.db.refresh(assistant_msg)
        return {"conversation_id": conv.id, "message": user_msg, "assistant_message": assistant_msg}
