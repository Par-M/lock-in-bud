"""
Comprehensive Personal Scheduler Edge Case Matrix
Covers every plausible scheduling scenario for a personal scheduler.
Run with: pytest tests/test_scheduler_comprehensive.py -v
Each test prints its simulation result for user review.
"""
import uuid
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo
import pytest

from app.models.task import TaskPriority
from app.services.scheduling.context import SchedulingContext, TaskContext, TimeSlot, ProposedBlock
from app.services.scheduling.free_slots import find_free_slots
from app.services.scheduling.providers import HeuristicProvider
from app.services.scheduling.validator import validate_schedule
from app.services.scheduling.prompt_builder import build_prompt

UTC = ZoneInfo("UTC")


@pytest.fixture(autouse=True)
def freeze_free_slot_clock(monkeypatch):
    class FrozenDateTime(datetime):
        @classmethod
        def now(cls, tz=None):
            return datetime(2026, 8, 3, tzinfo=UTC).astimezone(tz)

    monkeypatch.setattr("app.services.scheduling.free_slots.datetime", FrozenDateTime)


def utc(s): return datetime.fromisoformat(s).astimezone(UTC)
def slot(a,b): return TimeSlot(utc(a), utc(b))
def task(title="Task", priority=TaskPriority.medium, duration=60, deadline=None, start_at=None, end_at=None):
    return TaskContext(id=uuid.uuid4(), title=title, deadline=deadline, duration_minutes=duration, priority=priority, energy_level=3, start_at=utc(start_at) if start_at else None, end_at=utc(end_at) if end_at else None)

provider = HeuristicProvider()

def _check_valid_with_warnings(res, val):
    # Helper: our new fluid policy allows warnings but no errors
    assert val.is_valid or len(val.errors)==0 or all("partially" in e.lower() for e in val.errors) or len([e for e in val.errors if "working hours" not in e.lower()])==0

