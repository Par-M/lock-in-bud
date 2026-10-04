from __future__ import annotations

import json
from typing import Any
from uuid import UUID

import httpx

from app.core.config import settings
from app.models.chat import ChatRole
from app.repositories import chat_repository
from app.services.task_service import TaskService
from app.services.scheduling_service import SchedulingService
from app.services.planner_service import PlannerService
from app.services.focus_service import FocusService
from sqlalchemy.orm import Session


SYSTEM_PROMPT = """You are a concise, practical personal assistant for the Lock-in Bud app.

Goals:
- Help plan realistically using the user's actual tasks, calendar blocks, focus sessions, and preferences.
- Answer questions about tasks, deadlines, blocks, and focus time.
- When asked to take action, prefer calling tools. Only act within the authenticated user's scope.
- Be terse, actionable. Cite dates/times when relevant.
- Never fabricate IDs. Ask for clarification if ambiguous.
- Do not make changes outside the available tools.

Available tools (call only when appropriate):
- get_tasks(filters: today/upcoming/overdue)
- get_calendar_blocks(range_start, range_end)
- get_focus_sessions(range_start, range_end)
- create_task(title, description, estimated_duration_minutes, priority, deadline, category)
- complete_task(task_id, occurrence_date?, timezone?)
- reschedule_task(task_id, minutes_remaining?, reason?, deadline?, timezone?)
- snooze_task(task_id, minutes, timezone)
- complete_occurrence(task_id, date, timezone)

If multiple actions are needed, propose a short plan and execute the most direct first, or call tools in sequence. Keep responses under 4-5 sentences unless asked for detail.
"""


class ChatServiceError(Exception):
    pass


class ChatService:
    BASE_URL = "https://generativelanguage.googleapis.com/v1beta"

    def __init__(
        self,
        db: Session,
        *,
        user_id: UUID,
        task_service: TaskService | None = None,
        schedule_service: ScheduleService | None = None,
        planner_service: PlannerService | None = None,
        focus_service: FocusService | None = None,
    ) -> None:
        self.db = db
        self.user_id = user_id
        self.task_service = task_service or TaskService(db, user_id=user_id)
        self.schedule_service = schedule_service or ScheduleService(db, user_id=user_id)
        self.planner_service = planner_service or PlannerService(db, user_id=user_id)
        self.focus_service = focus_service or FocusService(db, user_id=user_id)

    def create_conversation(self, title: str | None = None):
        conv = chat_repository.create_conversation(self.db, user_id=self.user_id, title=title)
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

    def send_message(self, conversation_id: UUID, content: str):
        conv = self.get_conversation(conversation_id)
        user_msg = chat_repository.add_message(
            self.db, conversation_id=conv.id, role=ChatRole.user, content=content
        )
        self.db.commit()

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

        if not any(c.get("role") == "model" for c in context):
            context.insert(0, {"role": "user", "parts": [{"text": SYSTEM_PROMPT}]})

        payload = {
            "contents": context,
            "generationConfig": {"temperature": 0.2},
            "tools": self._build_tools(),
        }

        try:
            resp = httpx.post(
                f"{self.BASE_URL}/models/{settings.gemini_chat_model}:generateContent",
                params={"key": settings.gemini_api_key} if settings.gemini_api_key else {},
                json=payload,
                timeout=45.0,
            )
            resp.raise_for_status()
            data = resp.json()
        except Exception as e:
            raise ChatServiceError(f"LLM request failed: {e}")

        assistant_text = ""
        try:
            candidates = data.get("candidates", [{}])
            content_part = candidates[0].get("content", {})
            parts = content_part.get("parts", [])
            for p in parts:
                if "text" in p:
                    assistant_text += p["text"]
        except Exception:
            assistant_text = "I had trouble generating a response."

        assistant_msg = chat_repository.add_message(
            self.db, conversation_id=conv.id, role=ChatRole.assistant, content=assistant_text
        )
        chat_repository.touch_conversation(self.db, conv)
        self.db.commit()
        self.db.refresh(user_msg)
        self.db.refresh(assistant_msg)
        return {"conversation_id": conv.id, "message": user_msg, "assistant_message": assistant_msg}
