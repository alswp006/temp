"""멘토-멘티 — 소셜 기능이 아니라 입력 문제의 해법.

The connection flow is deliberately mentee-first: a mentor generates an invite,
but the mentee sees a **permission screen before anything is shared** and picks
scope by scope. Everything defaults to off; revocation is instant.
"""

from __future__ import annotations

from fastapi import APIRouter, Query
from sqlalchemy import or_, select

from app.config import settings
from app.core.security import join_code
from app.core.timeutil import utcnow
from app.core.deps import CurrentUser, DbSession
from app.errors import Conflict, NotFound, ValidationError
from app.models import (
    Comment,
    Mentorship,
    MentorshipStatus,
    Notification,
    Scope,
    User,
)
from app.schemas import (
    CommentIn,
    CommentOut,
    MentorshipAccept,
    MentorshipInvite,
    MentorshipInviteOut,
    MentorshipOut,
    Ok,
    PermissionUpdate,
)
from app.services import audit, permissions, reports

router = APIRouter(prefix="/mentorships", tags=["mentorships"])


async def _out(db, m: Mentorship) -> MentorshipOut:
    out = MentorshipOut.model_validate(m)
    mentor = await db.get(User, m.mentor_id)
    mentee = await db.get(User, m.mentee_id)
    out.mentor_name = mentor.nickname if mentor else None
    out.mentee_name = mentee.nickname if mentee else None
    scopes = await permissions.granted_scopes(db, m.id)
    out.permissions = {s.value: (s in scopes) for s in Scope}
    return out


@router.post("/invite", response_model=MentorshipInviteOut, status_code=201)
async def create_invite(
    payload: MentorshipInvite, user: CurrentUser, db: DbSession
) -> MentorshipInviteOut:
    """Mentor side: mint an invite link. No mentee is attached yet."""
    await permissions.assert_capacity(db, user.id, payload.type, user.plan.value)
    code = join_code(10)
    m = Mentorship(
        mentor_id=user.id,
        mentee_id=None,  # attached when the mentee accepts
        type=payload.type,
        status=MentorshipStatus.PENDING,
        invite_code=code,
    )
    db.add(m)
    await db.flush()
    return MentorshipInviteOut(
        invite_code=code,
        invite_url=f"{settings.base_url.rstrip('/')}/app/#/invite/{code}",
        type=payload.type,
    )


@router.get("/invite/{code}", response_model=dict)
async def preview_invite(code: str, db: DbSession) -> dict:
    """What the mentee sees *before* accepting: who, what type, and the full
    list of scopes they are about to be asked for."""
    m = (
        await db.execute(
            select(Mentorship).where(
                Mentorship.invite_code == code,
                Mentorship.status == MentorshipStatus.PENDING,
            )
        )
    ).scalar_one_or_none()
    if m is None:
        raise NotFound("초대를 찾을 수 없습니다.")
    mentor = await db.get(User, m.mentor_id)
    return {
        "mentor_name": mentor.nickname if mentor else None,
        "type": m.type.value,
        "scopes": [
            {
                "scope": s.value,
                "recommended": s in permissions.RECOMMENDED_ON,
                "is_write": s in permissions.WRITE_SCOPES,
            }
            for s in Scope
        ],
        "weight_write_available": False,
        "notice": "체중은 대리 입력이 불가능합니다. 언제든 연결을 해제할 수 있습니다.",
    }


@router.post("/accept", response_model=MentorshipOut)
async def accept_invite(
    payload: MentorshipAccept, user: CurrentUser, db: DbSession
) -> MentorshipOut:
    """Mentee side. Nothing is shared until this call, and only what's ticked."""
    m = (
        await db.execute(
            select(Mentorship).where(
                Mentorship.invite_code == payload.invite_code,
                Mentorship.status == MentorshipStatus.PENDING,
            )
        )
    ).scalar_one_or_none()
    if m is None:
        raise NotFound("초대를 찾을 수 없습니다.")
    if m.mentor_id == user.id:
        raise ValidationError("자기 자신과는 연결할 수 없습니다.")

    dupe = await permissions.get_mentorship(db, m.mentor_id, user.id)
    if dupe:
        raise Conflict("이미 연결되어 있습니다.")

    m.mentee_id = user.id
    m.status = MentorshipStatus.ACTIVE
    m.accepted_at = utcnow()
    m.invite_code = None
    await db.flush()

    await permissions.set_permissions(db, m, payload.permissions)
    await audit.record(
        db,
        actor_id=user.id,
        target_user_id=m.mentor_id,
        action="grant",
        entity="mentorship",
        entity_id=m.id,
        after={k.value: v for k, v in payload.permissions.items()},
    )
    db.add(
        Notification(
            user_id=m.mentor_id,
            kind="mentorship_accepted",
            title="멘티가 연결을 수락했습니다",
            body=user.nickname,
            payload={"mentorship_id": m.id},
        )
    )
    return await _out(db, m)


