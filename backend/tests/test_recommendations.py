import importlib
from datetime import date
from datetime import datetime
from datetime import timedelta
from datetime import timezone

import pytest

from app.services.recommendation_service import RecommendationService
from app.services.recommendation_service import split_description_into_steps
from app.services.recommendation_service import split_task_into_parts


def _fake_now() -> datetime:
    # Fixed mid-morning UTC so "today's free time" always contains a usable
    # work window regardless of when CI happens to run (the daily endpoint
    # clamps today's window to the current time, so runs near the evening
    # boundary used to yield available_minutes == 0 and flake).
    return datetime(2026, 9, 22, 9, 0, 0, tzinfo=timezone.utc)


class _FakeDatetime(datetime):
    @classmethod
    def now(cls, tz=None):
        return _fake_now()


@pytest.fixture(autouse=True)
def _freeze_clock(monkeypatch):
    for module_name in (
        "app.services.recommendation_service",
        "app.services.scheduling.free_slots",
    ):
        monkeypatch.setattr(
            importlib.import_module(module_name), "datetime", _FakeDatetime
        )


NOW = _fake_now()


def _login(client, email="rec@example.com", name="Rec"):
    response = client.post(
        "/api/v1/auth/dev",
        json={"name": name, "email": email},
    )
    assert response.status_code == 200
    return response.json()


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


