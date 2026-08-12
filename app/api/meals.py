"""Meal logging: photo intake, listing, correction, delegated entry."""

from __future__ import annotations

from datetime import date as Date
from datetime import datetime

from fastapi import APIRouter, File, Form, Query, UploadFile
from sqlalchemy import select

from app.core.deps import CurrentUser, DbSession
from app.core.timeutil import infer_meal_type, local_date, today_local, utcnow
from app.errors import Forbidden, NotFound, ValidationError
from app.jobs.queue import enqueue
from app.models import (
    Canteen,
    EntrySource,
    Food,
    Meal,
    MealItem,
    MealStatus,
    MealType,
    Membership,
    Scope,
    User,
)
from app.schemas import (
    ManualMealIn,
    MealItemOut,
    MealItemUpdate,
    MealOut,
    MealUpdate,
    NaturalEditIn,
    Ok,
)
from app.services import audit, nutrition, permissions
from app.services.edits import apply_natural_edit
from app.services.photos import process_upload
from app.services.recognition import recompute_meal_item

router = APIRouter(prefix="/meals", tags=["meals"])


async def _load_target_user(db, actor: User, user_id: int | None) -> User:
    """Resolve who this record belongs to, enforcing the diet:write scope when
    it isn't the actor themself."""
    if user_id is None or user_id == actor.id:
        return actor
    target = await db.get(User, user_id)
    if target is None:
        raise NotFound("대상 사용자를 찾을 수 없습니다.")
    await permissions.require(db, actor.id, target.id, Scope.DIET_WRITE)
    return target


async def _meal_out(db, meal: Meal) -> MealOut:
    # Load the collection explicitly. Pydantic's from_attributes would touch
    # `meal.items` outside the greenlet context and blow up with MissingGreenlet.
    await db.refresh(meal, ["items"])
    items = sorted(meal.items, key=lambda i: i.id)
    out = MealOut.model_validate(meal)
    out.items = [MealItemOut.model_validate(i) for i in items]
    out.kcal = round(sum(i.kcal for i in items), 1)
    out.protein_g = round(sum(i.protein_g for i in items), 1)
    out.carb_g = round(sum(i.carb_g for i in items), 1)
    out.fat_g = round(sum(i.fat_g for i in items), 1)
    if meal.logged_by != meal.user_id:
        author = await db.get(User, meal.logged_by)
        out.logged_by_name = author.nickname if author else None
    return out


async def _get_meal_for(db, actor: User, meal_id: int, scope: Scope) -> Meal:
    meal = await db.get(Meal, meal_id)
    if meal is None:
        raise NotFound("식사를 찾을 수 없습니다.")
    if meal.user_id != actor.id:
        await permissions.require(db, actor.id, meal.user_id, scope)
    return meal


@router.post("/photo", response_model=MealOut, status_code=202)
async def upload_meal_photo(
    user: CurrentUser,
    db: DbSession,
    file: UploadFile = File(...),
    canteen_id: int | None = Form(default=None),
    meal_type: MealType | None = Form(default=None),
    shot_at: datetime | None = Form(default=None),
    for_user_id: int | None = Form(default=None),
    note: str | None = Form(default=None),
) -> MealOut:
    """Accept the photo, return immediately, analyse in the background.

    The shutter must never wait on a model call — the client gets a `pending`
    meal it can render at once and updates when the job finishes.
    """
    target = await _load_target_user(db, user, for_user_id)

    if canteen_id is not None:
        membership = (
            await db.execute(
                select(Membership).where(
                    Membership.canteen_id == canteen_id,
                    Membership.user_id == target.id,
                )
            )
        ).scalar_one_or_none()
        canteen = await db.get(Canteen, canteen_id)
        if canteen is None or (membership is None and not canteen.is_public):
            raise Forbidden("이 식당에 기록할 권한이 없습니다.")

    raw = await file.read()
    stored = process_upload(
        raw,
        user_id=target.id,
        tz_name=target.timezone,
        kind="meal",
        fallback_shot_at=shot_at,
    )

    when = shot_at or stored.shot_at
    meal = Meal(
        user_id=target.id,
        canteen_id=canteen_id,
        shot_at=when,
        local_date=local_date(when, target.timezone),
        meal_type=meal_type or infer_meal_type(when, target.timezone),
        photo_path=stored.path,
        status=MealStatus.PENDING,
        source=EntrySource.PHOTO,
        logged_by=user.id,
        note=note,
    )
    db.add(meal)
    await db.flush()

    await enqueue(db, "analyze_meal", {"meal_id": meal.id})
    await audit.record(
        db,
        actor_id=user.id,
        target_user_id=target.id,
        action="create",
        entity="meal",
        entity_id=meal.id,
        after=meal,
    )
    return await _meal_out(db, meal)


