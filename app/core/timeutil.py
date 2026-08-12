"""Time helpers.

Everything is stored UTC-aware. "Which day is this?" is always answered in the
user's timezone — a 23:40 snack in Seoul belongs to that Seoul day, not to the
UTC day it happens to fall in.
"""

from __future__ import annotations

from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from app.models import MealType

UTC = timezone.utc

# Shot-time → meal slot. Anything outside these windows is a snack.
MEAL_WINDOWS: list[tuple[int, int, MealType]] = [
    (5, 10, MealType.BREAKFAST),
    (11, 14, MealType.LUNCH),
    (17, 21, MealType.DINNER),
]


def utcnow() -> datetime:
    return datetime.now(tz=UTC)


def tz_of(name: str | None) -> ZoneInfo:
    try:
        return ZoneInfo(name or "Asia/Seoul")
    except (ZoneInfoNotFoundError, ValueError):
        return ZoneInfo("Asia/Seoul")


def ensure_aware(dt: datetime, tz_name: str | None = None) -> datetime:
    """Treat a naive datetime as local wall-clock in the user's timezone."""
    if dt.tzinfo is None:
        return dt.replace(tzinfo=tz_of(tz_name))
    return dt


def to_local(dt: datetime, tz_name: str | None) -> datetime:
    return ensure_aware(dt, tz_name).astimezone(tz_of(tz_name))


def local_date(dt: datetime, tz_name: str | None) -> date:
    return to_local(dt, tz_name).date()


def today_local(tz_name: str | None) -> date:
    return datetime.now(tz=tz_of(tz_name)).date()


def infer_meal_type(dt: datetime, tz_name: str | None) -> MealType:
    hour = to_local(dt, tz_name).hour
    for start, end, meal in MEAL_WINDOWS:
        if start <= hour <= end:
            return meal
    return MealType.SNACK


def week_start(d: date) -> date:
    """Monday of the week containing ``d``."""
    return d - timedelta(days=d.weekday())


def date_range(start: date, end: date) -> list[date]:
    if end < start:
        return []
    return [start + timedelta(days=i) for i in range((end - start).days + 1)]
