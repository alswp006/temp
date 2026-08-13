"""Weight, adaptive targets, and portion calibration."""

from __future__ import annotations

from datetime import date as Date

from fastapi import APIRouter, Query
from sqlalchemy import select

from app.core.deps import CurrentUser, DbSession
from app.core.timeutil import today_local, utcnow, week_start
from app.errors import NotFound, ValidationError
from app.models import Notification, Scope, Target, User, Weight
from app.schemas import (
    CalibrationIn,
    Ok,
    TargetOut,
    TargetOverride,
    TargetProposal,
    WeightIn,
    WeightOut,
)
from app.services import audit, calibration, permissions, targets as targets_service
from app.services.notify import notify

router = APIRouter(tags=["body"])


# --------------------------------------------------------------------------
# Weight — self-report only
# --------------------------------------------------------------------------


@router.post("/weights", response_model=WeightOut, status_code=201)
async def record_weight(
    payload: WeightIn, user: CurrentUser, db: DbSession
) -> WeightOut:
    """No ``user_id`` parameter exists here, and that is deliberate: there is
    no scope, plan, or role that lets one account write another's weight."""
    on_date = payload.date or today_local(user.timezone)
    row = await targets_service.record_weight(
        db, user, on_date=on_date, raw_kg=payload.raw_kg
    )
    return WeightOut.model_validate(row)


@router.get("/weights", response_model=list[WeightOut])
async def list_weights(
    user: CurrentUser,
    db: DbSession,
    start: Date | None = None,
    end: Date | None = None,
    user_id: int | None = None,
    limit: int = Query(default=120, le=400),
) -> list[WeightOut]:
    target_id = user.id
    if user_id and user_id != user.id:
        # Reading a mentee's weight is grantable; writing it is not.
        await permissions.require(db, user.id, user_id, Scope.WEIGHT_READ)
        target_id = user_id

    stmt = select(Weight).where(Weight.user_id == target_id)
    if start:
        stmt = stmt.where(Weight.date >= start)
    if end:
        stmt = stmt.where(Weight.date <= end)
    rows = (
        await db.execute(stmt.order_by(Weight.date.desc()).limit(limit))
    ).scalars().all()
    return [WeightOut.model_validate(r) for r in reversed(rows)]


# --------------------------------------------------------------------------
# Targets
# --------------------------------------------------------------------------


@router.get("/targets/current", response_model=TargetOut | None)
async def get_current_target(user: CurrentUser, db: DbSession) -> TargetOut | None:
    row = await targets_service.current_target(db, user)
    return TargetOut.model_validate(row) if row else None


@router.post("/targets/refresh", response_model=TargetOut)
async def refresh_target(user: CurrentUser, db: DbSession) -> TargetOut:
    """Recompute this week's target from the last 3 weeks of data."""
    row = await targets_service.refresh_target(db, user, set_by=user.id)
    return TargetOut.model_validate(row)


@router.get("/targets/tdee", response_model=dict)
async def tdee_estimate(user: CurrentUser, db: DbSession) -> dict:
    est = await targets_service.estimate_tdee(db, user)
    return {
        "value": est.value,
        "method": est.method,
        "weeks_used": est.weeks_used,
        "detail": est.detail,
    }


