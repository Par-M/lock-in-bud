"""Pure provider tests; runnable with pytest --noconftest (no database)."""

import json
import traceback
from datetime import date, datetime, timezone
from uuid import UUID

import httpx
import pytest

from app.core.config import settings
from app.services.scheduling.context import SchedulingContext
from app.services.scheduling.providers import GeminiProvider, ProviderError
from app.services.text_analysis import GeminiTextAnalysisProvider, TextAnalysisError


API_KEY = "secret-test-key"
BLOCK = {
    "task_id": "12345678-1234-1234-1234-123456789abc",
    "task_title": "Work",
    "start": "2026-10-05T09:00:00Z",
    "end": "2026-10-05T10:00:00Z",
    "reason": "First available slot",
}
OUTPUTS = {
    "schedule": {"items": [BLOCK], "reasoning": "Ready"},
    "analyze_text": {"insight": "Keep going", "tags": ["productive"]},
    "parse_task": {"title": "Work", "deadline": BLOCK["end"], "estimated_duration": 60},
    "morning_message": {"message": "Start with one task"},
}


def invoke(method, model=None):
    if method == "schedule":
        provider = GeminiProvider(api_key=API_KEY, model=model)
        context = SchedulingContext(tasks=[], dates=[date(2026, 10, 5)], timezone="UTC")
        return provider.generate_schedule(context, "Schedule my tasks")
    provider = GeminiTextAnalysisProvider(api_key=API_KEY, model=model)
    return getattr(provider, method)("Finish work tomorrow")


def response_with_text(text):
    return httpx.Response(
        200,
        request=httpx.Request("POST", "https://example.com/gemini"),
        json={"candidates": [{"content": {"parts": [{"text": text}]}}]},
    )


@pytest.mark.parametrize("method", OUTPUTS)
@pytest.mark.parametrize("model", [None, "custom-model"])
def test_model_and_header_authentication(monkeypatch, method, model):
    monkeypatch.setattr(settings, "gemini_chat_model", "gemini-3.5-flash-lite")

    def post(url, **kwargs):
        assert url.endswith(f"/models/{model or settings.gemini_chat_model}:generateContent")
        assert not httpx.URL(url).query
        assert API_KEY not in url
        assert "params" not in kwargs
        assert kwargs["headers"]["x-goog-api-key"] == API_KEY
        return response_with_text(json.dumps(OUTPUTS[method]))

    monkeypatch.setattr(httpx, "post", post)
    result = invoke(method, model)
    if method == "schedule":
        assert result.items[0].task_id == UUID(BLOCK["task_id"])
        assert result.items[0].start == datetime(2026, 10, 5, 9, tzinfo=timezone.utc)
    elif method == "parse_task":
        assert result.title == "Work"
        assert result.estimated_duration == 60
    elif method == "analyze_text":
        assert result.tags == ["productive"]
    else:
        assert result == "Start with one task"


@pytest.mark.parametrize("method", OUTPUTS)
@pytest.mark.parametrize("status", [400, 401, 403, 404, 429, 500, 503])
def test_http_errors_do_not_expose_secrets(monkeypatch, method, status):
    def post(url, **kwargs):
        return httpx.Response(
            status,
            request=httpx.Request("POST", f"{url}?key={API_KEY}"),
            text=f"Error containing {API_KEY}",
        )

    monkeypatch.setattr(httpx, "post", post)
    error = ProviderError if method == "schedule" else TextAnalysisError
    with pytest.raises(error, match=f"HTTP {status}") as caught:
        invoke(method)
    rendered = "".join(traceback.format_exception(caught.value))
    assert API_KEY not in rendered
    assert "https://" not in str(caught.value)


@pytest.mark.parametrize("method", OUTPUTS)
def test_transport_errors_do_not_expose_secrets(monkeypatch, method):
    def post(url, **kwargs):
        raise httpx.ConnectError(f"Failed {url}?key={API_KEY}")

    monkeypatch.setattr(httpx, "post", post)
    error = ProviderError if method == "schedule" else TextAnalysisError
    with pytest.raises(error, match="Gemini request failed") as caught:
        invoke(method)
    assert API_KEY not in "".join(traceback.format_exception(caught.value))


