"""Battle scoring.

Weight is deliberately absent from the score, for three reasons stated in the
spec and worth restating in code, because someone will eventually want to add it:

1. 감량 속도 경쟁은 무리한 절식을 유도한다.
2. 시작 체중이 무거운 사람이 자동으로 유리해서 게임이 안 된다.
3. 체중은 통제 불가능하지만 기록은 통제 가능하다.

You score points for *logging*, which you control, and for hitting your own
personalised targets — not for out-losing anyone.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
from datetime import date, datetime, time, timedelta

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.timeutil import local_date, tz_of, week_start
from app.models import (
    Battle,
    BattleParticipant,
    DailyScore,
    Meal,
    MealItem,
    MealStatus,
    MenuPlan,
    Target,
    User,
    Weight,
    Workout,
)

# --- 점수 규칙 (일 단위) ---------------------------------------------------
POINTS_PER_MEAL = 2
MAX_MEAL_POINTS = 6
POINTS_WORKOUT = 3
POINTS_WEIGHT = 1
POINTS_KCAL_ON_TARGET = 3
POINTS_PROTEIN_TARGET = 2
POINTS_MENU_PLAN_FIRST = 5

KCAL_TOLERANCE = 0.10


@dataclass(slots=True)
class ScoreBreakdown:
    meals: int = 0
    workout: int = 0
    weight: int = 0
    kcal_on_target: int = 0
    protein_target: int = 0
    menu_plan: int = 0

    @property
    def total(self) -> int:
        return (
            self.meals
            + self.workout
            + self.weight
            + self.kcal_on_target
            + self.protein_target
            + self.menu_plan
        )

    def to_dict(self) -> dict:
        d = asdict(self)
        d["total"] = self.total
        return d


async def compute_day(
    db: AsyncSession, user: User, on_date: date, *, battle: Battle | None = None
) -> ScoreBreakdown:
    """Score one user-day. Pure read; the caller decides whether to persist."""
    breakdown = ScoreBreakdown()

    meals = (
        await db.execute(
            select(Meal).where(
                Meal.user_id == user.id,
                Meal.local_date == on_date,
                Meal.status == MealStatus.READY,
            )
        )
    ).scalars().all()
    breakdown.meals = min(len(meals) * POINTS_PER_MEAL, MAX_MEAL_POINTS)

    # 대리 기록도 동일하게 인정한다 — 코치가 써 준 운동도 한 것은 한 것이다.
    workout_count = await db.scalar(
        select(func.count())
        .select_from(Workout)
        .where(Workout.user_id == user.id, Workout.local_date == on_date)
    )
    if workout_count:
        breakdown.workout = POINTS_WORKOUT

    weight_row = (
        await db.execute(
            select(Weight).where(Weight.user_id == user.id, Weight.date == on_date)
        )
    ).scalar_one_or_none()
    if weight_row:
        breakdown.weight = POINTS_WEIGHT

    # Nutrition points need both a target and at least one logged meal —
    # otherwise "0 kcal" would score as a perfect deficit day.
    if meals:
        totals = (
            await db.execute(
                select(
                    func.coalesce(func.sum(MealItem.kcal), 0.0),
                    func.coalesce(func.sum(MealItem.protein_g), 0.0),
                )
                .select_from(MealItem)
                .join(Meal, Meal.id == MealItem.meal_id)
                .where(Meal.user_id == user.id, Meal.local_date == on_date)
            )
        ).one()
        kcal, protein = float(totals[0]), float(totals[1])

        target = (
            await db.execute(
                select(Target)
                .where(
                    Target.user_id == user.id,
                    Target.week_start <= week_start(on_date),
                )
                .order_by(Target.week_start.desc())
                .limit(1)
            )
        ).scalar_one_or_none()

        if target and target.target_kcal:
            lo = target.target_kcal * (1 - KCAL_TOLERANCE)
            hi = target.target_kcal * (1 + KCAL_TOLERANCE)
            if lo <= kcal <= hi:
                breakdown.kcal_on_target = POINTS_KCAL_ON_TARGET
            if target.target_protein_g and protein >= target.target_protein_g:
                breakdown.protein_target = POINTS_PROTEIN_TARGET

    breakdown.menu_plan = await _menu_plan_points(db, user, on_date, battle)
    return breakdown


async def _menu_plan_points(
    db: AsyncSession, user: User, on_date: date, battle: Battle | None
) -> int:
    """5 points for the week's first menu-plan upload, once.

    Uploading the board is the product's fuel, so it is worth more than a day
    of logging — but only once a week, so it can't be farmed.
    """
    monday = week_start(on_date)
    # created_at is a timestamp; the week boundary is a local-midnight instant,
    # not a bare date — comparing the two directly is a type error.
    week_from = datetime.combine(monday, time.min, tzinfo=tz_of(user.timezone))
    week_to = week_from + timedelta(days=7)

    stmt = select(MenuPlan).where(
        MenuPlan.created_by == user.id,
        MenuPlan.created_at >= week_from,
        MenuPlan.created_at < week_to,
    )
    if battle is not None and battle.canteen_id is not None:
        stmt = stmt.where(MenuPlan.canteen_id == battle.canteen_id)

    plans = (await db.execute(stmt.order_by(MenuPlan.created_at))).scalars().all()
    if not plans:
        return 0
    first_day = local_date(plans[0].created_at, user.timezone)
    return POINTS_MENU_PLAN_FIRST if first_day == on_date else 0


async def persist_day(
    db: AsyncSession, battle: Battle, user: User, on_date: date
) -> DailyScore:
    breakdown = await compute_day(db, user, on_date, battle=battle)
    row = (
        await db.execute(
            select(DailyScore).where(
                DailyScore.battle_id == battle.id,
                DailyScore.user_id == user.id,
                DailyScore.date == on_date,
            )
        )
    ).scalar_one_or_none()
    if row is None:
        row = DailyScore(
            battle_id=battle.id, user_id=user.id, date=on_date, points=breakdown.total
        )
        db.add(row)
    row.points = breakdown.total
    row.breakdown = breakdown.to_dict()
    await db.flush()
    return row


async def recompute_battle(
    db: AsyncSession, battle: Battle, *, through: date | None = None
) -> int:
    """Rescore every participant-day in range. Idempotent."""
    end = min(through or battle.end_date, battle.end_date)
    participants = (
        await db.execute(
            select(BattleParticipant).where(BattleParticipant.battle_id == battle.id)
        )
    ).scalars().all()

    written = 0
    for p in participants:
        user = await db.get(User, p.user_id)
        if user is None:
            continue
        day = battle.start_date
        while day <= end:
            await persist_day(db, battle, user, day)
            written += 1
            day += timedelta(days=1)
    return written


@dataclass(slots=True)
class LeaderboardRow:
    user_id: int
    nickname: str
    team: str | None
    points: int
    logged_days: int
    streak: int


async def leaderboard(
    db: AsyncSession, battle: Battle, *, through: date | None = None
) -> list[LeaderboardRow]:
    """Public view: points, 기록률, 연속일수. No calories, no weight."""
    end = through or battle.end_date
    participants = (
        await db.execute(
            select(BattleParticipant).where(BattleParticipant.battle_id == battle.id)
        )
    ).scalars().all()

    rows: list[LeaderboardRow] = []
    for p in participants:
        user = await db.get(User, p.user_id)
        if user is None:
            continue
        scores = (
            await db.execute(
                select(DailyScore)
                .where(
                    DailyScore.battle_id == battle.id,
                    DailyScore.user_id == p.user_id,
                    DailyScore.date <= end,
                )
                .order_by(DailyScore.date)
            )
        ).scalars().all()

        total = sum(s.points for s in scores)
        logged = sum(1 for s in scores if s.points > 0)

        streak = 0
        for s in reversed(scores):
            if s.points > 0:
                streak += 1
            else:
                break

        rows.append(
            LeaderboardRow(
                user_id=user.id,
                nickname=user.nickname,
                team=p.team,
                points=total,
                logged_days=logged,
                streak=streak,
            )
        )

    rows.sort(key=lambda r: (-r.points, -r.logged_days, r.nickname))
    return rows