@router.put("/targets/current", response_model=TargetOut)
async def override_target(
    payload: TargetOverride, user: CurrentUser, db: DbSession
) -> TargetOut:
    """공식이 뱉은 값은 초기값일 뿐이다 — the user's own number wins.

    It still cannot go below basal metabolic rate, and an aggressive weekly
    deficit needs an explicit confirmation flag.
    """
    monday = week_start(today_local(user.timezone))
    est = await targets_service.estimate_tdee(db, user)
    latest = (
        await db.execute(
            select(Weight)
            .where(Weight.user_id == user.id)
            .order_by(Weight.date.desc())
            .limit(1)
        )
    ).scalar_one_or_none()

    verdict = targets_service.evaluate_target_safety(
        target_kcal=payload.target_kcal,
        est_tdee=est.value,
        weight_kg=latest.trend_kg if latest else None,
        height_cm=user.height_cm,
        age=(today_local(user.timezone).year - user.birth_year)
        if user.birth_year
        else None,
        sex=user.sex,
    )
    targets_service.assert_safe_target(verdict)
    if verdict.needs_confirmation and not payload.confirm_aggressive:
        raise ValidationError(
            verdict.reason or "감량 속도가 빠릅니다.",
            detail={
                "requires_confirmation": True,
                "weekly_loss_kg": verdict.weekly_loss_kg,
            },
        )

    row = (
        await db.execute(
            select(Target).where(
                Target.user_id == user.id, Target.week_start == monday
            )
        )
    ).scalar_one_or_none()
    if row is None:
        row = Target(
            user_id=user.id,
            week_start=monday,
            est_tdee=est.value,
            target_kcal=payload.target_kcal,
            target_protein_g=payload.target_protein_g or 100.0,
            method="manual",
            set_by=user.id,
        )
        db.add(row)
    else:
        row.target_kcal = payload.target_kcal
        if payload.target_protein_g:
            row.target_protein_g = payload.target_protein_g
        row.method = "manual"
        row.set_by = user.id
    row.pinned = payload.pinned
    row.accepted_at = utcnow()
    await db.flush()
    return TargetOut.model_validate(row)


@router.post("/targets/propose", response_model=TargetOut, status_code=201)
async def propose_target(
    payload: TargetProposal, user: CurrentUser, db: DbSession
) -> TargetOut:
    """A coach proposes a target. It is inert until the mentee accepts.

    코치가 멘티 목표를 자유롭게 넣게 두지 않는다 — the BMR floor is enforced
    here too, and an aggressive rate needs the mentee's own confirmation at
    accept time.
    """
    mentee = await db.get(User, payload.user_id)
    if mentee is None:
        raise NotFound("멘티를 찾을 수 없습니다.")
    await permissions.require(db, user.id, mentee.id, Scope.GOAL_PROPOSE)

    est = await targets_service.estimate_tdee(db, mentee)
    latest = (
        await db.execute(
            select(Weight)
            .where(Weight.user_id == mentee.id)
            .order_by(Weight.date.desc())
            .limit(1)
        )
    ).scalar_one_or_none()
    verdict = targets_service.evaluate_target_safety(
        target_kcal=payload.target_kcal,
        est_tdee=est.value,
        weight_kg=latest.trend_kg if latest else None,
        height_cm=mentee.height_cm,
        age=(today_local(mentee.timezone).year - mentee.birth_year)
        if mentee.birth_year
        else None,
        sex=mentee.sex,
    )
    targets_service.assert_safe_target(verdict)

    monday = week_start(today_local(mentee.timezone))
    row = Target(
        user_id=mentee.id,
        week_start=monday,
        est_tdee=est.value,
        target_kcal=payload.target_kcal,
        target_protein_g=payload.target_protein_g,
        method="coach",
        set_by=user.id,
        accepted_at=None,  # inert until the mentee accepts
    )
    db.add(row)
    await db.flush()

    await notify(
        db,
        user_id=mentee.id,
        kind="target_proposed",
        title="코치가 목표를 제안했습니다",
        body=(
            f"{payload.target_kcal:.0f}kcal / 단백질 "
            f"{payload.target_protein_g:.0f}g"
            + (f" · {payload.note}" if payload.note else "")
        ),
        payload={
            "target_id": row.id,
            "needs_confirmation": verdict.needs_confirmation,
            "weekly_loss_kg": verdict.weekly_loss_kg,
        },
    )
    await audit.record(
        db,
        actor_id=user.id,
        target_user_id=mentee.id,
        action="propose",
        entity="target",
        entity_id=row.id,
        after=row,
    )
    return TargetOut.model_validate(row)