@pytest.mark.parametrize("method", OUTPUTS)
@pytest.mark.parametrize("payload", [None, [], {}, {"candidates": []}, {"candidates": None}, {"candidates": [None]}, {"candidates": [{"content": {"parts": []}}]}])
def test_invalid_envelope_raises_fallback_error(monkeypatch, method, payload):
    monkeypatch.setattr(
        httpx, "post",
        lambda *args, **kwargs: httpx.Response(
            200, request=httpx.Request("POST", "https://example.com"),
            content=json.dumps(payload),
        ),
    )
    with pytest.raises(ProviderError if method == "schedule" else TextAnalysisError):
        invoke(method)


@pytest.mark.parametrize("method", OUTPUTS)
@pytest.mark.parametrize("raw", ["not json", "null", "[]", "42", '"text"'])
def test_invalid_output_raises_fallback_error(monkeypatch, method, raw):
    monkeypatch.setattr(httpx, "post", lambda *args, **kwargs: response_with_text(raw))
    with pytest.raises(ProviderError if method == "schedule" else TextAnalysisError):
        invoke(method)


@pytest.mark.parametrize("method", OUTPUTS)
def test_invalid_http_json_raises_fallback_error(monkeypatch, method):
    monkeypatch.setattr(
        httpx, "post",
        lambda *args, **kwargs: httpx.Response(
            200, request=httpx.Request("POST", "https://example.com"),
            text=f"not json {API_KEY}",
        ),
    )
    with pytest.raises(ProviderError if method == "schedule" else TextAnalysisError) as caught:
        invoke(method)
    assert API_KEY not in "".join(traceback.format_exception(caught.value))


@pytest.mark.parametrize("field,value", [
    ("task_id", "invalid-uuid"), ("task_id", 123), ("task_id", {}),
    ("start", "invalid-date"), ("end", "2026-99-05"),
    ("start", None), ("end", 123), ("task_title", []), ("reason", {}),
])
def test_invalid_schedule_fields_raise_provider_error(monkeypatch, field, value):
    output = {"items": [{**BLOCK, field: value}]}
    monkeypatch.setattr(httpx, "post", lambda *args, **kwargs: response_with_text(json.dumps(output)))
    with pytest.raises(ProviderError):
        invoke("schedule")


@pytest.mark.parametrize("output", [{}, {"items": None}, {"items": {}}, {"items": [None]}, {"items": [42]}, {"items": [{}]}, {"items": [], "reasoning": {}}])
def test_invalid_schedule_shapes_raise_provider_error(output):
    with pytest.raises(ProviderError):
        GeminiProvider(api_key=API_KEY)._parse_output(json.dumps(output))


@pytest.mark.parametrize("method,output", [
    ("analyze_text", {"insight": []}),
    ("analyze_text", {"tags": "productive"}),
    ("analyze_text", {"tags": [None]}),
    ("morning_message", {"message": {}}),
    ("parse_task", {"title": []}),
    ("parse_task", {"deadline": "invalid-date"}),
    ("parse_task", {"deadline": 123}),
    ("parse_task", {"estimated_duration": []}),
    ("parse_task", {"estimated_duration": True}),
])
def test_invalid_text_fields_raise_fallback_error(monkeypatch, method, output):
    monkeypatch.setattr(httpx, "post", lambda *args, **kwargs: response_with_text(json.dumps(output)))
    with pytest.raises(TextAnalysisError):
        invoke(method)


@pytest.mark.parametrize("failure", ["http", "malformed"])
def test_focus_summary_uses_existing_fallback(monkeypatch, failure):
    from app.services.focus_service import FocusService

    monkeypatch.setattr(settings, "gemini_api_key", API_KEY)

    def post(url, **kwargs):
        if failure == "malformed":
            return response_with_text("[]")
        return httpx.Response(404, request=httpx.Request("POST", url))

    monkeypatch.setattr(httpx, "post", post)
    service = FocusService.__new__(FocusService)
    assert service._analyze_summary(total_seconds=3600, count=2) == service._fallback(minutes=60, count=2)


@pytest.mark.parametrize("failure", ["http", "malformed"])
def test_task_parser_uses_existing_fallback(monkeypatch, failure):
    from app.services.task_service import TaskService

    monkeypatch.setattr(settings, "gemini_api_key", API_KEY)

    def post(url, **kwargs):
        if failure == "malformed":
            return response_with_text('{"deadline": "invalid-date"}')
        return httpx.Response(404, request=httpx.Request("POST", url))

    monkeypatch.setattr(httpx, "post", post)
    monkeypatch.setattr(TaskService, "create_task", lambda self, data: data)
    service = TaskService.__new__(TaskService)
    result = service.parse_task("Finish work tomorrow")
    assert result.title == "Finish work tomorrow"
    assert result.deadline is None
