"""내 식사 세트 — repeat meals in one tap.

This is the generalisation that keeps the product out of the "급식 앱" box.
급식 is one case of "메뉴가 반복되는 식사"; 구내식당, 학식, 집밥 루틴, 단골 식당,
밀프렙 are the others, and they all want the same affordance: record it once,
then re-apply it forever.
"""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.timeutil import infer_meal_type, local_date, utcnow
from app.errors import Conflict, NotFound, ValidationError
from app.models import (
    EntrySource,
    Food,
    FoodCategory,
    Meal,
    MealItem,
    MealSet,
    MealStatus,
    MealType,
    User,
)


def _serialise_items(items: list[MealItem]) -> list[dict]:
    return [
        {
            "name": i.name,
            "category": i.category.value,
            "food_id": i.food_id,
            "final_g": i.final_g,
            "kcal": i.kcal,
            "carb_g": i.carb_g,
            "protein_g": i.protein_g,
            "fat_g": i.fat_g,
        }
        for i in items
    ]


async def create_from_meal(
    db: AsyncSession, *, user: User, meal: Meal, name: str
) -> MealSet:
    """Freeze a meal into a reusable set.

    The item list is denormalised into ``payload`` on purpose: deleting the
    original meal must not break the set built from it.
    """
    name = name.strip()
    if not name:
        raise ValidationError("세트 이름이 필요합니다.")

    dupe = (
        await db.execute(
            select(MealSet).where(MealSet.user_id == user.id, MealSet.name == name)
        )
    ).scalar_one_or_none()
    if dupe:
        raise Conflict("같은 이름의 세트가 이미 있습니다.")

    items = (
        await db.execute(select(MealItem).where(MealItem.meal_id == meal.id))
    ).scalars().all()
    if not items:
        raise ValidationError("항목이 없는 식사로는 세트를 만들 수 없습니다.")

    meal_set = MealSet(
        user_id=user.id,
        name=name,
        source_meal_id=meal.id,
        default_meal_type=meal.meal_type,
        payload={"items": _serialise_items(list(items))},
    )
    db.add(meal_set)
    await db.flush()
    return meal_set


async def create_manual(
    db: AsyncSession, *, user: User, name: str, items: list[dict]
) -> MealSet:
    """Build a set from scratch (no source meal), resolving foods as we go."""
    from app.services import nutrition

    if not items:
        raise ValidationError("항목이 비어 있습니다.")

    resolved: list[dict] = []
    for raw in items:
        item_name = (raw.get("name") or "").strip()
        if not item_name:
            continue
        category = (
            FoodCategory(raw["category"])
            if raw.get("category")
            else nutrition.guess_category(item_name)
        )
        food = (
            await db.get(Food, raw["food_id"])
            if raw.get("food_id")
            else await nutrition.resolve_food(db, item_name)
        )
        grams = float(
            raw.get("final_g")
            or (food.default_serving_g if food else nutrition.STANDARD_PORTION_G.get(category, 100.0))
        )
        macros = nutrition.macros_for(food, grams)
        resolved.append(
            {
                "name": item_name,
                "category": category.value,
                "food_id": food.id if food else None,
                "final_g": grams,
                **macros,
            }
        )

    if not resolved:
        raise ValidationError("유효한 항목이 없습니다.")

    meal_set = MealSet(
        user_id=user.id,
        name=name.strip(),
        payload={"items": resolved},
        default_meal_type=None,
    )
    db.add(meal_set)
    await db.flush()
    return meal_set


async def apply(
    db: AsyncSession,
    *,
    user: User,
    meal_set: MealSet,
    at: datetime | None = None,
    meal_type: MealType | None = None,
    logged_by: int | None = None,
    scale: float = 1.0,
) -> Meal:
    """Instantiate the set as a new meal. This is the 1-tap path."""
    if meal_set.user_id != user.id:
        raise NotFound("세트를 찾을 수 없습니다.")
    if scale <= 0:
        raise ValidationError("배율은 0보다 커야 합니다.")

    when = at or utcnow()
    resolved_type = (
        meal_type
        or meal_set.default_meal_type
        or infer_meal_type(when, user.timezone)
    )

    meal = Meal(
        user_id=user.id,
        canteen_id=None,
        shot_at=when,
        local_date=local_date(when, user.timezone),
        meal_type=resolved_type,
        status=MealStatus.READY,
        source=EntrySource.MEAL_SET,
        logged_by=logged_by or user.id,
        note=f"세트: {meal_set.name}",
    )
    db.add(meal)
    await db.flush()

    for raw in meal_set.payload.get("items", []):
        db.add(
            MealItem(
                meal_id=meal.id,
                food_id=raw.get("food_id"),
                name=raw["name"],
                category=FoodCategory(raw.get("category", "side")),
                portion_ratio=scale,
                final_g=round(float(raw.get("final_g", 0)) * scale, 1),
                kcal=round(float(raw.get("kcal", 0)) * scale, 1),
                carb_g=round(float(raw.get("carb_g", 0)) * scale, 1),
                protein_g=round(float(raw.get("protein_g", 0)) * scale, 1),
                fat_g=round(float(raw.get("fat_g", 0)) * scale, 1),
                confidence=1.0,
                edited_by_user=False,
            )
        )

    meal_set.use_count += 1
    meal_set.last_used_at = utcnow()
    await db.flush()
    return meal


async def list_for_user(db: AsyncSession, user_id: int) -> list[MealSet]:
    """Most-used first — the point of the feature is that the top of this list
    is what you eat every day."""
    return list(
        (
            await db.execute(
                select(MealSet)
                .where(MealSet.user_id == user_id)
                .order_by(MealSet.use_count.desc(), MealSet.last_used_at.desc())
            )
        ).scalars().all()
    )