@router.post("/manual", response_model=MealOut, status_code=201)
async def create_manual_meal(
    payload: ManualMealIn, user: CurrentUser, db: DbSession
) -> MealOut:
    """Type it in. No photo, no model call, no cost."""
    target = user
    when = payload.shot_at or utcnow()
    meal = Meal(
        user_id=target.id,
        canteen_id=payload.canteen_id,
        shot_at=when,
        local_date=local_date(when, target.timezone),
        meal_type=payload.meal_type or infer_meal_type(when, target.timezone),
        status=MealStatus.READY,
        source=EntrySource.MANUAL,
        logged_by=user.id,
        note=payload.note,
    )
    db.add(meal)
    await db.flush()

    for raw in payload.items:
        category = raw.category or nutrition.guess_category(raw.name)
        food = (
            await db.get(Food, raw.food_id)
            if raw.food_id
            else await nutrition.resolve_food(db, raw.name)
        )
        macros = nutrition.macros_for(food, raw.final_g)
        db.add(
            MealItem(
                meal_id=meal.id,
                food_id=food.id if food else None,
                name=raw.name,
                category=category,
                portion_ratio=1.0,
                final_g=raw.final_g,
                confidence=1.0,
                edited_by_user=True,
                **macros,
            )
        )
    await db.flush()
    return await _meal_out(db, meal)


@router.get("", response_model=list[MealOut])
async def list_meals(
    user: CurrentUser,
    db: DbSession,
    on_date: Date | None = Query(default=None, alias="date"),
    start: Date | None = None,
    end: Date | None = None,
    user_id: int | None = None,
    limit: int = Query(default=50, le=200),
) -> list[MealOut]:
    target_id = user.id
    if user_id and user_id != user.id:
        await permissions.require(db, user.id, user_id, Scope.DIET_READ)
        target_id = user_id

    stmt = select(Meal).where(Meal.user_id == target_id)
    if on_date:
        stmt = stmt.where(Meal.local_date == on_date)
    else:
        if start:
            stmt = stmt.where(Meal.local_date >= start)
        if end:
            stmt = stmt.where(Meal.local_date <= end)
        if not start and not end:
            stmt = stmt.where(Meal.local_date == today_local(user.timezone))

    rows = (
        await db.execute(stmt.order_by(Meal.shot_at.desc()).limit(limit))
    ).scalars().all()
    return [await _meal_out(db, m) for m in rows]


@router.get("/{meal_id}", response_model=MealOut)
async def get_meal(meal_id: int, user: CurrentUser, db: DbSession) -> MealOut:
    meal = await _get_meal_for(db, user, meal_id, Scope.DIET_READ)
    return await _meal_out(db, meal)


@router.post("/{meal_id}/retry", response_model=MealOut)
async def retry_analysis(meal_id: int, user: CurrentUser, db: DbSession) -> MealOut:
    meal = await _get_meal_for(db, user, meal_id, Scope.DIET_WRITE)
    if not meal.photo_path:
        raise ValidationError("사진이 없어 재분석할 수 없습니다.")
    meal.status = MealStatus.PENDING
    meal.error = None
    await enqueue(db, "analyze_meal", {"meal_id": meal.id})
    return await _meal_out(db, meal)


