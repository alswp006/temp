"""Personal portion calibration.

Two weeks of "what the app estimated vs what the scale said" turns into a
per-category multiplier. It corrects the two systematic biases the vision model
can't see: your canteen's ladle is bigger than standard, and oil absorbed by
fried food is invisible in a photo.

The multiplier is a **median** of the sample ratios and is clamped — one
mis-typed weight shouldn't move a category by 40%.
"""

from __future__ import annotations

import statistics

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import ValidationError
from app.models import Calibration, CalibrationSample, FoodCategory, MealItem, User

MIN_SAMPLES = 3
MULTIPLIER_FLOOR = 0.6
MULTIPLIER_CEILING = 1.6

# 튀김·볶음은 흡수된 기름이 사진에 안 보인다. 개인 보정이 쌓이기 전까지 쓰는
# 카테고리 기본 가중치. (ROADMAP §6 "기름 흡수량 과소추정")
DEFAULT_CATEGORY_HINT: dict[FoodCategory, float] = {
    FoodCategory.MAIN: 1.05,
}


def compute_multiplier(ratios: list[float]) -> float:
    if not ratios:
        return 1.0
    value = statistics.median(ratios)
    return round(max(MULTIPLIER_FLOOR, min(MULTIPLIER_CEILING, value)), 3)


async def add_sample(
    db: AsyncSession,
    *,
    user: User,
    category: FoodCategory,
    estimated_g: float,
    actual_g: float,
    meal_item: MealItem | None = None,
) -> Calibration:
    """Record one scale reading and refresh that category's multiplier."""
    if estimated_g <= 0 or actual_g <= 0:
        raise ValidationError("중량은 0보다 커야 합니다.")

    db.add(
        CalibrationSample(
            user_id=user.id,
            meal_item_id=meal_item.id if meal_item else None,
            category=category,
            estimated_g=estimated_g,
            actual_g=actual_g,
        )
    )
    await db.flush()
    return await refresh_category(db, user=user, category=category)


async def refresh_category(
    db: AsyncSession, *, user: User, category: FoodCategory
) -> Calibration:
    samples = (
        await db.execute(
            select(CalibrationSample).where(
                CalibrationSample.user_id == user.id,
                CalibrationSample.category == category,
            )
        )
    ).scalars().all()

    ratios = [
        s.actual_g / s.estimated_g for s in samples if s.estimated_g > 0
    ]

    row = (
        await db.execute(
            select(Calibration).where(
                Calibration.user_id == user.id, Calibration.category == category
            )
        )
    ).scalar_one_or_none()
    if row is None:
        row = Calibration(user_id=user.id, category=category)
        db.add(row)

    # Below the sample floor we keep the category hint rather than trusting one
    # or two readings.
    if len(ratios) < MIN_SAMPLES:
        row.multiplier = DEFAULT_CATEGORY_HINT.get(category, 1.0)
    else:
        row.multiplier = compute_multiplier(ratios)
    row.sample_n = len(ratios)
    await db.flush()
    return row


async def status(db: AsyncSession, user_id: int) -> list[dict]:
    rows = (
        await db.execute(select(Calibration).where(Calibration.user_id == user_id))
    ).scalars().all()
    by_cat = {r.category: r for r in rows}
    return [
        {
            "category": cat.value,
            "multiplier": by_cat[cat].multiplier if cat in by_cat else 1.0,
            "sample_n": by_cat[cat].sample_n if cat in by_cat else 0,
            "calibrated": cat in by_cat and by_cat[cat].sample_n >= MIN_SAMPLES,
        }
        for cat in FoodCategory
    ]
