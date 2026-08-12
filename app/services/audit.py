"""Audit trail for delegated writes.

Anything a mentor does to a mentee's data is recorded here, and the mentee can
always read their own log. Self-actions are not logged — the log exists to
answer "누가 내 기록을 건드렸나", and filling it with your own edits buries the
answer.
"""

from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import AuditLog

_MAX_SNAPSHOT_KEYS = 40


def _snapshot(value: Any) -> dict | None:
    if value is None:
        return None
    if isinstance(value, dict):
        return dict(list(value.items())[:_MAX_SNAPSHOT_KEYS])
    # SQLAlchemy model → plain column dict, minus internals.
    if hasattr(value, "__table__"):
        return {
            col.name: _jsonable(getattr(value, col.name))
            for col in value.__table__.columns
        }
    return {"value": _jsonable(value)}


def _jsonable(v: Any) -> Any:
    if v is None or isinstance(v, (str, int, float, bool)):
        return v
    if hasattr(v, "isoformat"):
        return v.isoformat()
    if hasattr(v, "value"):  # enum
        return v.value
    return str(v)


async def record(
    db: AsyncSession,
    *,
    actor_id: int,
    target_user_id: int,
    action: str,
    entity: str,
    entity_id: int | None = None,
    before: Any = None,
    after: Any = None,
) -> AuditLog | None:
    if actor_id == target_user_id:
        return None
    row = AuditLog(
        actor_user_id=actor_id,
        target_user_id=target_user_id,
        action=action,
        entity=entity,
        entity_id=entity_id,
        before=_snapshot(before),
        after=_snapshot(after),
    )
    db.add(row)
    await db.flush()
    return row


async def list_for_user(
    db: AsyncSession, user_id: int, *, limit: int = 100, offset: int = 0
) -> list[AuditLog]:
    return list(
        (
            await db.execute(
                select(AuditLog)
                .where(AuditLog.target_user_id == user_id)
                .order_by(AuditLog.created_at.desc())
                .limit(limit)
                .offset(offset)
            )
        ).scalars().all()
    )
