"""Canteens ('내 식사 세트'의 출처) and their menu plans."""

from __future__ import annotations

from datetime import date as Date

from fastapi import APIRouter, File, Form, Query, UploadFile
from sqlalchemy import select

from app.core.deps import CurrentUser, DbSession
from app.core.security import join_code as make_join_code
from app.core.timeutil import today_local, week_start
from app.errors import Forbidden, NotFound
from app.models import Canteen, Membership, MembershipRole, MenuPlan, User
from app.schemas import (
    CanteenCreate,
    CanteenJoin,
    CanteenOut,
    MenuDraftApply,
    MenuPlanIn,
    MenuPlanOut,
    MenuReportIn,
)
from app.services import menus
from app.services.photos import process_upload

router = APIRouter(prefix="/canteens", tags=["canteens"])


async def _require_member(db, user: User, canteen_id: int) -> Canteen:
    canteen = await db.get(Canteen, canteen_id)
    if canteen is None:
        raise NotFound("식당을 찾을 수 없습니다.")
    membership = (
        await db.execute(
            select(Membership).where(
                Membership.canteen_id == canteen_id, Membership.user_id == user.id
            )
        )
    ).scalar_one_or_none()
    if membership is None and not canteen.is_public:
        raise Forbidden("이 식당의 멤버가 아닙니다.")
    return canteen


@router.post("", response_model=CanteenOut, status_code=201)
async def create_canteen(
    payload: CanteenCreate, user: CurrentUser, db: DbSession
) -> CanteenOut:
    canteen = Canteen(
        name=payload.name,
        owner_user_id=user.id,
        join_code=make_join_code(),
        is_public=payload.is_public,
        timezone=payload.timezone,
    )
    db.add(canteen)
    await db.flush()
    db.add(
        Membership(
            user_id=user.id, canteen_id=canteen.id, role=MembershipRole.OWNER
        )
    )
    await db.flush()
    return CanteenOut.model_validate(canteen)


@router.get("", response_model=list[CanteenOut])
async def list_canteens(user: CurrentUser, db: DbSession) -> list[CanteenOut]:
    rows = (
        await db.execute(
            select(Canteen)
            .join(Membership, Membership.canteen_id == Canteen.id)
            .where(Membership.user_id == user.id)
            .order_by(Canteen.name)
        )
    ).scalars().all()
    return [CanteenOut.model_validate(c) for c in rows]


@router.post("/join", response_model=CanteenOut)
async def join_canteen(
    payload: CanteenJoin, user: CurrentUser, db: DbSession
) -> CanteenOut:
    canteen = (
        await db.execute(
            select(Canteen).where(Canteen.join_code == payload.join_code.strip().upper())
        )
    ).scalar_one_or_none()
    if canteen is None:
        raise NotFound("초대 코드가 올바르지 않습니다.")

    existing = (
        await db.execute(
            select(Membership).where(
                Membership.canteen_id == canteen.id, Membership.user_id == user.id
            )
        )
    ).scalar_one_or_none()
    if existing is None:
        db.add(Membership(user_id=user.id, canteen_id=canteen.id))
        await db.flush()
    return CanteenOut.model_validate(canteen)


# --- menu plans -----------------------------------------------------------


@router.post("/{canteen_id}/menu-board")
async def parse_menu_board(
    canteen_id: int,
    user: CurrentUser,
    db: DbSession,
    file: UploadFile = File(...),
    week_of: Date | None = Form(default=None),
) -> dict:
    """식단표 사진 1장 → 파싱 결과(초안). 저장하지 않는다.

    The client shows the draft for confirmation and then POSTs it back to
    ``/menu-plans``. Nothing is written until a human approves it.
    """
    canteen = await _require_member(db, user, canteen_id)
    raw = await file.read()
    stored = process_upload(
        raw, user_id=user.id, tz_name=canteen.timezone, kind="menu"
    )
    draft = await menus.parse_board(
        db,
        canteen=canteen,
        image_bytes=stored.data,
        media_type=stored.media_type,
        week_of=week_of or week_start(today_local(canteen.timezone)),
    )
    payload = draft.to_dict()
    payload["photo_path"] = stored.path
    return payload


@router.post("/{canteen_id}/menu-plans", response_model=list[MenuPlanOut], status_code=201)
async def apply_menu_draft(
    canteen_id: int, payload: MenuDraftApply, user: CurrentUser, db: DbSession
) -> list[MenuPlanOut]:
    canteen = await _require_member(db, user, canteen_id)
    plans = await menus.apply_draft(
        db,
        canteen=canteen,
        user=user,
        draft=payload.model_dump(mode="json"),
    )
    return [await _plan_out(db, p) for p in plans]


@router.put("/{canteen_id}/menu-plans", response_model=MenuPlanOut)
async def upsert_menu_plan(
    canteen_id: int, payload: MenuPlanIn, user: CurrentUser, db: DbSession
) -> MenuPlanOut:
    """Manual entry / correction of a single slot."""
    canteen = await _require_member(db, user, canteen_id)
    plan = await menus.upsert_plan(
        db,
        canteen=canteen,
        user=user,
        on_date=payload.date,
        meal_type=payload.meal_type,
        items=[i.model_dump(mode="json") for i in payload.items],
        source="manual",
    )
    return await _plan_out(db, plan)


@router.get("/{canteen_id}/menu-plans", response_model=list[MenuPlanOut])
async def list_menu_plans(
    canteen_id: int,
    user: CurrentUser,
    db: DbSession,
    week_of: Date | None = Query(default=None),
) -> list[MenuPlanOut]:
    canteen = await _require_member(db, user, canteen_id)
    monday = week_start(week_of or today_local(canteen.timezone))
    plans = await menus.plans_for_week(db, canteen_id, monday)
    return [await _plan_out(db, p) for p in plans]


@router.get("/{canteen_id}/menu-plans/today", response_model=list[MenuPlanOut])
async def today_menu(
    canteen_id: int, user: CurrentUser, db: DbSession
) -> list[MenuPlanOut]:
    canteen = await _require_member(db, user, canteen_id)
    today = today_local(canteen.timezone)
    plans = (
        await db.execute(
            select(MenuPlan)
            .where(MenuPlan.canteen_id == canteen_id, MenuPlan.date == today)
            .order_by(MenuPlan.meal_type)
        )
    ).scalars().all()
    return [await _plan_out(db, p) for p in plans]


@router.post("/{canteen_id}/menu-plans/{plan_id}/report", response_model=dict)
async def report_menu_error(
    canteen_id: int,
    plan_id: int,
    payload: MenuReportIn,
    user: CurrentUser,
    db: DbSession,
) -> dict:
    """'메뉴 틀림' 신고. 2명 이상 동의하면 verified가 내려간다."""
    await _require_member(db, user, canteen_id)
    count, reached = await menus.report_error(
        db, plan_id=plan_id, user=user, note=payload.note
    )
    return {"reports": count, "threshold_reached": reached}


async def _plan_out(db, plan: MenuPlan) -> MenuPlanOut:
    from app.schemas import MenuItemOut

    await db.refresh(plan, ["items"])
    out = MenuPlanOut.model_validate(plan)
    out.items = [
        MenuItemOut.model_validate(i)
        for i in sorted(plan.items, key=lambda i: i.position)
    ]
    return out
