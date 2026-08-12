"""Mentorship permissions.

Delegated logging is a dangerous power, so three rules hold everywhere:

1. **표시** — every record carries ``logged_by``.
2. **되돌리기** — the mentee can edit or delete anything a mentor wrote.
3. **로그** — every delegated write lands in :class:`AuditLog`.

This module owns rule 0, the one that makes the rest safe: *what* a mentor is
allowed to touch at all. Defaults are off; the mentee opts in per scope at
connection time and can revoke instantly.
"""

from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.timeutil import utcnow
from app.errors import Forbidden, ValidationError
from app.models import (
    Mentorship,
    MentorshipPermission,
    MentorshipStatus,
    MentorType,
    Scope,
)

# Recommended defaults presented to the mentee. Everything else starts off.
RECOMMENDED_ON: frozenset[Scope] = frozenset({Scope.WORKOUT_READ, Scope.WORKOUT_WRITE})

# Scopes that let a mentor create or modify a mentee's records.
WRITE_SCOPES: frozenset[Scope] = frozenset({Scope.DIET_WRITE, Scope.WORKOUT_WRITE})

# A peer mentor may hold at most this many mentees; coaches are capped by plan.
PEER_MENTEE_LIMIT = 2
COACH_MENTEE_LIMIT = 10
COACH_PRO_MENTEE_LIMIT = 30


class WeightWriteForbidden(Forbidden):
    """체중은 남이 대신 재 줄 수 없고, 대신 넣을 수 있게 하면 데이터 신뢰가 무너진다.

    There is no ``Scope.WEIGHT_WRITE`` to grant, and this exists so the refusal
    is explicit rather than an accident of a missing enum member.
    """

    code = "weight_write_forbidden"


async def get_mentorship(
    db: AsyncSession, mentor_id: int, mentee_id: int
) -> Mentorship | None:
    return (
        await db.execute(
            select(Mentorship).where(
                Mentorship.mentor_id == mentor_id,
                Mentorship.mentee_id == mentee_id,
                Mentorship.status == MentorshipStatus.ACTIVE,
                Mentorship.ended_at.is_(None),
            )
        )
    ).scalar_one_or_none()


async def granted_scopes(db: AsyncSession, mentorship_id: int) -> set[Scope]:
    rows = (
        await db.execute(
            select(MentorshipPermission).where(
                MentorshipPermission.mentorship_id == mentorship_id,
                MentorshipPermission.allowed.is_(True),
            )
        )
    ).scalars().all()
    return {r.scope for r in rows}


async def can(
    db: AsyncSession, actor_id: int, target_user_id: int, scope: Scope
) -> bool:
    """Does ``actor`` hold ``scope`` over ``target``?"""
    if actor_id == target_user_id:
        return True
    mentorship = await get_mentorship(db, actor_id, target_user_id)
    if mentorship is None:
        return False
    return scope in await granted_scopes(db, mentorship.id)


async def require(
    db: AsyncSession, actor_id: int, target_user_id: int, scope: Scope
) -> None:
    if not await can(db, actor_id, target_user_id, scope):
        raise Forbidden(f"권한이 없습니다: {scope.value}")


def require_self_for_weight(actor_id: int, target_user_id: int) -> None:
    """Weight is self-report only. No scope grants this; no plan unlocks it."""
    if actor_id != target_user_id:
        raise WeightWriteForbidden(
            "체중은 본인만 입력할 수 있습니다. 대리 입력은 허용되지 않습니다."
        )


async def set_permissions(
    db: AsyncSession, mentorship: Mentorship, wanted: dict[Scope, bool]
) -> dict[Scope, bool]:
    """Replace the permission set. Unlisted scopes are turned off."""
    existing = (
        await db.execute(
            select(MentorshipPermission).where(
                MentorshipPermission.mentorship_id == mentorship.id
            )
        )
    ).scalars().all()
    by_scope = {row.scope: row for row in existing}

    result: dict[Scope, bool] = {}
    for scope in Scope:
        allowed = bool(wanted.get(scope, False))
        row = by_scope.get(scope)
        if row is None:
            db.add(
                MentorshipPermission(
                    mentorship_id=mentorship.id, scope=scope, allowed=allowed
                )
            )
        else:
            row.allowed = allowed
        result[scope] = allowed
    await db.flush()
    return result


def mentee_limit_for(mentor_type: MentorType, plan: str) -> int:
    if mentor_type is MentorType.PEER:
        return PEER_MENTEE_LIMIT
    return COACH_PRO_MENTEE_LIMIT if plan == "coach_pro" else COACH_MENTEE_LIMIT


async def assert_capacity(
    db: AsyncSession, mentor_id: int, mentor_type: MentorType, plan: str
) -> None:
    count = len(
        (
            await db.execute(
                select(Mentorship.id).where(
                    Mentorship.mentor_id == mentor_id,
                    Mentorship.type == mentor_type,
                    Mentorship.status.in_(
                        [MentorshipStatus.ACTIVE, MentorshipStatus.PENDING]
                    ),
                )
            )
        ).scalars().all()
    )
    limit = mentee_limit_for(mentor_type, plan)
    if count >= limit:
        raise ValidationError(
            f"연결 가능한 멘티 수를 초과했습니다 (최대 {limit}명). "
            "요금제를 올리거나 기존 연결을 해제하십시오."
        )


async def end_mentorship(db: AsyncSession, mentorship: Mentorship) -> None:
    """Revocation is immediate: status flips and every scope is turned off, so
    a cached scope set cannot outlive the connection."""
    mentorship.status = MentorshipStatus.ENDED
    mentorship.ended_at = utcnow()
    rows = (
        await db.execute(
            select(MentorshipPermission).where(
                MentorshipPermission.mentorship_id == mentorship.id
            )
        )
    ).scalars().all()
    for row in rows:
        row.allowed = False
    await db.flush()
