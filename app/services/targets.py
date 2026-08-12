"""Weight trend, adaptive TDEE, and the safety guards around goal setting.

The formula produces a *starting* number. The user can always override it —
"목표치를 유저가 덮어쓸 수 있어야 한다"는 것이 요구사항이다. What the user cannot
do, and what a coach definitely cannot do on their behalf, is set a target
below basal metabolic rate: that guard lives in :func:`assert_safe_target` and
is enforced on every write path.
"""

from __future__ import annotations

import statistics
from dataclasses import dataclass
from datetime import date, timedelta

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.core.timeutil import today_local, week_start
from app.errors import SafetyGuardError
from app.models import GoalType, Meal, MealItem, Sex, Target, User, Weight

KCAL_PER_KG_FAT = 7700.0

GOAL_ADJUSTMENT: dict[GoalType, float] = {
    GoalType.LOSE: -400.0,
    GoalType.MAINTAIN: 0.0,
    GoalType.GAIN: 250.0,
}

# 3주 가중 이동평균 (최근 주에 가장 큰 가중치)
TDEE_WEIGHTS = (0.5, 0.3, 0.2)

# 주간 감량 목표가 체중의 이 비율을 넘으면 멘티 본인 확인을 한 번 더 받는다.
MAX_WEEKLY_LOSS_RATIO = 0.01

MIN_WEEKS_FOR_ADAPTIVE = 3


# --------------------------------------------------------------------------
# Pure maths — no DB, trivially testable
# --------------------------------------------------------------------------


def ewma_trend(previous_trend: float | None, raw_kg: float, alpha: float | None = None) -> float:
    """trend[d] = α·raw[d] + (1-α)·trend[d-1]"""
    a = settings.weight_trend_alpha if alpha is None else alpha
    if previous_trend is None:
        return round(raw_kg, 2)
    return round(a * raw_kg + (1 - a) * previous_trend, 2)


def bmr_mifflin(
    *, weight_kg: float, height_cm: float, age: int, sex: Sex
) -> float:
    """Mifflin–St Jeor. For unspecified sex we take the midpoint of the two
    constants rather than guessing, which keeps the floor conservative."""
    base = 10 * weight_kg + 6.25 * height_cm - 5 * age
    if sex is Sex.MALE:
        return base + 5
    if sex is Sex.FEMALE:
        return base - 161
    return base - 78


def estimate_tdee_from_week(
    *, avg_intake_kcal: float, weekly_weight_change_kg: float
) -> float:
    """Back out true expenditure from what went in and what the scale did.

    intake − expenditure = stored energy, so
    expenditure = intake − (Δkg · 7700 / 7 days).
    """
    return avg_intake_kcal - (weekly_weight_change_kg * KCAL_PER_KG_FAT / 7.0)


def smooth_tdee(estimates: list[float]) -> float:
    """Weighted mean of up to three weekly estimates, most recent first."""
    usable = [e for e in estimates[: len(TDEE_WEIGHTS)] if e is not None]
    if not usable:
        return 0.0
    weights = TDEE_WEIGHTS[: len(usable)]
    total_w = sum(weights)
    return sum(e * w for e, w in zip(usable, weights)) / total_w


def clamp_tdee(new_estimate: float, previous: float | None) -> float:
    """Never move more than ±15% off the previous estimate in one week.

    A single bad week — water weight, a missed logging day — should not swing
    next week's target by hundreds of calories.
    """
    if previous is None or previous <= 0:
        return new_estimate
    ratio = settings.tdee_clamp_ratio
    return max(previous * (1 - ratio), min(previous * (1 + ratio), new_estimate))


def protein_target(weight_kg: float) -> float:
    return round(weight_kg * settings.protein_g_per_kg, 0)


@dataclass(slots=True)
class SafetyVerdict:
    ok: bool
    bmr: float
    weekly_loss_kg: float | None
    needs_confirmation: bool
    reason: str | None = None


