"""내 식사 세트 — 두 번째부터 1탭."""

from __future__ import annotations

from fastapi import APIRouter

from app.core.deps import CurrentUser, DbSession
from app.errors import NotFound
from app.models import Meal, MealSet
from app.schemas import (
    MealOut,
    MealSetApply,
    MealSetFromMeal,
    MealSetManual,
    MealSetOut,
    Ok,
)
from app.services import mealsets

router = APIRouter(prefix="/meal-sets", tags=["meal-sets"])


@router.get("", response_model=list[MealSetOut])
async def list_sets(user: CurrentUser, db: DbSession) -> list[MealSetOut]:
    rows = await mealsets.list_for_user(db, user.id)
    return [MealSetOut.model_validate(r) for r in rows]


@router.post("/from-meal", response_model=MealSetOut, status_code=201)
async def create_from_meal(
    payload: MealSetFromMeal, user: CurrentUser, db: DbSession
) -> MealSetOut:
    meal = await db.get(Meal, payload.meal_id)
    if meal is None or meal.user_id != user.id:
        raise NotFound("식사를 찾을 수 없습니다.")
    row = await mealsets.create_from_meal(db, user=user, meal=meal, name=payload.name)
    return MealSetOut.model_validate(row)


@router.post("", response_model=MealSetOut, status_code=201)
async def create_manual(
    payload: MealSetManual, user: CurrentUser, db: DbSession
) -> MealSetOut:
    row = await mealsets.create_manual(
        db,
        user=user,
        name=payload.name,
        items=[i.model_dump(mode="json") for i in payload.items],
    )
    return MealSetOut.model_validate(row)


@router.post("/{set_id}/apply", response_model=MealOut, status_code=201)
async def apply_set(
    set_id: int, payload: MealSetApply, user: CurrentUser, db: DbSession
) -> MealOut:
    from app.api.meals import _meal_out

    meal_set = await db.get(MealSet, set_id)
    if meal_set is None or meal_set.user_id != user.id:
        raise NotFound("세트를 찾을 수 없습니다.")
    meal = await mealsets.apply(
        db,
        user=user,
        meal_set=meal_set,
        at=payload.at,
        meal_type=payload.meal_type,
        scale=payload.scale,
    )
    return await _meal_out(db, meal)


@router.delete("/{set_id}", response_model=Ok)
async def delete_set(set_id: int, user: CurrentUser, db: DbSession) -> Ok:
    row = await db.get(MealSet, set_id)
    if row is None or row.user_id != user.id:
        raise NotFound("세트를 찾을 수 없습니다.")
    await db.delete(row)
    return Ok()
