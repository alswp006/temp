"""Battles.

The public surface is deliberately narrow: 점수, 기록률, 연속일수 만. Absolute
weight can never be exposed — there is no setting for it — and calorie/protein
numbers are private by default. No penalties, no relegation, no streak-broken
alerts: 미기록일에는 점수가 0일 뿐 아무 메시지도 보내지 않는다.
"""

from __future__ import annotations

from dataclasses import asdict
from datetime import date as Date
from datetime import timedelta

from fastapi import APIRouter, Query
from sqlalchemy import select

from app.core.deps import CurrentUser, DbSession
from app.core.security import join_code as make_join_code
from app.core.timeutil import today_local, week_start
from app.errors import Conflict, Forbidden, NotFound
from app.models import (
    Battle,
    BattleParticipant,
    BattleStatus,
    DailyScore,
    User,
)
from app.schemas import BattleCreate, BattleJoin, BattleOut, LeaderboardEntry, Ok
from app.services import scoring

router = APIRouter(prefix="/battles", tags=["battles"])


@router.post("", response_model=BattleOut, status_code=201)
async def create_battle(
    payload: BattleCreate, user: CurrentUser, db: DbSession
) -> BattleOut:
    start = payload.start_date or week_start(today_local(user.timezone))
    battle = Battle(
        name=payload.name,
        mode=payload.mode,
        owner_user_id=user.id,
        canteen_id=payload.canteen_id,
        start_date=start,
        end_date=start + timedelta(days=7 * payload.weeks - 1),
        join_code=make_join_code(6),
        status=BattleStatus.OPEN,
    )
    db.add(battle)
    await db.flush()
    db.add(BattleParticipant(battle_id=battle.id, user_id=user.id))
    await db.flush()
    return BattleOut.model_validate(battle)


@router.get("", response_model=list[BattleOut])
async def list_battles(user: CurrentUser, db: DbSession) -> list[BattleOut]:
    rows = (
        await db.execute(
            select(Battle)
            .join(BattleParticipant, BattleParticipant.battle_id == Battle.id)
            .where(BattleParticipant.user_id == user.id)
            .order_by(Battle.start_date.desc())
        )
    ).scalars().all()
    return [BattleOut.model_validate(b) for b in rows]


@router.post("/join", response_model=BattleOut)
async def join_battle(
    payload: BattleJoin, user: CurrentUser, db: DbSession
) -> BattleOut:
    battle = (
        await db.execute(
            select(Battle).where(Battle.join_code == payload.join_code.strip().upper())
        )
    ).scalar_one_or_none()
    if battle is None:
        raise NotFound("배틀 코드를 찾을 수 없습니다.")
    if battle.status is BattleStatus.FINISHED:
        raise Conflict("이미 종료된 배틀입니다.")

    existing = (
        await db.execute(
            select(BattleParticipant).where(
                BattleParticipant.battle_id == battle.id,
                BattleParticipant.user_id == user.id,
            )
        )
    ).scalar_one_or_none()
    if existing is None:
        db.add(
            BattleParticipant(
                battle_id=battle.id, user_id=user.id, team=payload.team
            )
        )
        await db.flush()
    return BattleOut.model_validate(battle)


@router.get("/{battle_id}/leaderboard", response_model=list[LeaderboardEntry])
async def leaderboard(
    battle_id: int,
    user: CurrentUser,
    db: DbSession,
    through: Date | None = Query(default=None),
) -> list[LeaderboardEntry]:
    battle = await _require_participant(db, user, battle_id)
    end = min(through or today_local(user.timezone), battle.end_date)
    await scoring.recompute_battle(db, battle, through=end)
    rows = await scoring.leaderboard(db, battle, through=end)
    return [LeaderboardEntry(**asdict(row)) for row in rows]


@router.get("/{battle_id}/me", response_model=dict)
async def my_scores(
    battle_id: int, user: CurrentUser, db: DbSession
) -> dict:
    """Your own breakdown — the only place per-day point detail is visible."""
    battle = await _require_participant(db, user, battle_id)
    rows = (
        await db.execute(
            select(DailyScore)
            .where(DailyScore.battle_id == battle.id, DailyScore.user_id == user.id)
            .order_by(DailyScore.date)
        )
    ).scalars().all()
    return {
        "battle_id": battle.id,
        "total": sum(r.points for r in rows),
        "days": [
            {"date": r.date.isoformat(), "points": r.points, "breakdown": r.breakdown}
            for r in rows
        ],
        "rules": {
            "meal": scoring.POINTS_PER_MEAL,
            "meal_cap": scoring.MAX_MEAL_POINTS,
            "workout": scoring.POINTS_WORKOUT,
            "weight": scoring.POINTS_WEIGHT,
            "kcal_on_target": scoring.POINTS_KCAL_ON_TARGET,
            "protein_target": scoring.POINTS_PROTEIN_TARGET,
            "menu_plan_first": scoring.POINTS_MENU_PLAN_FIRST,
        },
    }


@router.delete("/{battle_id}/leave", response_model=Ok)
async def leave_battle(battle_id: int, user: CurrentUser, db: DbSession) -> Ok:
    row = (
        await db.execute(
            select(BattleParticipant).where(
                BattleParticipant.battle_id == battle_id,
                BattleParticipant.user_id == user.id,
            )
        )
    ).scalar_one_or_none()
    if row is None:
        raise NotFound("참가 정보를 찾을 수 없습니다.")
    await db.delete(row)
    return Ok()


async def _require_participant(db, user: User, battle_id: int) -> Battle:
    battle = await db.get(Battle, battle_id)
    if battle is None:
        raise NotFound("배틀을 찾을 수 없습니다.")
    member = (
        await db.execute(
            select(BattleParticipant).where(
                BattleParticipant.battle_id == battle_id,
                BattleParticipant.user_id == user.id,
            )
        )
    ).scalar_one_or_none()
    if member is None:
        raise Forbidden("이 배틀의 참가자가 아닙니다.")
    return battle
