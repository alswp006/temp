"""Menu plans: board parsing, review, and persistence.

Board parsing is synchronous rather than queued. It is a **once-a-week, 30
second** action where the user is standing in front of the board waiting to
confirm what was read — pushing it to a worker would only add a round trip and
a state machine. Meal photos, which happen three times a day and shouldn't
block the shutter, are the ones that go through the queue.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import date

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.errors import NotFound, ValidationError
from app.models import (
    Canteen,
    FoodCategory,
    MealType,
    MenuItem,
    MenuPlan,
    MenuReport,
    User,
)
from app.services import nutrition
from app.vision import get_provider
from app.vision.base import ImagePayload, MenuBoardParse, MenuBoardRequest

log = logging.getLogger(__name__)

# 2명 이상 동의 시 반영 (ROADMAP §3.2)
REPORT_THRESHOLD = 2


@dataclass(slots=True)
class DraftItem:
    name: str
    category: FoodCategory
    standard_g: float
    kcal_per_serving: float | None
    matched_food_id: int | None
    matched_food_name: str | None
    match_score: float


@dataclass(slots=True)
class DraftSlot:
    date: date
    meal_type: MealType
    items: list[DraftItem]


@dataclass(slots=True)
class MenuDraft:
    canteen_id: int
    slots: list[DraftSlot]
    notes: str

    def to_dict(self) -> dict:
        return {
            "canteen_id": self.canteen_id,
            "notes": self.notes,
            "slots": [
                {
                    "date": s.date.isoformat(),
                    "meal_type": s.meal_type.value,
                    "items": [
                        {
                            "name": i.name,
                            "category": i.category.value,
                            "standard_g": i.standard_g,
                            "kcal_per_serving": i.kcal_per_serving,
                            "matched_food_id": i.matched_food_id,
                            "matched_food_name": i.matched_food_name,
                            "match_score": i.match_score,
                        }
                        for i in s.items
                    ],
                }
                for s in self.slots
            ],
        }


async def parse_board(
    db: AsyncSession,
    *,
    canteen: Canteen,
    image_bytes: bytes,
    media_type: str = "image/jpeg",
    week_of: date | None = None,
) -> MenuDraft:
    """Photo → structured draft, pre-matched against the nutrition DB.

    The draft is returned for confirmation, not saved. Nothing enters
    ``menu_plans`` until a human says "맞으면 ✅".
    """
    provider = get_provider()
    parsed: MenuBoardParse = await provider.parse_menu_board(
        MenuBoardRequest(
            image=ImagePayload(data=image_bytes, media_type=media_type),
            week_of=week_of,
        )
    )

    slots: list[DraftSlot] = []
    for slot in parsed.slots:
        items: list[DraftItem] = []
        for raw in slot.items:
            category = raw.category or nutrition.guess_category(raw.name)
            matches = await nutrition.match_food(db, raw.name, limit=1)
            best = matches[0] if matches else None
            items.append(
                DraftItem(
                    name=raw.name.strip(),
                    category=category,
                    standard_g=raw.standard_g
                    or nutrition.STANDARD_PORTION_G.get(category, 100.0),
                    kcal_per_serving=raw.kcal,
                    matched_food_id=best.food.id if best else None,
                    matched_food_name=best.food.name if best else None,
                    match_score=round(best.score, 3) if best else 0.0,
                )
            )
        slots.append(DraftSlot(date=slot.date, meal_type=slot.meal_type, items=items))

    return MenuDraft(canteen_id=canteen.id, slots=slots, notes=parsed.notes)


async def upsert_plan(
    db: AsyncSession,
    *,
    canteen: Canteen,
    user: User,
    on_date: date,
    meal_type: MealType,
    items: list[dict],
    source: str = "photo",
    photo_path: str | None = None,
    verified: bool = True,
) -> MenuPlan:
    """Create or replace one (canteen, date, meal) slot.

    Menu plans are shared: "한 식당의 한 주 식단표는 한 명만 올리면 된다." So
    replacing an existing slot is allowed for any member, and the audit lives
    in ``created_by`` plus the report/verify flow.
    """
    if not items:
        raise ValidationError("메뉴 항목이 비어 있습니다.")

    plan = (
        await db.execute(
            select(MenuPlan).where(
                MenuPlan.canteen_id == canteen.id,
                MenuPlan.date == on_date,
                MenuPlan.meal_type == meal_type,
            )
        )
    ).scalar_one_or_none()

    if plan is None:
        plan = MenuPlan(
            canteen_id=canteen.id,
            date=on_date,
            meal_type=meal_type,
            source=source,
            created_by=user.id,
            verified=verified,
            photo_path=photo_path,
        )
        db.add(plan)
        await db.flush()
    else:
        plan.source = source
        plan.verified = verified
        if photo_path:
            plan.photo_path = photo_path
        existing = (
            await db.execute(
                select(MenuItem).where(MenuItem.menu_plan_id == plan.id)
            )
        ).scalars().all()
        for row in existing:
            await db.delete(row)
        await db.flush()

    for position, raw in enumerate(items):
        name = (raw.get("name") or "").strip()
        if not name:
            continue
        category = (
            FoodCategory(raw["category"])
            if raw.get("category")
            else nutrition.guess_category(name)
        )
        food_id = raw.get("food_id")
        if food_id is None:
            food = await nutrition.resolve_food(db, name)
            food_id = food.id if food else None
        db.add(
            MenuItem(
                menu_plan_id=plan.id,
                name=name,
                category=category,
                standard_g=float(
                    raw.get("standard_g")
                    or nutrition.STANDARD_PORTION_G.get(category, 100.0)
                ),
                kcal_per_serving=(
                    float(raw["kcal_per_serving"])
                    if raw.get("kcal_per_serving")
                    else None
                ),
                food_id=food_id,
                position=position,
            )
        )
    await db.flush()
    return plan


async def apply_draft(
    db: AsyncSession, *, canteen: Canteen, user: User, draft: dict
) -> list[MenuPlan]:
    """Persist a (possibly user-edited) draft returned by :func:`parse_board`."""
    slots = draft.get("slots") or []
    if not slots:
        raise ValidationError("저장할 식단표 슬롯이 없습니다.")

    plans: list[MenuPlan] = []
    for slot in slots:
        plans.append(
            await upsert_plan(
                db,
                canteen=canteen,
                user=user,
                on_date=date.fromisoformat(slot["date"]),
                meal_type=MealType(slot["meal_type"]),
                items=slot.get("items") or [],
                source=draft.get("source", "photo"),
                photo_path=draft.get("photo_path"),
            )
        )
    return plans


async def report_error(
    db: AsyncSession, *, plan_id: int, user: User, note: str | None
) -> tuple[int, bool]:
    """Register a '메뉴 틀림' report. Returns ``(count, threshold_reached)``."""
    plan = await db.get(MenuPlan, plan_id)
    if plan is None:
        raise NotFound("식단표를 찾을 수 없습니다.")

    existing = (
        await db.execute(
            select(MenuReport).where(
                MenuReport.menu_plan_id == plan_id, MenuReport.user_id == user.id
            )
        )
    ).scalar_one_or_none()
    if existing is None:
        db.add(MenuReport(menu_plan_id=plan_id, user_id=user.id, note=note))
        await db.flush()

    count = len(
        (
            await db.execute(
                select(MenuReport.id).where(MenuReport.menu_plan_id == plan_id)
            )
        ).scalars().all()
    )
    reached = count >= REPORT_THRESHOLD
    if reached:
        plan.verified = False
    return count, reached


async def plans_for_week(
    db: AsyncSession, canteen_id: int, monday: date
) -> list[MenuPlan]:
    from datetime import timedelta

    return list(
        (
            await db.execute(
                select(MenuPlan)
                .where(
                    MenuPlan.canteen_id == canteen_id,
                    MenuPlan.date >= monday,
                    MenuPlan.date < monday + timedelta(days=7),
                )
                .order_by(MenuPlan.date, MenuPlan.meal_type)
            )
        ).scalars().all()
    )