@router.patch("/{meal_id}", response_model=MealOut)
async def update_meal(
    meal_id: int, payload: MealUpdate, user: CurrentUser, db: DbSession
) -> MealOut:
    """Correct the slot (끼니 / 식당) and re-analyse against the right menu."""
    meal = await _get_meal_for(db, user, meal_id, Scope.DIET_WRITE)
    before = {"meal_type": meal.meal_type.value, "canteen_id": meal.canteen_id}

    changed = False
    if payload.meal_type is not None and payload.meal_type != meal.meal_type:
        meal.meal_type = payload.meal_type
        changed = True
    if payload.canteen_id is not None and payload.canteen_id != meal.canteen_id:
        meal.canteen_id = payload.canteen_id
        changed = True
    if payload.note is not None:
        meal.note = payload.note
    await db.flush()

    # Re-running only makes sense for a photo meal: a manual or meal-set entry
    # has no image to re-read.
    if changed and payload.reanalyze and meal.photo_path:
        meal.status = MealStatus.PENDING
        meal.error = None
        await enqueue(db, "analyze_meal", {"meal_id": meal.id})

    await audit.record(
        db,
        actor_id=user.id,
        target_user_id=meal.user_id,
        action="update",
        entity="meal",
        entity_id=meal.id,
        before=before,
        after={"meal_type": meal.meal_type.value, "canteen_id": meal.canteen_id},
    )
    return await _meal_out(db, meal)


@router.patch("/{meal_id}/items/{item_id}", response_model=MealOut)
async def update_item(
    meal_id: int,
    item_id: int,
    payload: MealItemUpdate,
    user: CurrentUser,
    db: DbSession,
) -> MealOut:
    meal = await _get_meal_for(db, user, meal_id, Scope.DIET_WRITE)
    item = await db.get(MealItem, item_id)
    if item is None or item.meal_id != meal.id:
        raise NotFound("항목을 찾을 수 없습니다.")

    before = {"name": item.name, "final_g": item.final_g, "kcal": item.kcal}
    if payload.name is not None:
        item.name = payload.name
        item.food_id = None  # force a re-match against the new name
    if payload.category is not None:
        item.category = payload.category
    if payload.food_id is not None:
        item.food_id = payload.food_id
    await recompute_meal_item(db, item, grams=payload.final_g)

    await audit.record(
        db,
        actor_id=user.id,
        target_user_id=meal.user_id,
        action="update",
        entity="meal_item",
        entity_id=item.id,
        before=before,
        after={"name": item.name, "final_g": item.final_g, "kcal": item.kcal},
    )
    return await _meal_out(db, meal)


@router.delete("/{meal_id}/items/{item_id}", response_model=MealOut)
async def delete_item(
    meal_id: int, item_id: int, user: CurrentUser, db: DbSession
) -> MealOut:
    meal = await _get_meal_for(db, user, meal_id, Scope.DIET_WRITE)
    item = await db.get(MealItem, item_id)
    if item is None or item.meal_id != meal.id:
        raise NotFound("항목을 찾을 수 없습니다.")
    await audit.record(
        db,
        actor_id=user.id,
        target_user_id=meal.user_id,
        action="delete",
        entity="meal_item",
        entity_id=item.id,
        before=item,
    )
    await db.delete(item)
    await db.flush()
    return await _meal_out(db, meal)


@router.post("/{meal_id}/edit", response_model=dict)
async def natural_edit(
    meal_id: int, payload: NaturalEditIn, user: CurrentUser, db: DbSession
) -> dict:
    """'밥 150으로' / '국 안 먹음' — one-line correction from chat or voice."""
    meal = await _get_meal_for(db, user, meal_id, Scope.DIET_WRITE)
    result = await apply_natural_edit(db, meal, payload.text)
    return {
        "action": result.action,
        "item": result.item_name,
        "value": result.value,
        "message": result.message,
        "meal": (await _meal_out(db, meal)).model_dump(mode="json"),
    }


@router.delete("/{meal_id}", response_model=Ok)
async def delete_meal(meal_id: int, user: CurrentUser, db: DbSession) -> Ok:
    meal = await _get_meal_for(db, user, meal_id, Scope.DIET_WRITE)
    await audit.record(
        db,
        actor_id=user.id,
        target_user_id=meal.user_id,
        action="delete",
        entity="meal",
        entity_id=meal.id,
        before=meal,
    )
    await db.delete(meal)
    return Ok()