@router.post("/targets/{target_id}/accept", response_model=TargetOut)
async def accept_target(
    target_id: int,
    user: CurrentUser,
    db: DbSession,
    confirm_aggressive: bool = Query(default=False),
) -> TargetOut:
    row = await db.get(Target, target_id)
    if row is None or row.user_id != user.id:
        raise NotFound("목표를 찾을 수 없습니다.")

    est = await targets_service.estimate_tdee(db, user)
    latest = (
        await db.execute(
            select(Weight)
            .where(Weight.user_id == user.id)
            .order_by(Weight.date.desc())
            .limit(1)
        )
    ).scalar_one_or_none()
    verdict = targets_service.evaluate_target_safety(
        target_kcal=row.target_kcal,
        est_tdee=est.value,
        weight_kg=latest.trend_kg if latest else None,
        height_cm=user.height_cm,
        age=(today_local(user.timezone).year - user.birth_year)
        if user.birth_year
        else None,
        sex=user.sex,
    )
    targets_service.assert_safe_target(verdict)
    if verdict.needs_confirmation and not confirm_aggressive:
        raise ValidationError(
            verdict.reason or "감량 속도가 빠릅니다.",
            detail={
                "requires_confirmation": True,
                "weekly_loss_kg": verdict.weekly_loss_kg,
            },
        )

    row.accepted_at = utcnow()
    row.pinned = True
    await db.flush()
    return TargetOut.model_validate(row)


@router.get("/targets/history", response_model=list[TargetOut])
async def target_history(
    user: CurrentUser, db: DbSession, limit: int = Query(default=20, le=100)
) -> list[TargetOut]:
    """목표 변경 이력은 멘티에게 항상 보인다."""
    rows = (
        await db.execute(
            select(Target)
            .where(Target.user_id == user.id)
            .order_by(Target.week_start.desc(), Target.id.desc())
            .limit(limit)
        )
    ).scalars().all()
    return [TargetOut.model_validate(r) for r in rows]


# --------------------------------------------------------------------------
# Calibration
# --------------------------------------------------------------------------


@router.get("/calibration", response_model=list[dict])
async def calibration_status(user: CurrentUser, db: DbSession) -> list[dict]:
    return await calibration.status(db, user.id)


@router.post("/calibration/samples", response_model=dict, status_code=201)
async def add_calibration_sample(
    payload: CalibrationIn, user: CurrentUser, db: DbSession
) -> dict:
    """2주 저울 캘리브레이션: 앱 추정치와 실제 저울값을 한 쌍씩 넣는다."""
    from app.models import MealItem

    meal_item = (
        await db.get(MealItem, payload.meal_item_id) if payload.meal_item_id else None
    )
    row = await calibration.add_sample(
        db,
        user=user,
        category=payload.category,
        estimated_g=payload.estimated_g,
        actual_g=payload.actual_g,
        meal_item=meal_item,
    )
    return {
        "category": row.category.value,
        "multiplier": row.multiplier,
        "sample_n": row.sample_n,
        "calibrated": row.sample_n >= calibration.MIN_SAMPLES,
    }


@router.delete("/calibration/{category}", response_model=Ok)
async def reset_calibration(category: str, user: CurrentUser, db: DbSession) -> Ok:
    from app.models import Calibration, CalibrationSample, FoodCategory

    cat = FoodCategory(category)
    rows = (
        await db.execute(
            select(CalibrationSample).where(
                CalibrationSample.user_id == user.id,
                CalibrationSample.category == cat,
            )
        )
    ).scalars().all()
    for row in rows:
        await db.delete(row)
    existing = (
        await db.execute(
            select(Calibration).where(
                Calibration.user_id == user.id, Calibration.category == cat
            )
        )
    ).scalar_one_or_none()
    if existing:
        await db.delete(existing)
    return Ok()