def evaluate_target_safety(
    *,
    target_kcal: float,
    est_tdee: float | None,
    weight_kg: float | None,
    height_cm: float | None,
    age: int | None,
    sex: Sex,
) -> SafetyVerdict:
    """Two guards, in the order they matter.

    1. Hard floor: below BMR the system refuses to store the target at all.
    2. Soft cap: a weekly deficit implying >1% body-weight loss is storable
       but requires the mentee to confirm it themselves.
    """
    if not (weight_kg and height_cm and age):
        # Not enough body data to compute a floor. Allow, but nothing is
        # validated — the UI should be asking for height/birth year.
        return SafetyVerdict(
            ok=True, bmr=0.0, weekly_loss_kg=None, needs_confirmation=False
        )

    bmr = bmr_mifflin(weight_kg=weight_kg, height_cm=height_cm, age=age, sex=sex)
    if target_kcal < bmr:
        return SafetyVerdict(
            ok=False,
            bmr=round(bmr),
            weekly_loss_kg=None,
            needs_confirmation=False,
            reason=(
                f"목표 칼로리({target_kcal:.0f}kcal)가 추정 기초대사량"
                f"({bmr:.0f}kcal)보다 낮습니다."
            ),
        )

    weekly_loss = None
    needs_confirmation = False
    if est_tdee and est_tdee > target_kcal:
        weekly_deficit = (est_tdee - target_kcal) * 7
        weekly_loss = weekly_deficit / KCAL_PER_KG_FAT
        if weekly_loss > weight_kg * MAX_WEEKLY_LOSS_RATIO:
            needs_confirmation = True

    return SafetyVerdict(
        ok=True,
        bmr=round(bmr),
        weekly_loss_kg=round(weekly_loss, 2) if weekly_loss is not None else None,
        needs_confirmation=needs_confirmation,
        reason=(
            f"주간 감량 속도가 체중의 1%(약 "
            f"{weight_kg * MAX_WEEKLY_LOSS_RATIO:.2f}kg)를 넘습니다."
            if needs_confirmation
            else None
        ),
    )


def assert_safe_target(verdict: SafetyVerdict) -> None:
    if not verdict.ok:
        raise SafetyGuardError(verdict.reason or "안전하지 않은 목표입니다.")


# --------------------------------------------------------------------------
# DB-backed
# --------------------------------------------------------------------------


async def record_weight(
    db: AsyncSession, user: User, *, on_date: date, raw_kg: float
) -> Weight:
    """Upsert one day's weight and recompute the trend from that day forward."""
    prev = (
        await db.execute(
            select(Weight)
            .where(Weight.user_id == user.id, Weight.date < on_date)
            .order_by(Weight.date.desc())
            .limit(1)
        )
    ).scalar_one_or_none()

    row = (
        await db.execute(
            select(Weight).where(Weight.user_id == user.id, Weight.date == on_date)
        )
    ).scalar_one_or_none()

    trend = ewma_trend(prev.trend_kg if prev else None, raw_kg)
    if row:
        row.raw_kg = raw_kg
        row.trend_kg = trend
    else:
        row = Weight(user_id=user.id, date=on_date, raw_kg=raw_kg, trend_kg=trend)
        db.add(row)
    await db.flush()

    # Later entries inherit a changed trend, so re-run them in order.
    later = (
        await db.execute(
            select(Weight)
            .where(Weight.user_id == user.id, Weight.date > on_date)
            .order_by(Weight.date)
        )
    ).scalars().all()
    running = trend
    for w in later:
        running = ewma_trend(running, w.raw_kg)
        w.trend_kg = running
    await db.flush()
    return row


async def _daily_intake(
    db: AsyncSession, user_id: int, start: date, end: date
) -> dict[date, float]:
    rows = (
        await db.execute(
            select(Meal.local_date, MealItem.kcal)
            .join(MealItem, MealItem.meal_id == Meal.id)
            .where(
                Meal.user_id == user_id,
                Meal.local_date >= start,
                Meal.local_date <= end,
            )
        )
    ).all()
    totals: dict[date, float] = {}
    for local_date, kcal in rows:
        totals[local_date] = totals.get(local_date, 0.0) + (kcal or 0.0)
    return totals


async def _trend_at(db: AsyncSession, user_id: int, on_date: date) -> float | None:
    row = (
        await db.execute(
            select(Weight)
            .where(Weight.user_id == user_id, Weight.date <= on_date)
            .order_by(Weight.date.desc())
            .limit(1)
        )
    ).scalar_one_or_none()
    return row.trend_kg if row else None


@dataclass(slots=True)
class TdeeEstimate:
    value: float | None
    method: str
    weeks_used: int
    detail: dict


