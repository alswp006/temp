"""Job handlers.

Importing this module is what registers them, so it must be imported before the
worker loop starts (see :mod:`app.main` and :mod:`app.jobs.worker`).
"""

from __future__ import annotations

import logging
from datetime import date, timedelta

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.timeutil import today_local, utcnow, week_start
from app.db import session_scope
from app.jobs.queue import register
from app.models import (
    Battle,
    BattleStatus,
    Meal,
    MealStatus,
    MenuPlan,
    Notification,
    User,
)
from app.services import recognition, reports, scoring, targets

log = logging.getLogger(__name__)


@register("analyze_meal")
async def analyze_meal_job(db: AsyncSession, payload: dict) -> None:
    meal_id = int(payload["meal_id"])
    meal = await db.get(Meal, meal_id)
    if meal is None:
        log.warning("analyze_meal: meal %s 없음", meal_id)
        return
    if meal.status is MealStatus.READY:
        return
    try:
        await recognition.analyze_meal(db, meal)
    except Exception as exc:  # noqa: BLE001
        # The queue rolls this session back — which is right, half-written
        # items must not survive — so the failure has to be recorded in its
        # own transaction or the user would just see a meal stuck on
        # "pending" with no explanation. Roll back *first*: this session still
        # holds a write lock on the meal row from the ANALYZING flush, and the
        # compensating write would otherwise deadlock against it.
        await db.rollback()
        async with session_scope() as failure_db:
            failed = await failure_db.get(Meal, meal_id)
            if failed is not None:
                failed.status = MealStatus.FAILED
                failed.error = str(exc)[:500]
        raise

    await db.refresh(meal, ["items"])
    db.add(
        Notification(
            user_id=meal.user_id,
            kind="meal_ready",
            title="식사 분석 완료",
            body=f"{meal.kcal:.0f}kcal · 단백질 {meal.protein_g:.0f}g",
            payload={"meal_id": meal.id},
        )
    )


@register("refresh_targets")
async def refresh_targets_job(db: AsyncSession, payload: dict) -> None:
    """Weekly (Sunday night) target refresh for one user or everybody."""
    user_id = payload.get("user_id")
    users = (
        [await db.get(User, int(user_id))]
        if user_id
        else list((await db.execute(select(User).where(User.is_active))).scalars().all())
    )
    for user in filter(None, users):
        target = await targets.refresh_target(db, user)
        db.add(
            Notification(
                user_id=user.id,
                kind="target_updated",
                title="이번 주 목표가 갱신되었습니다",
                body=(
                    f"목표 {target.target_kcal:.0f}kcal · "
                    f"단백질 {target.target_protein_g:.0f}g"
                ),
                payload={"target_id": target.id, "method": target.method},
            )
        )


@register("recompute_battles")
async def recompute_battles_job(db: AsyncSession, payload: dict) -> None:
    on_date_raw = payload.get("date")
    battles = (
        await db.execute(
            select(Battle).where(
                Battle.status.in_([BattleStatus.OPEN, BattleStatus.RUNNING])
            )
        )
    ).scalars().all()
    for battle in battles:
        through = date.fromisoformat(on_date_raw) if on_date_raw else None
        await scoring.recompute_battle(db, battle, through=through)
        if battle.end_date < today_local("Asia/Seoul"):
            battle.status = BattleStatus.FINISHED


@register("weekly_report")
async def weekly_report_job(db: AsyncSession, payload: dict) -> None:
    user_id = payload.get("user_id")
    users = (
        [await db.get(User, int(user_id))]
        if user_id
        else list((await db.execute(select(User).where(User.is_active))).scalars().all())
    )
    for user in filter(None, users):
        end = today_local(user.timezone)
        start = week_start(end) - timedelta(days=7)
        report = await reports.weekly_report(db, user, start=start, end=start + timedelta(days=6))
        db.add(
            Notification(
                user_id=user.id,
                kind="weekly_report",
                title="주간 리포트",
                body=report.summary_line(),
                payload=report.to_dict(),
            )
        )


@register("verify_menu_plan")
async def verify_menu_plan_job(db: AsyncSession, payload: dict) -> None:
    """Two independent 오류 신고 → mark the plan unverified for re-parsing."""
    plan = await db.get(MenuPlan, int(payload["menu_plan_id"]))
    if plan is None:
        return
    plan.verified = False
    plan.created_at = plan.created_at or utcnow()
