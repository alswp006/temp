"""Workout logging — including the delegated path a coach uses.

Route A (photo) is first in the file because it is first in the field: a
trainer photographs the notebook after the session and is done in three
seconds. Routes B (voice/text) and C (taps) follow.
"""

from __future__ import annotations

from datetime import date as Date
from datetime import datetime

from fastapi import APIRouter, File, Form, Query, UploadFile
from sqlalchemy import select

from app.core.deps import CurrentUser, DbSession
from app.core.timeutil import today_local
from app.errors import NotFound
from app.models import EntrySource, Scope, User, Workout, WorkoutSet
from app.schemas import (
    ExerciseConfirm,
    Ok,
    WorkoutIn,
    WorkoutOut,
    WorkoutSetOut,
    WorkoutTextIn,
)
from app.services import audit, permissions, workouts as workouts_service
from app.services.photos import process_upload

router = APIRouter(prefix="/workouts", tags=["workouts"])


async def _target_user(db, actor: User, user_id: int | None) -> User:
    if user_id is None or user_id == actor.id:
        return actor
    target = await db.get(User, user_id)
    if target is None:
        raise NotFound("대상 사용자를 찾을 수 없습니다.")
    await permissions.require(db, actor.id, target.id, Scope.WORKOUT_WRITE)
    return target


async def _workout_out(db, workout: Workout, *, with_burn: bool = True) -> WorkoutOut:
    await db.refresh(workout, ["sets"])
    sets = sorted(workout.sets, key=lambda s: s.id)
    out = WorkoutOut.model_validate(workout)
    out.sets = [WorkoutSetOut.model_validate(s) for s in sets]
    if workout.logged_by != workout.user_id:
        author = await db.get(User, workout.logged_by)
        out.logged_by_name = author.nickname if author else None
    if with_burn:
        out.burn_kcal = await workouts_service.estimate_burn_kcal(db, workout)
    return out


# --- A. photo -------------------------------------------------------------


@router.post("/photo", response_model=WorkoutOut, status_code=201)
async def log_from_photo(
    user: CurrentUser,
    db: DbSession,
    file: UploadFile = File(...),
    for_user_id: int | None = Form(default=None),
    performed_at: datetime | None = Form(default=None),
    session_note: str | None = Form(default=None),
) -> WorkoutOut:
    """수첩·화이트보드·타 앱 화면 1장 → 세트 파싱.

    Runs inline rather than queued: the trainer is standing there and wants to
    see that it read the numbers correctly before pocketing the phone.
    """
    target = await _target_user(db, user, for_user_id)
    raw = await file.read()
    stored = process_upload(
        raw, user_id=target.id, tz_name=target.timezone, kind="workout"
    )
    parsed = await workouts_service.parse_note(
        db, image_bytes=stored.data, media_type=stored.media_type
    )
    workout = await workouts_service.create_workout(
        db,
        user=target,
        actor_id=user.id,
        parsed=parsed,
        performed_at=performed_at or stored.shot_at,
        session_note=session_note,
        source=EntrySource.PHOTO,
        photo_path=stored.path,
    )
    await audit.record(
        db,
        actor_id=user.id,
        target_user_id=target.id,
        action="create",
        entity="workout",
        entity_id=workout.id,
        after=workout,
    )
    return await _workout_out(db, workout)


# --- B. voice / text ------------------------------------------------------


@router.post("/text", response_model=WorkoutOut, status_code=201)
async def log_from_text(
    payload: WorkoutTextIn, user: CurrentUser, db: DbSession
) -> WorkoutOut:
    """'스쿼트 60에 10개 3세트, 랫풀 50에 12개 3세트' 한 문장."""
    target = await _target_user(db, user, payload.user_id)
    parsed = await workouts_service.parse_note(db, text=payload.text)
    workout = await workouts_service.create_workout(
        db,
        user=target,
        actor_id=user.id,
        parsed=parsed,
        performed_at=payload.performed_at,
        session_note=payload.session_note,
        source=EntrySource.VOICE,
    )
    await audit.record(
        db,
        actor_id=user.id,
        target_user_id=target.id,
        action="create",
        entity="workout",
        entity_id=workout.id,
        after=workout,
    )
    return await _workout_out(db, workout)