@router.get("", response_model=list[MentorshipOut])
async def list_mentorships(
    user: CurrentUser, db: DbSession, role: str | None = Query(default=None)
) -> list[MentorshipOut]:
    stmt = select(Mentorship).where(
        Mentorship.status == MentorshipStatus.ACTIVE
    )
    if role == "mentor":
        stmt = stmt.where(Mentorship.mentor_id == user.id)
    elif role == "mentee":
        stmt = stmt.where(Mentorship.mentee_id == user.id)
    else:
        stmt = stmt.where(
            or_(Mentorship.mentor_id == user.id, Mentorship.mentee_id == user.id)
        )
    rows = (await db.execute(stmt)).scalars().all()
    return [await _out(db, m) for m in rows]


@router.put("/{mentorship_id}/permissions", response_model=MentorshipOut)
async def update_permissions(
    mentorship_id: int,
    payload: PermissionUpdate,
    user: CurrentUser,
    db: DbSession,
) -> MentorshipOut:
    """Only the mentee can change what a mentor may see or write."""
    m = await db.get(Mentorship, mentorship_id)
    if m is None or m.mentee_id != user.id:
        raise NotFound("연결을 찾을 수 없습니다.")
    before = {s.value: s in await permissions.granted_scopes(db, m.id) for s in Scope}
    await permissions.set_permissions(db, m, payload.permissions)
    await audit.record(
        db,
        actor_id=user.id,
        target_user_id=m.mentor_id,
        action="update",
        entity="mentorship_permissions",
        entity_id=m.id,
        before=before,
        after={k.value: v for k, v in payload.permissions.items()},
    )
    return await _out(db, m)


@router.delete("/{mentorship_id}", response_model=Ok)
async def end_mentorship(
    mentorship_id: int, user: CurrentUser, db: DbSession
) -> Ok:
    """Either side may end it; 해제 즉시 열람 차단."""
    m = await db.get(Mentorship, mentorship_id)
    if m is None or user.id not in (m.mentor_id, m.mentee_id):
        raise NotFound("연결을 찾을 수 없습니다.")
    await permissions.end_mentorship(db, m)
    return Ok()


# --- coach dashboard ------------------------------------------------------


@router.get("/dashboard", response_model=list[dict])
async def coach_dashboard(user: CurrentUser, db: DbSession) -> list[dict]:
    """담당 멘티 전원을 카드로.

    미기록 3일 이상은 카드 색만 바뀐다 — this endpoint returns ``stale_days``
    and deliberately triggers no notification.
    """
    rows = (
        await db.execute(
            select(Mentorship).where(
                Mentorship.mentor_id == user.id,
                Mentorship.status == MentorshipStatus.ACTIVE,
            )
        )
    ).scalars().all()

    cards: list[dict] = []
    for m in rows:
        mentee = await db.get(User, m.mentee_id)
        if mentee is None:
            continue
        scopes = await permissions.granted_scopes(db, m.id)
        card = (await reports.mentee_card(db, mentee)).to_dict()
        card["mentorship_id"] = m.id
        card["scopes"] = sorted(s.value for s in scopes)
        # Respect the grant: hide sections the mentee did not share.
        if Scope.DIET_READ not in scopes:
            card["meals_today"] = None
        if Scope.WORKOUT_READ not in scopes:
            card["workouts_today"] = None
        if Scope.WEIGHT_READ not in scopes:
            card["weight_today"] = None
        cards.append(card)

    cards.sort(key=lambda c: (-c["stale_days"], c["nickname"]))
    return cards


# --- comments -------------------------------------------------------------


@router.post("/comments", response_model=CommentOut, status_code=201)
async def add_comment(
    payload: CommentIn, user: CurrentUser, db: DbSession
) -> CommentOut:
    """A one-line note on a meal, session, or day.

    Notifications are batched to at most one a day by the client/worker; the
    input placeholder in the UI is phrased positively on purpose — "지적"보다
    "인정"이 기본이 되도록.
    """
    target = await db.get(User, payload.target_user_id)
    if target is None:
        raise NotFound("대상을 찾을 수 없습니다.")
    if target.id != user.id:
        m = await permissions.get_mentorship(db, user.id, target.id)
        if m is None:
            raise NotFound("연결을 찾을 수 없습니다.")

    row = Comment(
        author_id=user.id,
        target_user_id=target.id,
        entity=payload.entity,
        entity_id=payload.entity_id,
        on_date=payload.on_date,
        body=payload.body,
    )
    db.add(row)
    await db.flush()
    out = CommentOut.model_validate(row)
    out.author_name = user.nickname
    return out


@router.get("/comments", response_model=list[CommentOut])
async def list_comments(
    user: CurrentUser,
    db: DbSession,
    user_id: int | None = None,
    limit: int = Query(default=50, le=200),
) -> list[CommentOut]:
    target_id = user.id
    if user_id and user_id != user.id:
        m = await permissions.get_mentorship(db, user.id, user_id)
        if m is None:
            raise NotFound("연결을 찾을 수 없습니다.")
        target_id = user_id
    rows = (
        await db.execute(
            select(Comment)
            .where(Comment.target_user_id == target_id)
            .order_by(Comment.created_at.desc())
            .limit(limit)
        )
    ).scalars().all()
    out: list[CommentOut] = []
    for r in rows:
        item = CommentOut.model_validate(r)
        author = await db.get(User, r.author_id)
        item.author_name = author.nickname if author else None
        out.append(item)
    return out