async def estimate_tdee(
    db: AsyncSession, user: User, *, as_of: date | None = None
) -> TdeeEstimate:
    """Back-calculate expenditure from intake + weight trend over 3 weeks.

    Falls back to BMR × activity factor until there are enough weeks of data —
    the doc's "최소 3주치 데이터 필요".
    """
    as_of = as_of or today_local(user.timezone)
    weekly: list[float] = []
    detail: list[dict] = []

    for offset in range(MIN_WEEKS_FOR_ADAPTIVE):
        end = as_of - timedelta(days=7 * offset)
        start = end - timedelta(days=6)
        trend_end = await _trend_at(db, user.id, end)
        trend_start = await _trend_at(db, user.id, start - timedelta(days=1))
        if trend_end is None or trend_start is None:
            continue

        intake = await _daily_intake(db, user.id, start, end)
        # A week where half the days went unlogged would understate intake and
        # therefore understate TDEE. Require most of the week.
        if len(intake) < 5:
            continue

        avg_intake = statistics.mean(intake.values())
        change = trend_end - trend_start
        est = estimate_tdee_from_week(
            avg_intake_kcal=avg_intake, weekly_weight_change_kg=change
        )
        weekly.append(est)
        detail.append(
            {
                "week_end": end.isoformat(),
                "logged_days": len(intake),
                "avg_intake": round(avg_intake),
                "weight_change_kg": round(change, 2),
                "estimate": round(est),
            }
        )

    if not weekly:
        latest_weight = await _trend_at(db, user.id, as_of)
        if latest_weight and user.height_cm and user.birth_year:
            bmr = bmr_mifflin(
                weight_kg=latest_weight,
                height_cm=user.height_cm,
                age=as_of.year - user.birth_year,
                sex=user.sex,
            )
            return TdeeEstimate(
                value=round(bmr * user.activity_factor),
                method="bmr",
                weeks_used=0,
                detail={"bmr": round(bmr), "activity_factor": user.activity_factor},
            )
        return TdeeEstimate(value=None, method="insufficient_data", weeks_used=0, detail={})

    previous = (
        await db.execute(
            select(Target)
            .where(Target.user_id == user.id, Target.est_tdee.isnot(None))
            .order_by(Target.week_start.desc())
            .limit(1)
        )
    ).scalar_one_or_none()

    smoothed = smooth_tdee(weekly)
    clamped = clamp_tdee(smoothed, previous.est_tdee if previous else None)
    return TdeeEstimate(
        value=round(clamped),
        method="adaptive",
        weeks_used=len(weekly),
        detail={"weeks": detail, "smoothed": round(smoothed), "clamped": round(clamped)},
    )


async def refresh_target(
    db: AsyncSession,
    user: User,
    *,
    as_of: date | None = None,
    set_by: int | None = None,
) -> Target:
    """Compute (or refresh) the current week's target.

    A pinned target is never overwritten by the weekly job — the user's own
    number wins over the formula's.
    """
    as_of = as_of or today_local(user.timezone)
    monday = week_start(as_of)

    existing = (
        await db.execute(
            select(Target).where(
                Target.user_id == user.id, Target.week_start == monday
            )
        )
    ).scalar_one_or_none()
    if existing and existing.pinned:
        return existing

    est = await estimate_tdee(db, user, as_of=as_of)
    weight = await _trend_at(db, user.id, as_of)

    if est.value is None:
        target_kcal = existing.target_kcal if existing else 2000.0
    else:
        target_kcal = est.value + GOAL_ADJUSTMENT.get(user.goal_type, 0.0)

    protein = protein_target(weight) if weight else 100.0

    verdict = evaluate_target_safety(
        target_kcal=target_kcal,
        est_tdee=est.value,
        weight_kg=weight,
        height_cm=user.height_cm,
        age=(as_of.year - user.birth_year) if user.birth_year else None,
        sex=user.sex,
    )
    if not verdict.ok:
        # The formula itself hit the floor — clamp to BMR rather than refusing
        # to produce a target at all.
        target_kcal = float(verdict.bmr)

    if existing:
        existing.est_tdee = est.value
        existing.target_kcal = round(target_kcal)
        existing.target_protein_g = protein
        existing.method = est.method
        existing.set_by = set_by
        return existing

    target = Target(
        user_id=user.id,
        week_start=monday,
        est_tdee=est.value,
        target_kcal=round(target_kcal),
        target_protein_g=protein,
        method=est.method,
        set_by=set_by,
        accepted_at=None,
    )
    db.add(target)
    await db.flush()
    return target


async def current_target(
    db: AsyncSession, user: User, *, as_of: date | None = None
) -> Target | None:
    as_of = as_of or today_local(user.timezone)
    return (
        await db.execute(
            select(Target)
            .where(Target.user_id == user.id, Target.week_start <= week_start(as_of))
            .order_by(Target.week_start.desc())
            .limit(1)
        )
    ).scalar_one_or_none()
