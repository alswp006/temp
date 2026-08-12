"""Today view, reports, food search, notifications, audit log, media, health."""

from __future__ import annotations

from datetime import date as Date

from fastapi import APIRouter, Query, Response
from sqlalchemy import func, select

from app.core.deps import CurrentUser, DbSession
from app.core.timeutil import today_local, utcnow
from app.errors import Forbidden, NotFound
from app.models import (
    Food,
    Job,
    JobStatus,
    Meal,
    MealSet,
    Notification,
    Scope,
    User,
)
from app.schemas import (
    AuditLogOut,
    FoodMatchOut,
    FoodOut,
    NotificationOut,
    Ok,
)
from app.services import audit, nutrition, permissions, reports
from app.services.photos import read_photo
from app.vision import get_provider

router = APIRouter(tags=["misc"])


@router.get("/today", response_model=dict)
async def today_view(
    user: CurrentUser, db: DbSession, on_date: Date | None = Query(default=None, alias="date")
) -> dict:
    """The one screen that matters: 남은 kcal, 단백질 게이지, 오늘 기록."""
    from app.api.meals import _meal_out

    day = on_date or today_local(user.timezone)
    summary = await reports.day_summary(db, user, day)

    meals = (
        await db.execute(
            select(Meal)
            .where(Meal.user_id == user.id, Meal.local_date == day)
            .order_by(Meal.shot_at)
        )
    ).scalars().all()

    quick_sets = (
        await db.execute(
            select(MealSet)
            .where(MealSet.user_id == user.id)
            .order_by(MealSet.use_count.desc())
            .limit(4)
        )
    ).scalars().all()

    return {
        "summary": summary.to_dict(),
        "meals": [(await _meal_out(db, m)).model_dump(mode="json") for m in meals],
        "quick_sets": [
            {"id": s.id, "name": s.name, "use_count": s.use_count} for s in quick_sets
        ],
        "pending": sum(1 for m in meals if m.status.value in ("pending", "analyzing")),
    }


@router.get("/reports/weekly", response_model=dict)
async def weekly(
    user: CurrentUser,
    db: DbSession,
    start: Date | None = None,
    end: Date | None = None,
    user_id: int | None = None,
) -> dict:
    target = user
    if user_id and user_id != user.id:
        await permissions.require(db, user.id, user_id, Scope.DIET_READ)
        found = await db.get(User, user_id)
        if found is None:
            raise NotFound("사용자를 찾을 수 없습니다.")
        target = found
    report = await reports.weekly_report(db, target, start=start, end=end)
    return report.to_dict()


# --- food search ----------------------------------------------------------


@router.get("/foods/search", response_model=list[FoodMatchOut])
async def search_foods(
    q: str,
    db: DbSession,
    user: CurrentUser,
    limit: int = Query(default=8, le=25),
) -> list[FoodMatchOut]:
    matches = await nutrition.match_food(db, q, limit=limit)
    return [
        FoodMatchOut(food=FoodOut.model_validate(m.food), score=m.score)
        for m in matches
    ]


@router.get("/foods/{food_id}", response_model=FoodOut)
async def get_food(food_id: int, db: DbSession, user: CurrentUser) -> FoodOut:
    food = await db.get(Food, food_id)
    if food is None:
        raise NotFound("음식을 찾을 수 없습니다.")
    return FoodOut.model_validate(food)


@router.get("/exercises/search", response_model=list[dict])
async def search_exercises(
    q: str, db: DbSession, user: CurrentUser, limit: int = Query(default=8, le=25)
) -> list[dict]:
    from app.models import Exercise
    from app.services.korean import similarity

    rows = (await db.execute(select(Exercise))).scalars().all()
    scored = sorted(
        ((similarity(q, e.name), e) for e in rows), key=lambda p: p[0], reverse=True
    )
    return [
        {
            "id": e.id,
            "name": e.name,
            "body_part": e.body_part,
            "equipment": e.equipment,
            "score": round(score, 3),
        }
        for score, e in scored[:limit]
        if score > 0.2
    ]


# --- notifications --------------------------------------------------------


@router.get("/notifications", response_model=list[NotificationOut])
async def list_notifications(
    user: CurrentUser,
    db: DbSession,
    unread_only: bool = False,
    limit: int = Query(default=30, le=100),
) -> list[NotificationOut]:
    stmt = select(Notification).where(Notification.user_id == user.id)
    if unread_only:
        stmt = stmt.where(Notification.read_at.is_(None))
    rows = (
        await db.execute(stmt.order_by(Notification.created_at.desc()).limit(limit))
    ).scalars().all()
    return [NotificationOut.model_validate(r) for r in rows]


@router.post("/notifications/read", response_model=Ok)
async def mark_read(user: CurrentUser, db: DbSession) -> Ok:
    rows = (
        await db.execute(
            select(Notification).where(
                Notification.user_id == user.id, Notification.read_at.is_(None)
            )
        )
    ).scalars().all()
    now = utcnow()
    for row in rows:
        row.read_at = now
    return Ok()


# --- audit log ------------------------------------------------------------


@router.get("/audit-log", response_model=list[AuditLogOut])
async def my_audit_log(
    user: CurrentUser, db: DbSession, limit: int = Query(default=100, le=300)
) -> list[AuditLogOut]:
    """모든 대리 행위는 audit_logs에 남고 멘티가 열람 가능하다."""
    rows = await audit.list_for_user(db, user.id, limit=limit)
    out: list[AuditLogOut] = []
    for r in rows:
        item = AuditLogOut.model_validate(r)
        actor = await db.get(User, r.actor_user_id)
        item.actor_name = actor.nickname if actor else None
        out.append(item)
    return out


# --- media ----------------------------------------------------------------


@router.get("/media/{path:path}")
async def get_media(path: str, user: CurrentUser, db: DbSession) -> Response:
    """Serve a photo, but only to someone entitled to see it.

    Photos are the most sensitive artefact in the system (faces, name tags,
    location context), so ``photo:read`` is a separate scope from ``diet:read``.
    """
    meal = (
        await db.execute(select(Meal).where(Meal.photo_path == path))
    ).scalar_one_or_none()
    if meal is not None and meal.user_id != user.id:
        await permissions.require(db, user.id, meal.user_id, Scope.PHOTO_READ)
    elif meal is None and not path.startswith(("menu/", f"meal/{user.id}/", f"workout/{user.id}/")):
        raise Forbidden("이 파일에 접근할 권한이 없습니다.")

    data = read_photo(path)
    if data is None:
        raise NotFound("파일을 찾을 수 없습니다.")
    return Response(content=data, media_type="image/jpeg")


# --- health ---------------------------------------------------------------


@router.get("/healthz", response_model=dict)
async def healthz(db: DbSession) -> dict:
    queued = (
        await db.scalar(
            select(func.count()).select_from(Job).where(Job.status == JobStatus.QUEUED)
        )
        or 0
    )
    failed = (
        await db.scalar(
            select(func.count()).select_from(Job).where(Job.status == JobStatus.FAILED)
        )
        or 0
    )
    return {
        "status": "ok",
        "vision_provider": get_provider().name,
        "jobs": {"queued": int(queued), "failed": int(failed)},
    }
