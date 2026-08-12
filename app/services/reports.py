"""Daily and weekly views.

The north-star metric is **주간 기록 항목 수** (식단 + 운동), not calorie accuracy
and not downloads — if logging stops, every other number is meaningless. These
reports compute it alongside the supporting metrics from ROADMAP §5.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from datetime import date, timedelta

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.timeutil import date_range, today_local, week_start
from app.models import (
    Meal,
    MealItem,
    MealStatus,
    Target,
    User,
    Weight,
    Workout,
    WorkoutSet,
)
from app.services import targets as targets_service


@dataclass(slots=True)
class DaySummary:
    date: str
    kcal: float = 0.0
    carb_g: float = 0.0
    protein_g: float = 0.0
    fat_g: float = 0.0
    meals: int = 0
    workouts: int = 0
    weight_kg: float | None = None
    trend_kg: float | None = None
    target_kcal: float | None = None
    target_protein_g: float | None = None

    @property
    def remaining_kcal(self) -> float | None:
        if self.target_kcal is None:
            return None
        return round(self.target_kcal - self.kcal, 1)

    def to_dict(self) -> dict:
        d = asdict(self)
        d["remaining_kcal"] = self.remaining_kcal
        return d


async def day_summary(db: AsyncSession, user: User, on_date: date) -> DaySummary:
    summary = DaySummary(date=on_date.isoformat())

    totals = (
        await db.execute(
            select(
                func.coalesce(func.sum(MealItem.kcal), 0.0),
                func.coalesce(func.sum(MealItem.carb_g), 0.0),
                func.coalesce(func.sum(MealItem.protein_g), 0.0),
                func.coalesce(func.sum(MealItem.fat_g), 0.0),
            )
            .select_from(MealItem)
            .join(Meal, Meal.id == MealItem.meal_id)
            .where(Meal.user_id == user.id, Meal.local_date == on_date)
        )
    ).one()
    summary.kcal = round(float(totals[0]), 1)
    summary.carb_g = round(float(totals[1]), 1)
    summary.protein_g = round(float(totals[2]), 1)
    summary.fat_g = round(float(totals[3]), 1)

    summary.meals = int(
        await db.scalar(
            select(func.count())
            .select_from(Meal)
            .where(
                Meal.user_id == user.id,
                Meal.local_date == on_date,
                Meal.status == MealStatus.READY,
            )
        )
        or 0
    )
    summary.workouts = int(
        await db.scalar(
            select(func.count())
            .select_from(Workout)
            .where(Workout.user_id == user.id, Workout.local_date == on_date)
        )
        or 0
    )

    weight = (
        await db.execute(
            select(Weight).where(Weight.user_id == user.id, Weight.date == on_date)
        )
    ).scalar_one_or_none()
    if weight:
        summary.weight_kg = weight.raw_kg
        summary.trend_kg = weight.trend_kg

    target = (
        await db.execute(
            select(Target)
            .where(Target.user_id == user.id, Target.week_start <= week_start(on_date))
            .order_by(Target.week_start.desc())
            .limit(1)
        )
    ).scalar_one_or_none()
    if target:
        summary.target_kcal = target.target_kcal
        summary.target_protein_g = target.target_protein_g

    return summary


@dataclass(slots=True)
class WeeklyReport:
    start: str
    end: str
    logged_days: int = 0
    total_entries: int = 0          # 북극성 지표: 식단 + 운동 기록 항목 수
    meal_entries: int = 0
    workout_entries: int = 0
    avg_kcal: float = 0.0
    avg_protein_g: float = 0.0
    weight_change_kg: float | None = None
    est_tdee: float | None = None
    target_kcal: float | None = None
    on_target_days: int = 0
    edit_rate: float = 0.0          # 수정 발생률
    menu_coverage: float = 0.0      # 반복 메뉴 커버리지
    delegated_ratio: float = 0.0    # 대리 기록 비율
    avg_calls_per_meal: float = 0.0
    cache_hit_rate: float = 0.0
    days: list[dict] = field(default_factory=list)

    def summary_line(self) -> str:
        parts = [
            f"기록 {self.logged_days}일",
            f"평균 {self.avg_kcal:.0f}kcal",
            f"단백질 {self.avg_protein_g:.0f}g",
        ]
        if self.weight_change_kg is not None:
            parts.append(f"추세체중 {self.weight_change_kg:+.2f}kg")
        return " · ".join(parts)

    def to_dict(self) -> dict:
        return asdict(self)


async def weekly_report(
    db: AsyncSession, user: User, *, start: date | None = None, end: date | None = None
) -> WeeklyReport:
    today = today_local(user.timezone)
    start = start or week_start(today)
    end = end or min(start + timedelta(days=6), today)

    report = WeeklyReport(start=start.isoformat(), end=end.isoformat())

    days = [await day_summary(db, user, d) for d in date_range(start, end)]
    report.days = [d.to_dict() for d in days]
    report.logged_days = sum(1 for d in days if d.meals or d.workouts)

    kcal_days = [d for d in days if d.meals]
    if kcal_days:
        report.avg_kcal = round(sum(d.kcal for d in kcal_days) / len(kcal_days), 1)
        report.avg_protein_g = round(
            sum(d.protein_g for d in kcal_days) / len(kcal_days), 1
        )
        report.on_target_days = sum(
            1
            for d in kcal_days
            if d.target_kcal
            and abs(d.kcal - d.target_kcal) <= d.target_kcal * 0.10
        )

    # --- north-star metric ------------------------------------------------
    report.meal_entries = int(
        await db.scalar(
            select(func.count())
            .select_from(MealItem)
            .join(Meal, Meal.id == MealItem.meal_id)
            .where(
                Meal.user_id == user.id,
                Meal.local_date >= start,
                Meal.local_date <= end,
            )
        )
        or 0
    )
    report.workout_entries = int(
        await db.scalar(
            select(func.count())
            .select_from(WorkoutSet)
            .join(Workout, Workout.id == WorkoutSet.workout_id)
            .where(
                Workout.user_id == user.id,
                Workout.local_date >= start,
                Workout.local_date <= end,
            )
        )
        or 0
    )
    report.total_entries = report.meal_entries + report.workout_entries

    # --- supporting metrics ----------------------------------------------
    meals = (
        await db.execute(
            select(Meal).where(
                Meal.user_id == user.id,
                Meal.local_date >= start,
                Meal.local_date <= end,
            )
        )
    ).scalars().all()

    if meals:
        photo_meals = [m for m in meals if m.calls_used]
        if photo_meals:
            report.avg_calls_per_meal = round(
                sum(m.calls_used for m in photo_meals) / len(photo_meals), 2
            )
            report.cache_hit_rate = round(
                sum(1 for m in photo_meals if m.cache_hit) / len(photo_meals), 3
            )
        report.menu_coverage = round(
            sum(1 for m in meals if not m.open_mode) / len(meals), 3
        )
        report.delegated_ratio = round(
            sum(1 for m in meals if m.logged_by != user.id) / len(meals), 3
        )

        items = (
            await db.execute(
                select(MealItem).where(
                    MealItem.meal_id.in_([m.id for m in meals])
                )
            )
        ).scalars().all()
        if items:
            report.edit_rate = round(
                sum(1 for i in items if i.edited_by_user) / len(items), 3
            )

    weight_start = (
        await db.execute(
            select(Weight)
            .where(Weight.user_id == user.id, Weight.date <= start)
            .order_by(Weight.date.desc())
            .limit(1)
        )
    ).scalar_one_or_none()
    weight_end = (
        await db.execute(
            select(Weight)
            .where(Weight.user_id == user.id, Weight.date <= end)
            .order_by(Weight.date.desc())
            .limit(1)
        )
    ).scalar_one_or_none()
    if weight_start and weight_end and weight_start.id != weight_end.id:
        report.weight_change_kg = round(weight_end.trend_kg - weight_start.trend_kg, 2)

    est = await targets_service.estimate_tdee(db, user, as_of=end)
    report.est_tdee = est.value
    target = await targets_service.current_target(db, user, as_of=end)
    report.target_kcal = target.target_kcal if target else None

    return report


@dataclass(slots=True)
class MenteeCard:
    """One row of the coach dashboard.

    No auto-nagging: a mentee who hasn't logged for three days changes the
    card's colour and nothing else. 미기록일에는 점수가 0일 뿐 아무 메시지도
    보내지 않는다.
    """

    user_id: int
    nickname: str
    logged_today: bool
    meals_today: int
    workouts_today: int
    weight_today: bool
    week_completion: float
    last_entry_at: str | None
    stale_days: int

    def to_dict(self) -> dict:
        return asdict(self)


async def mentee_card(db: AsyncSession, mentee: User) -> MenteeCard:
    today = today_local(mentee.timezone)
    summary = await day_summary(db, mentee, today)

    start = week_start(today)
    week_days = [await day_summary(db, mentee, d) for d in date_range(start, today)]
    completion = (
        round(sum(1 for d in week_days if d.meals or d.workouts) / len(week_days), 3)
        if week_days
        else 0.0
    )

    last_meal = (
        await db.execute(
            select(Meal.local_date)
            .where(Meal.user_id == mentee.id)
            .order_by(Meal.local_date.desc())
            .limit(1)
        )
    ).scalar_one_or_none()
    last_workout = (
        await db.execute(
            select(Workout.local_date)
            .where(Workout.user_id == mentee.id)
            .order_by(Workout.local_date.desc())
            .limit(1)
        )
    ).scalar_one_or_none()
    candidates = [d for d in (last_meal, last_workout) if d]
    last_entry = max(candidates) if candidates else None

    return MenteeCard(
        user_id=mentee.id,
        nickname=mentee.nickname,
        logged_today=bool(summary.meals or summary.workouts),
        meals_today=summary.meals,
        workouts_today=summary.workouts,
        weight_today=summary.weight_kg is not None,
        week_completion=completion,
        last_entry_at=last_entry.isoformat() if last_entry else None,
        stale_days=(today - last_entry).days if last_entry else 999,
    )