def _parse_at(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def _create(client, token, **overrides):
    payload = {"title": "Write report"}
    payload.update(overrides)
    response = client.post("/api/v1/tasks", json=payload, headers=_auth(token))
    assert response.status_code == 201
    return response.json()


class TestSplitHelpers:
    def test_numbered_steps(self):
        steps = split_description_into_steps(
            "1. Gather data\n2. Analyze\n3. Write summary"
        )
        assert len(steps) == 3
        assert steps[0] == "Gather data"

    def test_bullet_steps(self):
        steps = split_description_into_steps("- Draft outline\n- Review sources")
        assert len(steps) == 2

    def test_prose_sentences(self):
        steps = split_description_into_steps("First do research. Then write it up.")
        assert len(steps) == 2

    def test_chunk_without_description(self):
        parts = split_task_into_parts("Big task", None, 200)
        assert len(parts) == 3
        assert sum(p["minutes"] for p in parts) == 200

    def test_single_part_small_task(self):
        parts = split_task_into_parts("Quick", None, 30)
        assert len(parts) == 1

    def test_description_parts_cover_total(self):
        description = "Step one here. Step two follows. Step three ends it."
        parts = split_task_into_parts("Task", description, 90)
        assert len(parts) == 3
        assert sum(p["minutes"] for p in parts) == 90

    def test_description_steps_never_inflate_the_estimate(self):
        # Regression: four steps against a 30 minute budget used to be floored
        # to 15 minutes each, producing 60 minutes of work from a 30 minute
        # task. The minimum must not be re-applied once the budget is spent.
        description = "1. Research\n2. Outline\n3. Write\n4. Polish"
        parts = split_task_into_parts("Essay", description, 30)
        assert len(parts) == 4
        assert sum(p["minutes"] for p in parts) == 30

    @pytest.mark.parametrize("minutes", [15, 20, 30, 45, 60, 90, 120, 200])
    @pytest.mark.parametrize("step_count", [2, 3, 4, 5, 6, 8])
    def test_parts_are_a_partition_of_the_budget(
        self, minutes, step_count
    ):
        description = "\n".join(
            f"{i + 1}. Step {i + 1}" for i in range(step_count)
        )
        parts = split_task_into_parts("Task", description, minutes)
        # MIN_PART_MINUTES floors the budget for very short tasks, and a single
        # step is not a breakdown, but the parts must always sum to the budget
        # that was actually planned.
        planned = max(15, minutes)
        assert sum(p["minutes"] for p in parts) == planned
        assert all(p["minutes"] > 0 for p in parts)
        assert [p["index"] for p in parts] == list(range(len(parts)))

    @pytest.mark.parametrize("minutes", [15, 30, 90, 200, 365])
    def test_chunked_parts_cover_total(self, minutes):
        parts = split_task_into_parts("Task", None, minutes)
        assert sum(p["minutes"] for p in parts) == max(15, minutes)
        assert all(p["minutes"] <= 90 for p in parts)


class TestEligibleDays:
    def _dates(self, start=date(2026, 9, 1), end=date(2026, 9, 30)):
        days = []
        cursor = start
        while cursor <= end:
            days.append(cursor)
            cursor += timedelta(days=1)
        return days

    def test_window_starting_before_today_never_eligible(self):
        from types import SimpleNamespace

        # Frozen "today" is 2026-09-22. A window starting 2026-09-01 must not
        # expose any day before today, or the anchor would fill the past and
        # leave today empty.
        eligible = RecommendationService._eligible_days(
            SimpleNamespace(deadline=None),
            self._dates(),
            timezone.utc,
            date(2026, 9, 1),
            date(2026, 9, 30),
        )
        assert eligible[0] == 21  # index of 2026-09-22
        assert eligible[-1] == 29

    def test_overdue_task_restricted_to_earliest_usable_days(self):
        from types import SimpleNamespace

        overdue = SimpleNamespace(
            deadline=datetime(2026, 9, 10, 12, 0, tzinfo=timezone.utc)
        )
        eligible = RecommendationService._eligible_days(
            overdue,
            self._dates(),
            timezone.utc,
            date(2026, 9, 1),
            date(2026, 9, 30),
        )
        assert eligible == [21, 22], (
            "overdue work must land on today/tomorrow, not the elapsed "
            f"start of the window: {eligible}"
        )


class TestFindFreeSlots:
    def test_elapsed_days_are_not_free(self):
        from app.services.scheduling.free_slots import find_free_slots

        slots = find_free_slots(
            dates=[date(2026, 9, 20), date(2026, 9, 21), date(2026, 9, 22)],
            busy=[],
            start_hour=9,
            end_hour=17,
            timezone="UTC",
        )
        days = {slot.start.date() for slot in slots}
        assert days == {date(2026, 9, 22)}


class TestDailyRecommendationsEndpoint:
    def _daily(self, client, token, **overrides):
        payload = {
            "timezone": "UTC",
            "start_date": "2026-09-22",
            "end_date": "2026-09-22",
        }
        payload.update(overrides)
        response = client.post(
            "/api/v1/recommendations/daily", json=payload, headers=_auth(token)
        )
        assert response.status_code == 200, response.text
        return response.json()

    def _preferences(self, client, token, **overrides):
        payload = {"work_hours_start": 9, "work_hours_end": 17, "buffer_minutes": 0}
        payload.update(overrides)
        response = client.put("/api/v1/preferences", json=payload, headers=_auth(token))
        assert response.status_code == 200, response.text

    @pytest.mark.parametrize("date_value, zone, expected", [
        ("2026-09-23T00:00:00Z", "America/Los_Angeles", "2026-09-22"),
        ("2026-09-22T23:00:00Z", "Asia/Tokyo", "2026-09-23"),
        ("2026-09-22", "America/Los_Angeles", "2026-09-22"),
        ("2026-09-22T00:00:00", "Asia/Tokyo", "2026-09-22"),
    ])
    def test_boundaries_use_request_calendar_day(self, client, date_value, zone, expected):
        token = _login(client)["access_token"]
        body = self._daily(client, token, timezone=zone, start_date=date_value, end_date=date_value)
        assert [day["date"] for day in body["days"]] == [expected]

    @pytest.mark.parametrize("payload", [
        {"timezone": "Not/AZone"},
        {"start_date": "2026-09-23", "end_date": "2026-09-22"},
        {"start_date": "2026-09-22", "end_date": "2027-09-23"},
        {"end_date": "2028-09-22"},
    ])
    def test_invalid_ranges_and_timezone_are_422(self, client, payload):
        token = _login(client)["access_token"]
        response = client.post("/api/v1/recommendations/daily", json=payload, headers=_auth(token))
        assert response.status_code == 422

    def test_native_growing_coverage_range_is_supported(self, client):
        token = _login(client)["access_token"]
        body = self._daily(client, token, start_date="2026-09-01", end_date="2027-08-31")
        assert len(body["days"]) == 365
        assert body["days"][0]["date"] == "2026-09-01"

    def test_internal_block_blocks_time_and_reduces_remaining_work(self, client):
        token = _login(client)["access_token"]
        self._preferences(client, token, max_daily_hours=2, buffer_minutes=15)
        task = _create(client, token, estimated_duration=120)
        response = client.post("/api/v1/calendar/blocks", headers=_auth(token), json={
            "task_id": task["id"], "title": "Committed",
            "start_at": "2026-09-22T09:00:00Z", "end_at": "2026-09-22T10:00:00Z",
        })
        assert response.status_code == 201
        body = self._daily(client, token)
        assert body["days"][0]["available_minutes"] == 60
        item, = body["days"][0]["items"]
        assert item["minutes"] == 60
        assert _parse_at(item["start_at"]) == NOW + timedelta(minutes=75)
        # Echoed device busy times must not count committed work a second time.
        echoed = self._daily(client, token, busy_times=[{
            "start": "2026-09-22T09:00:00Z", "end": "2026-09-22T10:00:00Z",
        }])
        assert echoed == body

    def test_fixed_recurrence_local_overrides_and_end_date(self, client):
        token = _login(client)["access_token"]
        self._preferences(client, token, max_daily_hours=2)
        fixed = _create(client, token, title="Weekly", start_at="2026-09-15T09:00:00Z",
                        end_at="2026-09-15T10:00:00Z", repeat_weekdays=[2],
                        repeat_ends_on="2026-09-22T23:00:00Z")
        response = client.patch(f"/api/v1/tasks/{fixed['id']}/occurrence", headers=_auth(token), json={
            "date": "2026-09-22", "scope": "this_event_only", "timezone": "UTC",
            "start_at": "2026-09-22T09:30:00Z", "end_at": "2026-09-22T11:00:00Z",
        })
        assert response.status_code == 200
        _create(client, token, title="Flexible", estimated_duration=30)
        body = self._daily(client, token)
        assert body["days"][0]["available_minutes"] == 30
        item, = body["days"][0]["items"]
        assert _parse_at(item["end_at"]) == NOW + timedelta(minutes=30)
        assert item["task_title"] == "Flexible"
        assert self._daily(client, token, start_date="2026-09-29", end_date="2026-09-29")["days"][0]["available_minutes"] == 120

    def test_fixed_task_is_busy_without_a_calendar_block(self, client):
        token = _login(client)["access_token"]
        self._preferences(client, token)
        _create(client, token, title="Fixed", start_at="2026-09-22T09:00:00Z", end_at="2026-09-22T10:00:00Z")
        _create(client, token, estimated_duration=30)
        item, = self._daily(client, token)["days"][0]["items"]
        assert _parse_at(item["start_at"]) == NOW + timedelta(hours=1)

    def test_recurrence_uses_local_weekday_and_override_key(self, client):
        token = _login(client)["access_token"]
        self._preferences(client, token, max_daily_hours=2)
        # UTC Wednesday, but Tuesday evening in Los Angeles. The recurring
        # Tuesday event must occupy Tuesday's local work window.
        fixed = _create(
            client, token, title="Local weekly", repeat_weekdays=[2],
            start_at="2026-09-16T01:00:00Z", end_at="2026-09-16T02:00:00Z",
        )
        response = client.patch(
            f"/api/v1/tasks/{fixed['id']}/occurrence", headers=_auth(token), json={
                "date": "2026-09-22", "scope": "this_event_only",
                "timezone": "America/Los_Angeles",
                "start_at": "2026-09-22T16:00:00Z", "end_at": "2026-09-22T17:00:00Z",
            },
        )
        assert response.status_code == 200
        _create(client, token, estimated_duration=60)
        body = self._daily(client, token, timezone="America/Los_Angeles")
        assert body["days"][0]["available_minutes"] == 60
        item, = body["days"][0]["items"]
        assert _parse_at(item["start_at"]) == _parse_at("2026-09-22T17:00:00Z")

    def test_failed_allocation_does_not_consume_slots(self, client):
        token = _login(client)["access_token"]
        self._preferences(client, token, work_hours_end=10)
        _create(client, token, title="Cannot finish", estimated_duration=120, priority="high")
        _create(client, token, title="Fits", estimated_duration=60)
        body = self._daily(client, token)
        assert [item["task_title"] for item in body["days"][0]["items"]] == ["Fits"]
        assert len(body["unscheduled"]) == 2

    @pytest.mark.parametrize("zone, moved_start, moved_end", [
        ("UTC", "2026-09-23T09:00:00Z", "2026-09-23T10:00:00Z"),
        ("America/Los_Angeles", "2026-09-23T16:00:00Z", "2026-09-23T17:00:00Z"),
    ])
    def test_moved_override_preserves_absolute_dates(
        self, client, zone, moved_start, moved_end
    ):
        token = _login(client)["access_token"]
        self._preferences(client, token, max_daily_hours=2)
        fixed = _create(
            client, token, title="Moved weekly", repeat_weekdays=[2],
            start_at="2026-09-15T16:00:00Z", end_at="2026-09-15T17:00:00Z",
        )
        response = client.patch(
            f"/api/v1/tasks/{fixed['id']}/occurrence", headers=_auth(token), json={
                "date": "2026-09-22", "scope": "this_event_only", "timezone": zone,
                "start_at": moved_start, "end_at": moved_end,
            },
        )
        assert response.status_code == 200
        _create(client, token, title="Flexible", estimated_duration=60)

        original = self._daily(client, token, timezone=zone)
        assert original["days"][0]["available_minutes"] == 120
        # The source date is outside this single-day request, and Wednesday
        # is not a repeat weekday. The absolute override must still be busy.
        moved = self._daily(
            client, token, timezone=zone,
            start_date="2026-09-23", end_date="2026-09-23",
        )
        assert moved["days"][0]["available_minutes"] == 60
        item, = moved["days"][0]["items"]
        assert _parse_at(item["start_at"]) == _parse_at(moved_end)

        combined = self._daily(
            client, token, timezone=zone, end_date="2026-09-23"
        )
        assert [day["available_minutes"] for day in combined["days"]] == [120, 60]

    def test_fragmented_windows_do_not_span_busy_gap(self, client):
        token = _login(client)["access_token"]
        self._preferences(client, token, work_hours_end=11)
        _create(client, token, estimated_duration=60)
        body = self._daily(client, token, busy_times=[{
            "start": "2026-09-22T09:30:00Z", "end": "2026-09-22T10:30:00Z",
        }])
        assert body["days"][0]["available_minutes"] == 60
        assert body["days"][0]["items"] == []
        assert body["unscheduled"][0]["minutes"] == 60

    def test_existing_steps_fit_separate_contiguous_slots(self, client):
        token = _login(client)["access_token"]
        self._preferences(client, token, work_hours_end=11)
        _create(client, token, estimated_duration=60, description="1. Draft\n2. Review")
        body = self._daily(client, token, busy_times=[{
            "start": "2026-09-22T09:30:00Z", "end": "2026-09-22T10:30:00Z",
        }])
        items = body["days"][0]["items"]
        assert [item["part_index"] for item in items] == [0, 1]
        assert [_parse_at(item["start_at"]) for item in items] == [NOW, NOW + timedelta(minutes=90)]
        assert all(_parse_at(item["end_at"]) - _parse_at(item["start_at"]) == timedelta(minutes=item["minutes"]) for item in items)

    @pytest.mark.parametrize("minutes, scheduled", [(30, True), (31, False)])
    def test_exact_deadline_time(self, client, minutes, scheduled):
        token = _login(client)["access_token"]
        self._preferences(client, token)
        _create(client, token, estimated_duration=minutes, deadline="2026-09-22T09:30:00Z")
        body = self._daily(client, token)
        assert bool(body["days"][0]["items"]) is scheduled
        assert bool(body["unscheduled"]) is not scheduled

    def test_small_remaining_duration_and_buffers_are_exact(self, client):
        token = _login(client)["access_token"]
        self._preferences(client, token, buffer_minutes=15)
        first = _create(client, token, estimated_duration=30, priority="high")
        assert client.patch(f"/api/v1/tasks/{first['id']}", json={"actual_duration": 25}, headers=_auth(token)).status_code == 200
        _create(client, token, title="Next", estimated_duration=30)
        items = self._daily(client, token)["days"][0]["items"]
        assert [item["minutes"] for item in items] == [5, 30]
        assert _parse_at(items[1]["start_at"]) - _parse_at(items[0]["end_at"]) == timedelta(minutes=15)

    def test_after_work_hours_has_no_today_recommendations(self, client):
        token = _login(client)["access_token"]
        self._preferences(client, token, work_hours_start=5, work_hours_end=8)
        _create(client, token, estimated_duration=30)
        body = self._daily(client, token)
        assert body["days"][0]["available_minutes"] == 0
        assert body["days"][0]["items"] == []

    def test_requires_authentication(self, client):
        response = client.post("/api/v1/recommendations/daily", json={})
        assert response.status_code == 401

    def test_accepts_iso_datetime_strings(self, client):
        data = _login(client)
        _create(client, data["access_token"], estimated_duration=60)

        response = client.post(
            "/api/v1/recommendations/daily",
            json={
                "timezone": "UTC",
                "start_date": "2026-08-22T07:00:00Z",
                "end_date": "2026-08-29T07:00:00Z",
            },
            headers=_auth(data["access_token"]),
        )
        assert response.status_code == 200

    def test_recommends_tasks_for_today(self, client):
        data = _login(client)
        _create(client, data["access_token"], estimated_duration=60)

        response = client.post(
            "/api/v1/recommendations/daily",
            json={"timezone": "UTC"},
            headers=_auth(data["access_token"]),
        )
        assert response.status_code == 200
        body = response.json()
        today = body["days"][0]
        assert today["available_minutes"] > 0
        assert len(today["items"]) >= 1
        item = today["items"][0]
        assert item["task_title"] == "Write report"
        assert item["minutes"] == 60

    def test_window_starting_before_today_still_fills_today(self, client):
        # Regression: iOS plans from the start of the visible month (a past
        # date when opened mid-month). Past days must not absorb the
        # recommendation, or today is left empty.
        data = _login(client)
        _create(client, data["access_token"], estimated_duration=60)

        response = client.post(
            "/api/v1/recommendations/daily",
            json={
                "timezone": "UTC",
                "start_date": "2026-09-01",
                "end_date": "2026-09-30",
            },
            headers=_auth(data["access_token"]),
        )
        assert response.status_code == 200
        body = response.json()
        today_iso = _fake_now().date().isoformat()
        today_index = next(
            i for i, day in enumerate(body["days"]) if day["date"] == today_iso
        )
        assert any(
            item["task_title"] == "Write report"
            for item in body["days"][today_index]["items"]
        )
        for day in body["days"][:today_index]:
            assert day["items"] == [], (
                f'no recommendations may land on past day {day["date"]}'
            )

    def test_overdue_task_lands_on_today_not_past_days(self, client):
        # Overdue tasks are restricted to the earliest eligible days; when the
        # window begins before today those earliest days must be today (not the
        # already-elapsed start of the window).
        data = _login(client)
        _create(
            client,
            data["access_token"],
            title="Overdue report",
            estimated_duration=60,
            deadline=(datetime(2026, 9, 15, 12, 0, tzinfo=timezone.utc)).isoformat(),
        )

        response = client.post(
            "/api/v1/recommendations/daily",
            json={
                "timezone": "UTC",
                "start_date": "2026-09-01",
                "end_date": "2026-09-30",
            },
            headers=_auth(data["access_token"]),
        )
        assert response.status_code == 200
        body = response.json()
        today_iso = _fake_now().date().isoformat()
        today_items = next(
            day["items"]
            for day in body["days"]
            if day["date"] == today_iso
        )
        assert any(
            item["task_title"] == "Overdue report" for item in today_items
        )
        past_items = [
            item
            for day in body["days"]
            if day["date"] < today_iso
            for item in day["items"]
        ]
        assert past_items == [], "overdue task must be recommended today"

    def test_scheduled_tasks_are_not_recommended(self, client):
        from datetime import timedelta

        data = _login(client)
        future = datetime.now(timezone.utc) + timedelta(days=30)
        _create(
            client,
            data["access_token"],
            title="Fixed Sept event",
            estimated_duration=60,
            start_at=future.isoformat(),
            end_at=(future + timedelta(hours=1)).isoformat(),
        )
        response = client.post(
            "/api/v1/recommendations/daily",
            json={"timezone": "UTC"},
            headers=_auth(data["access_token"]),
        )
        assert response.status_code == 200
        items = [
            item
            for day in response.json()["days"]
            for item in day["items"]
        ]
        assert all(item["task_title"] != "Fixed Sept event" for item in items)


    def test_completed_tasks_not_recommended(self, client):
        data = _login(client)
        created = _create(
            client,
            data["access_token"],
            estimated_duration=60,
        )
        client.post(
            f"/api/v1/tasks/{created['id']}/complete",
            json={},
            headers=_auth(data["access_token"]),
        )

        response = client.post(
            "/api/v1/recommendations/daily",
            json={"timezone": "UTC"},
            headers=_auth(data["access_token"]),
        )
        assert response.status_code == 200
        items = [i for day in response.json()["days"] for i in day["items"]]
        assert all(i["task_title"] != "Write report" for i in items)

    def test_priority_ordering(self, client):
        data = _login(client)
        _create(client, data["access_token"], title="Low first", priority="low")
        _create(client, data["access_token"], title="High later", priority="high")

        response = client.post(
            "/api/v1/recommendations/daily",
            json={"timezone": "UTC"},
            headers=_auth(data["access_token"]),
        )
        titles = [i["task_title"] for i in response.json()["days"][0]["items"]]
        if "High later" in titles and "Low first" in titles:
            assert titles.index("High later") < titles.index("Low first")

    def test_deadline_ordering(self, client):
        data = _login(client)
        soon = (NOW + timedelta(days=1)).isoformat()
        late = (NOW + timedelta(days=10)).isoformat()
        _create(client, data["access_token"], title="Late deadline", deadline=late)
        _create(client, data["access_token"], title="Soon deadline", deadline=soon)

        response = client.post(
            "/api/v1/recommendations/daily",
            json={"timezone": "UTC"},
            headers=_auth(data["access_token"]),
        )
        titles = [i["task_title"] for i in response.json()["days"][0]["items"]]
        if "Soon deadline" in titles and "Late deadline" in titles:
            assert titles.index("Soon deadline") < titles.index("Late deadline")

    def test_partially_completed_task_recommends_only_amount_left(self, client):
        data = _login(client)
        created = _create(
            client,
            data["access_token"],
            title="Partly done",
            estimated_duration=60,
        )
        client.patch(
            f"/api/v1/tasks/{created['id']}",
            json={"actual_duration": 30},
            headers=_auth(data["access_token"]),
        )

        response = client.post(
            "/api/v1/recommendations/daily",
            json={"timezone": "UTC"},
            headers=_auth(data["access_token"]),
        )
        assert response.status_code == 200
        items = [
            item
            for day in response.json()["days"]
            for item in day["items"]
        ]
        part_items = [i for i in items if i["task_title"] == "Partly done"]
        assert part_items
        assert sum(i["minutes"] for i in part_items) == 30

    def test_fully_completed_task_not_recommended(self, client):
        data = _login(client)
        created = _create(
            client,
            data["access_token"],
            title="All done",
            estimated_duration=60,
        )
        client.patch(
            f"/api/v1/tasks/{created['id']}",
            json={"actual_duration": 60},
            headers=_auth(data["access_token"]),
        )

        response = client.post(
            "/api/v1/recommendations/daily",
            json={"timezone": "UTC"},
            headers=_auth(data["access_token"]),
        )
        assert response.status_code == 200
        items = [
            item
            for day in response.json()["days"]
            for item in day["items"]
        ]
        assert all(item["task_title"] != "All done" for item in items)

    def test_work_packs_into_earliest_day(self, client):
        # We deliberately pack earliest days first: every task's full time
        # appears on today (which has plenty of room), not one fanned-out part
        # per future day.
        data = _login(client)
        _create(client, data["access_token"], title="A", estimated_duration=60)
        _create(client, data["access_token"], title="B", estimated_duration=60)
        _create(client, data["access_token"], title="C", estimated_duration=60)

        response = client.post(
            "/api/v1/recommendations/daily",
            json={"timezone": "UTC"},
            headers=_auth(data["access_token"]),
        )
        assert response.status_code == 200
        body = response.json()
        titles = [i["task_title"] for i in body["days"][0]["items"]]
        assert titles == ["A", "B", "C"]
        later_titles = [
            i["task_title"]
            for day in body["days"][1:]
            for i in day["items"]
        ]
        assert later_titles == [], (
            "tasks with room on today must not spill onto later days"
        )

    def test_far_deadline_task_packs_before_deadline(self, client):
        data = _login(client)
        far = (NOW + timedelta(days=14)).isoformat()
        near = (NOW + timedelta(days=1)).isoformat()
        _create(client, data["access_token"], title="Near", estimated_duration=60, deadline=near)
        _create(client, data["access_token"], title="Far", estimated_duration=480, deadline=far)

        response = client.post(
            "/api/v1/recommendations/daily",
            json={"timezone": "UTC"},
            headers=_auth(data["access_token"]),
        )
        assert response.status_code == 200
        days = response.json()["days"]
        far_day_indices = [
            index
            for index, day in enumerate(days)
            if any(i["task_title"] == "Far" for i in day["items"])
        ]
        assert far_day_indices and far_day_indices[0] == 0, (
            "far-deadline work packs from today, not a later spread-out anchor"
        )
        assert sum(
            i["minutes"]
            for day in days
            for i in day["items"]
            if i["task_title"] == "Far"
        ) == 480

    def test_parts_scheduled_in_order(self, client):
        data = _login(client)
        far = (NOW + timedelta(days=14)).isoformat()
        _create(
            client,
            data["access_token"],
            title="Big build",
            estimated_duration=540,
            deadline=far,
        )

        response = client.post(
            "/api/v1/recommendations/daily",
            json={"timezone": "UTC"},
            headers=_auth(data["access_token"]),
        )
        assert response.status_code == 200
        body = response.json()
        scheduled = [
            (day_index, item)
            for day_index, day in enumerate(body["days"])
            for item in day["items"]
            if item["task_title"] == "Big build"
        ]
        assert scheduled
        assert sum(item["minutes"] for _, item in scheduled) == 540
        indices = [item["part_index"] for _, item in scheduled]
        assert indices == sorted(indices), (
            "parts must be scheduled in order (part 9 must never appear "
            "before parts 1-8)"
        )

    def test_parts_of_blocked_task_not_forceplaced(self, client):
        # If an earlier part cannot fit anywhere, later parts of the same task
        # must not show a time block on their own.
        data = _login(client)
        far = (NOW + timedelta(days=14)).isoformat()
        _create(
            client,
            data["access_token"],
            title="One-shot",
            estimated_duration=540,
            deadline=far,
        )

        midnight = NOW.replace(hour=0, minute=0, second=0, microsecond=0)
        response = client.post(
            "/api/v1/recommendations/daily",
            json={
                "timezone": "UTC",
                "start_date": midnight.date().isoformat(),
                "end_date": midnight.date().isoformat(),
                "busy_times": [
                    {
                        "start": midnight.isoformat(),
                        "end": (midnight + timedelta(hours=23)).isoformat(),
                    }
                ],
            },
            headers=_auth(data["access_token"]),
        )
        assert response.status_code == 200
        body = response.json()
        assert body["days"][0]["items"] == []
        assert len(body["unscheduled"]) == 6

    def test_multi_part_task_packs_earliest_day_first(self, client):
        # Big multi-part tasks pack their parts into the earliest eligible day
        # (today) until it is full, spilling forward only when today runs out
        # of room, and the parts must stay in index order.
        data = _login(client)
        far = (NOW + timedelta(days=14)).isoformat()
        _create(
            client,
            data["access_token"],
            title="Big build",
            estimated_duration=540,
            deadline=far,
        )

        response = client.post(
            "/api/v1/recommendations/daily",
            json={"timezone": "UTC"},
            headers=_auth(data["access_token"]),
        )
        assert response.status_code == 200
        body = response.json()
        parts = [
            (day_index, item)
            for day_index, day in enumerate(body["days"])
            for item in day["items"]
            if item["task_title"] == "Big build"
        ]
        assert sum(item["minutes"] for _, item in parts) == 540
        indices = [item["part_index"] for _, item in parts]
        assert indices == sorted(indices), (
            "parts must be scheduled in order (part 9 must never appear "
            "before parts 1-8)"
        )
        part_days = [day_index for day_index, _ in parts]
        assert part_days[0] == 0, (
            "a multi-part task must start packing on the earliest day (today), "
            f"not a later spread-out anchor: first part on day {part_days[0]}"
        )
        assert max(part_days) - min(part_days) <= 1, (
            "parts must fill today before spilling to the next day: "
            f"days used {sorted(set(part_days))}"
        )

    def test_big_multi_part_tasks_respect_daily_cap(self, client):
        # Raw free time cannot override daily caps or the exact deadline.
        data = _login(client)
        deadline = (NOW + timedelta(days=4)).isoformat()
        for title, duration, priority in [
            ("Circuit notes 8-15", 720, "high"),
            ("Circuit TD problem set", 360, "medium"),
            ("Tutorial part 7/8", 300, "medium"),
            ("Notes + problem set/tutorial part 10-15", 900, "low"),
        ]:
            _create(
                client,
                data["access_token"],
                title=title,
                estimated_duration=duration,
                priority=priority,
                deadline=deadline,
            )

        start = NOW.replace(hour=0, minute=0, second=0, microsecond=0)
        busy_times = []
        for offset in range(7):
            day = start + timedelta(days=offset)
            busy_times.append(
                {
                    "start": (day + timedelta(hours=9)).isoformat(),
                    "end": (day + timedelta(hours=11)).isoformat(),
                }
            )
            busy_times.append(
                {
                    "start": (day + timedelta(hours=13)).isoformat(),
                    "end": (day + timedelta(hours=17)).isoformat(),
                }
            )

        response = client.post(
            "/api/v1/recommendations/daily",
            json={
                "timezone": "UTC",
                "start_date": start.date().isoformat(),
                "end_date": (start + timedelta(days=6)).date().isoformat(),
                "busy_times": busy_times,
            },
            headers=_auth(data["access_token"]),
        )
        assert response.status_code == 200
        body = response.json()
        assert body["unscheduled"], "work exceeding capped deadline capacity cannot fit"
        for day in body["days"]:
            assert sum(item["minutes"] for item in day["items"]) <= 480
            for item in day["items"]:
                assert _parse_at(item["end_at"]) <= _parse_at(deadline)
        # Each task's parts appear in order across the window.
        for day_index in range(len(body["days"])):
            seen: dict[str, int] = {}
            for item in body["days"][day_index]["items"]:
                previous = seen.get(item["task_title"])
                assert previous is None or item["part_index"] > previous, (
                    f"{item['task_title']} parts out of order on "
                    f'{body["days"][day_index]["date"]}'
                )
                seen[item["task_title"]] = item["part_index"]

    def test_busy_time_defers_to_unscheduled(self, client):
        data = _login(client)
        _create(client, data["access_token"], estimated_duration=120)

        midnight = NOW.replace(hour=0, minute=0, second=0, microsecond=0)
        response = client.post(
            "/api/v1/recommendations/daily",
            json={
                "timezone": "UTC",
                "start_date": midnight.date().isoformat(),
                "end_date": midnight.date().isoformat(),
                "busy_times": [
                    {
                        "start": midnight.isoformat(),
                        "end": (midnight + timedelta(hours=23)).isoformat(),
                    }
                ],
            },
            headers=_auth(data["access_token"]),
        )
        assert response.status_code == 200
        body = response.json()
        assert body["days"][0]["items"] == []
        assert len(body["unscheduled"]) == 2


class TestBreakdownEndpoint:
    def test_breaks_down_description(self, client):
        data = _login(client)
        task = _create(
            client,
            data["access_token"],
            title="Report",
            estimated_duration=90,
            description="1. Collect data\n2. Build charts\n3. Write prose",
        )

        response = client.post(
            f"/api/v1/recommendations/breakdown/{task['id']}",
            headers=_auth(data["access_token"]),
        )
        assert response.status_code == 200
        body = response.json()
        assert len(body["parts"]) == 3
        assert body["source"] == "description"
        assert sum(p["minutes"] for p in body["parts"]) == 90

    def test_chunks_without_description(self, client):
        data = _login(client)
        task = _create(
            client,
            data["access_token"],
            title="Big job",
            estimated_duration=180,
        )

        response = client.post(
            f"/api/v1/recommendations/breakdown/{task['id']}",
            headers=_auth(data["access_token"]),
        )
        assert response.status_code == 200
        body = response.json()
        assert len(body["parts"]) == 2
        assert sum(p["minutes"] for p in body["parts"]) == 180

    def test_unknown_task_404(self, client):
        data = _login(client)
        response = client.post(
            "/api/v1/recommendations/breakdown/00000000-0000-0000-0000-000000000000",
            headers=_auth(data["access_token"]),
        )
        assert response.status_code == 404