# --- C. structured taps ---------------------------------------------------


@router.post("", response_model=WorkoutOut, status_code=201)
async def log_structured(
    payload: WorkoutIn, user: CurrentUser, db: DbSession
) -> WorkoutOut:
    target = await _target_user(db, user, payload.user_id)
    workout = await workouts_service.create_workout(
        db,
        user=target,
        actor_id=user.id,
        sets=[s.model_dump(mode="json") for s in payload.sets],
        performed_at=payload.performed_at,
        session_note=payload.session_note,
        source=EntrySource.MANUAL,
    )
    await audit.record(
        db,
        actor_id=user.id,
        target_user_id=target.id,
        action="create",
        entity="workout",
        entity_id=workout.id,
        after=workout,
    )
    return await _workout_out(db, workout)


@router.get("", response_model=list[WorkoutOut])
async def list_workouts(
    user: CurrentUser,
    db: DbSession,
    on_date: Date | None = Query(default=None, alias="date"),
    start: Date | None = None,
    end: Date | None = None,
    user_id: int | None = None,
    limit: int = Query(default=50, le=200),
) -> list[WorkoutOut]:
    target_id = user.id
    if user_id and user_id != user.id:
        await permissions.require(db, user.id, user_id, Scope.WORKOUT_READ)
        target_id = user_id

    stmt = select(Workout).where(Workout.user_id == target_id)
    if on_date:
        stmt = stmt.where(Workout.local_date == on_date)
    else:
        if start:
            stmt = stmt.where(Workout.local_date >= start)
        if end:
            stmt = stmt.where(Workout.local_date <= end)
        if not start and not end:
            stmt = stmt.where(Workout.local_date == today_local(user.timezone))

    rows = (
        await db.execute(stmt.order_by(Workout.performed_at.desc()).limit(limit))
    ).scalars().all()
    return [await _workout_out(db, w, with_burn=False) for w in rows]


@router.get("/{workout_id}", response_model=WorkoutOut)
async def get_workout(workout_id: int, user: CurrentUser, db: DbSession) -> WorkoutOut:
    workout = await db.get(Workout, workout_id)
    if workout is None:
        raise NotFound("운동 기록을 찾을 수 없습니다.")
    if workout.user_id != user.id:
        await permissions.require(db, user.id, workout.user_id, Scope.WORKOUT_READ)
    return await _workout_out(db, workout)


@router.post("/{workout_id}/sets/{set_id}/confirm", response_model=WorkoutOut)
async def confirm_exercise(
    workout_id: int,
    set_id: int,
    payload: ExerciseConfirm,
    user: CurrentUser,
    db: DbSession,
) -> WorkoutOut:
    """Resolve an unmatched exercise name; the app learns it as an alias."""
    workout = await db.get(Workout, workout_id)
    if workout is None:
        raise NotFound("운동 기록을 찾을 수 없습니다.")
    if workout.user_id != user.id:
        await permissions.require(db, user.id, workout.user_id, Scope.WORKOUT_WRITE)
    ws = await db.get(WorkoutSet, set_id)
    if ws is None or ws.workout_id != workout.id:
        raise NotFound("세트를 찾을 수 없습니다.")
    await workouts_service.confirm_exercise(
        db, workout_set=ws, exercise_id=payload.exercise_id
    )
    return await _workout_out(db, workout)


@router.delete("/{workout_id}", response_model=Ok)
async def delete_workout(workout_id: int, user: CurrentUser, db: DbSession) -> Ok:
    workout = await db.get(Workout, workout_id)
    if workout is None:
        raise NotFound("운동 기록을 찾을 수 없습니다.")
    if workout.user_id != user.id:
        await permissions.require(db, user.id, workout.user_id, Scope.WORKOUT_WRITE)
    await audit.record(
        db,
        actor_id=user.id,
        target_user_id=workout.user_id,
        action="delete",
        entity="workout",
        entity_id=workout.id,
        before=workout,
    )
    await db.delete(workout)
    return Ok()