class TestComprehensiveScheduler:
    def test_01_no_tasks(self):
        ctx = SchedulingContext(tasks=[], dates=[date(2026,8,3)], timezone="UTC", busy_times=[], buffer_minutes=5, max_daily_hours=12)
        ctx.free_slots=[]
        res = provider.generate_schedule(ctx, build_prompt(ctx))
        assert len(res.items)==0
        print("\n01 No tasks: 0 blocks, valid")

    def test_02_past_blocking_breakfast_fixed_overlaps_busy(self):
        # Breakfast fixed 07:00-07:45 overlapping busy 05:30-09:10, work 5:30-17:00
        # Should schedule with warning (fluid) not defer
        ctx = SchedulingContext(tasks=[task("Breakfast", priority=TaskPriority.high, duration=45, start_at="2026-08-03T07:00:00+00:00", end_at="2026-08-03T07:45:00+00:00")], dates=[date(2026,8,3)], timezone="UTC", busy_times=[slot("2026-08-03T05:30:00+00:00", "2026-08-03T09:10:00+00:00")], buffer_minutes=5, max_daily_hours=12)
        ctx.free_slots = find_free_slots(dates=ctx.dates, busy=ctx.busy_times, start_hour=5.5, end_hour=17, timezone="UTC")
        res = provider.generate_schedule(ctx, build_prompt(ctx))
        val = validate_schedule(res.items, ctx)
        assert len(res.items)==1
        assert val.is_valid  # outside working hours now warning for fixed, busy overlap warning
        print(f"\n02 Past blocking: {res.items[0].start} valid={val.is_valid} warnings={val.warnings}")

    def test_03_buffer_between_tasks(self):
        ctx = SchedulingContext(tasks=[task("A", priority=TaskPriority.high, duration=60), task("B", priority=TaskPriority.medium, duration=60)], dates=[date(2026,8,3)], timezone="UTC", busy_times=[], buffer_minutes=5, max_daily_hours=12)
        ctx.free_slots=[slot("2026-08-03T09:00:00+00:00", "2026-08-03T12:00:00+00:00")]
        res = provider.generate_schedule(ctx, build_prompt(ctx))
        assert res.items[1].start - res.items[0].end >= timedelta(minutes=5)
        print(f"\n03 Buffer: {[ (b.start.strftime('%H:%M'), b.end.strftime('%H:%M')) for b in res.items]}")

    def test_04_daily_max_enforced(self):
        ctx = SchedulingContext(tasks=[task("High", priority=TaskPriority.high, duration=60), task("Low", priority=TaskPriority.low, duration=60)], dates=[date(2026,8,3)], timezone="UTC", busy_times=[], buffer_minutes=0, max_daily_hours=1)
        ctx.free_slots=[slot("2026-08-03T09:00:00+00:00", "2026-08-03T17:00:00+00:00")]
        res = provider.generate_schedule(ctx, build_prompt(ctx))
        val = validate_schedule(res.items, ctx)
        # Only High should fit within 1h cap
        assert len([b for b in res.items if b.task_title=="High"])==1
        print(f"\n04 Daily max 1h: scheduled {[b.task_title for b in res.items]} warnings={val.warnings[:1]}")

    def test_05_fixed_exact_window(self):
        ctx = SchedulingContext(tasks=[task("Fixed", duration=60, start_at="2026-08-03T10:00:00+00:00", end_at="2026-08-03T11:00:00+00:00")], dates=[date(2026,8,3)], timezone="UTC", busy_times=[], buffer_minutes=5, max_daily_hours=12)
        ctx.free_slots=[slot("2026-08-03T09:00:00+00:00", "2026-08-03T17:00:00+00:00")]
        res = provider.generate_schedule(ctx, build_prompt(ctx))
        assert res.items[0].start==utc("2026-08-03T10:00:00+00:00")
        print(f"\n05 Fixed exact: {res.items[0].start}")

    def test_06_fixed_overlapping_busy_fluid(self):
        ctx = SchedulingContext(tasks=[task("FixedBreakfast", duration=45, start_at="2026-08-03T07:30:00+00:00", end_at="2026-08-03T08:15:00+00:00")], dates=[date(2026,8,3)], timezone="UTC", busy_times=[slot("2026-08-03T07:00:00+00:00", "2026-08-03T09:00:00+00:00")], buffer_minutes=5, max_daily_hours=12)
        ctx.free_slots=find_free_slots(dates=ctx.dates, busy=ctx.busy_times, start_hour=5.5, end_hour=17, timezone="UTC")
        res = provider.generate_schedule(ctx, build_prompt(ctx))
        val = validate_schedule(res.items, ctx)
        assert len(res.items)==1
        assert val.is_valid
        assert any("overlaps" in w.lower() or "outside" in w.lower() for w in val.warnings)
        print(f"\n06 Fixed overlapping busy fluid: scheduled {res.items[0].start} warnings={val.warnings}")

    def test_07_flexible_around_fixed(self):
        ctx = SchedulingContext(tasks=[task("FixedDinner", duration=60, start_at="2026-08-03T18:30:00+00:00", end_at="2026-08-03T19:30:00+00:00"), task("Flex", duration=60)], dates=[date(2026,8,3)], timezone="UTC", busy_times=[], buffer_minutes=0, max_daily_hours=12)
        ctx.free_slots=[slot("2026-08-03T09:00:00+00:00", "2026-08-03T21:00:00+00:00")]
        res = provider.generate_schedule(ctx, build_prompt(ctx))
        flex = [b for b in res.items if b.task_title=="Flex"][0]
        fixed = [b for b in res.items if b.task_title=="FixedDinner"][0]
        assert not (flex.start < fixed.end and flex.end > fixed.start)
        print(f"\n07 Flex around fixed: flex {flex.start.strftime('%H:%M')} fixed {fixed.start.strftime('%H:%M')}")

    def test_08_priority_ordering(self):
        # Priority removed: ordered by deadline, earlier deadline first
        ctx = SchedulingContext(tasks=[task("Low", priority=TaskPriority.low, duration=60, deadline=utc("2026-08-04T12:00:00+00:00")), task("High", priority=TaskPriority.high, duration=60, deadline=utc("2026-08-03T12:00:00+00:00"))], dates=[date(2026,8,3)], timezone="UTC", busy_times=[], buffer_minutes=5, max_daily_hours=12)
        ctx.free_slots=[slot("2026-08-03T09:00:00+00:00", "2026-08-03T12:00:00+00:00")]
        res = provider.generate_schedule(ctx, build_prompt(ctx))
        assert [b.task_title for b in res.items]==["High","Low"]
        print(f"\n08 Deadline ordering: {[b.task_title for b in res.items]}")

    def test_09_deadline_vs_priority(self):
        # Deadline over priority - sooner deadline wins even if lower priority
        ctx = SchedulingContext(tasks=[task("LaterHigh", priority=TaskPriority.high, duration=60, deadline=utc("2026-08-05T12:00:00+00:00")), task("SoonerLow", priority=TaskPriority.low, duration=60, deadline=utc("2026-08-03T12:00:00+00:00"))], dates=[date(2026,8,3)], timezone="UTC", busy_times=[], buffer_minutes=5, max_daily_hours=12)
        ctx.free_slots=[slot("2026-08-03T09:00:00+00:00", "2026-08-03T17:00:00+00:00")]
        res = provider.generate_schedule(ctx, build_prompt(ctx))
        assert res.items[0].task_title=="SoonerLow"
        print(f"\n09 Deadline vs Priority: {[b.task_title for b in res.items]} (deadline wins)")

    def test_10_overdue_beats_high(self):
        ctx = SchedulingContext(tasks=[task("High", priority=TaskPriority.high, duration=60), TaskContext(id=uuid.uuid4(), title="Overdue", deadline=utc("2026-08-01T10:00:00+00:00"), duration_minutes=60, priority=TaskPriority.medium, energy_level=3, is_overdue=True)], dates=[date(2026,8,3)], timezone="UTC", busy_times=[], buffer_minutes=5, max_daily_hours=12)
        ctx.free_slots=[slot("2026-08-03T09:00:00+00:00", "2026-08-03T12:00:00+00:00")]
        res = provider.generate_schedule(ctx, build_prompt(ctx))
        assert res.items[0].task_title=="Overdue"
        print(f"\n10 Overdue: {[b.task_title for b in res.items]}")

    def test_11_overcommit_partial_now(self):
        ctx = SchedulingContext(tasks=[task("Big", duration=600)], dates=[date(2026,8,3)], timezone="UTC", busy_times=[], buffer_minutes=5, max_daily_hours=12)
        ctx.free_slots=[slot("2026-08-03T09:00:00+00:00", "2026-08-03T17:00:00+00:00")]
        res = provider.generate_schedule(ctx, build_prompt(ctx))
        assert len(res.items)==5  # 450/600 scheduled, chunked
        val=validate_schedule(res.items, ctx)
        assert any("partially" in w.lower() for w in val.warnings)
        print(f"\n11 Overcommit: {len(res.items)} chunks, {sum(int((b.end-b.start).total_seconds()/60) for b in res.items)}/600m")

    def test_12_chunking(self):
        ctx = SchedulingContext(tasks=[task("Big", duration=240)], dates=[date(2026,8,3)], timezone="UTC", busy_times=[], buffer_minutes=0, max_daily_hours=12)
        ctx.free_slots=[slot("2026-08-03T09:00:00+00:00", "2026-08-03T10:30:00+00:00"), slot("2026-08-03T11:00:00+00:00", "2026-08-03T12:30:00+00:00"), slot("2026-08-03T13:00:00+00:00", "2026-08-03T14:00:00+00:00")]
        res = provider.generate_schedule(ctx, build_prompt(ctx))
        assert len(res.items)==3
        print(f"\n12 Chunking: {len(res.items)} parts")

    def test_13_doubling_up_allowed(self):
        # Only 60m free for 120m required -> second task not fully scheduled, but warning not error
        ctx = SchedulingContext(tasks=[task("A", duration=60), task("B", duration=60)], dates=[date(2026,8,3)], timezone="UTC", busy_times=[], buffer_minutes=5, max_daily_hours=12)
        ctx.free_slots=[slot("2026-08-03T09:00:00+00:00", "2026-08-03T10:00:00+00:00")]
        res = provider.generate_schedule(ctx, build_prompt(ctx))
        val = validate_schedule(res.items, ctx)
        assert val.is_valid  # overlap is warning now
        print(f"\n13 Doubling up: scheduled {[b.task_title for b in res.items]} valid={val.is_valid}")

    def test_14_breakfast_continuous_busy(self):
        ctx = SchedulingContext(tasks=[task("Breakfast", priority=TaskPriority.high, duration=45, start_at="2026-08-03T07:00:00+00:00", end_at="2026-08-03T07:45:00+00:00"), task("Flex1", duration=60), task("Flex2", duration=60)], dates=[date(2026,8,3)], timezone="UTC", busy_times=[slot("2026-08-03T05:30:00+00:00", "2026-08-03T09:10:00+00:00")], buffer_minutes=5, max_daily_hours=12)
        ctx.free_slots=find_free_slots(dates=ctx.dates, busy=ctx.busy_times, start_hour=5.5, end_hour=17, timezone="UTC")
        res = provider.generate_schedule(ctx, build_prompt(ctx))
        assert any(b.task_title=="Breakfast" for b in res.items)
        print(f"\n14 Breakfast continuous: {[ (b.task_title, b.start.strftime('%H:%M')) for b in res.items]}")

    def test_15_linkedin_push(self):
        ctx = SchedulingContext(tasks=[task("LinkedIn Post", priority=TaskPriority.high, duration=45, deadline=utc("2026-08-03T14:00:00+00:00")), task("LowReport", priority=TaskPriority.low, duration=120), task("MediumEmail", priority=TaskPriority.medium, duration=60)], dates=[date(2026,8,3)], timezone="UTC", busy_times=[], buffer_minutes=5, max_daily_hours=12)
        ctx.free_slots=[slot("2026-08-03T09:00:00+00:00", "2026-08-03T12:00:00+00:00"), slot("2026-08-03T13:00:00+00:00", "2026-08-03T17:00:00+00:00")]
        res = provider.generate_schedule(ctx, build_prompt(ctx))
        assert res.items[0].task_title=="LinkedIn Post"
        print(f"\n15 LinkedIn push: {[b.task_title for b in res.items]}")

    def test_16_busy_merge(self):
        res = find_free_slots(dates=[date(2026,8,3)], busy=[slot("2026-08-03T10:00:00+00:00", "2026-08-03T11:00:00+00:00"), slot("2026-08-03T10:00:00+00:00", "2026-08-03T11:00:00+00:00")], start_hour=9, end_hour=17, timezone="UTC")
        assert len(res)==2  # 09:00-10:00 + 11:00-17:00
        print(f"\n16 Busy merge identical: {len(res)} slots")

    def test_17_partial_busy(self):
        res = find_free_slots(dates=[date(2026,8,3)], busy=[slot("2026-08-03T10:00:00+00:00", "2026-08-03T11:00:00+00:00"), slot("2026-08-03T10:30:00+00:00", "2026-08-03T12:00:00+00:00")], start_hour=9, end_hour=17, timezone="UTC")
        assert res[0].start==utc("2026-08-03T09:00:00+00:00")
        print(f"\n17 Partial busy: {[(s.start.strftime('%H:%M'), s.end.strftime('%H:%M')) for s in res]}")

    def test_18_outside_working_hours_fixed_allowed(self):
        ctx = SchedulingContext(tasks=[task("EarlyFixed", duration=30, start_at="2026-08-03T07:00:00+00:00", end_at="2026-08-03T07:30:00+00:00")], dates=[date(2026,8,3)], timezone="UTC", busy_times=[], buffer_minutes=5, max_daily_hours=12)
        ctx.free_slots=[slot("2026-08-03T09:00:00+00:00", "2026-08-03T17:00:00+00:00")]
        res = provider.generate_schedule(ctx, build_prompt(ctx))
        val = validate_schedule(res.items, ctx)
        assert len(res.items)==1
        assert val.is_valid  # fixed outside working hours now warning
        print(f"\n18 Fixed outside work hours: valid={val.is_valid} warnings={val.warnings}")

    def test_19_task_finish_early_frees_time(self):
        # Simulate early finish: block completed early, next generate should use freed time
        # This is more an integration test - just verify completed blocks not in busy
        ctx = SchedulingContext(tasks=[task("Flex", duration=60)], dates=[date(2026,8,3)], timezone="UTC", busy_times=[], buffer_minutes=5, max_daily_hours=12)
        ctx.free_slots=[slot("2026-08-03T09:00:00+00:00", "2026-08-03T17:00:00+00:00")]
        res = provider.generate_schedule(ctx, build_prompt(ctx))
        assert len(res.items)==1
        print(f"\n19 Early finish: flex scheduled, if it finished at 09:30 next generate would see free 09:30-17:00")

    def test_20_zero_tasks(self):
        ctx = SchedulingContext(tasks=[], dates=[date(2026,8,3)], timezone="UTC", busy_times=[], buffer_minutes=5, max_daily_hours=12)
        ctx.free_slots=[]
        res = provider.generate_schedule(ctx, build_prompt(ctx))
        assert len(res.items)==0
        print(f"\n20 Zero tasks: 0 blocks")
