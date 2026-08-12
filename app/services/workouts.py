"""Workout logging — the main target of delegated recording.

Three input paths, in the order they matter in the field:

A. **사진** — a photo of the trainer's notebook / whiteboard / another app's
   screen. This is the 1순위 path: PT 중에 폰을 붙잡고 세트를 입력할 트레이너는
   없다. It reuses the same vision pipeline the meal photos use.
B. **음성/텍스트** — one sentence, parsed locally first and only escalated to a
   model when the local parse fails.
C. **탭** — steppers, for precise corrections.

Calories burned are computed for display, but deliberately excluded from the
adaptive TDEE: the weight-trend back-calculation already contains the effect of
training, so adding MET calories would double-count it.
"""

from __future__ import annotations

import logging
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.timeutil import local_date, utcnow
from app.errors import ValidationError
from app.models import (
    EntrySource,
    Exercise,
    User,
    Weight,
    Workout,
    WorkoutSet,
)
from app.services import nutrition
from app.vision import get_provider
from app.vision.base import ImagePayload, WorkoutNoteRequest, WorkoutParse
from app.vision.stub import _parse_workout_text

log = logging.getLogger(__name__)


async def parse_note(
    db: AsyncSession,
    *,
    image_bytes: bytes | None = None,
    text: str | None = None,
    media_type: str = "image/jpeg",
) -> WorkoutParse:
    """Parse a note into sets.

    Plain text is tried locally first — trainer shorthand is regular enough
    that a free local parse usually succeeds, and a model call we don't have to
    make is the cheapest one there is.
    """
    if text and not image_bytes:
        local = _parse_workout_text(text)
        if local.sets and not local.unmatched:
            return local

    known = [
        name
        for name in (
            await db.execute(select(Exercise.name).order_by(Exercise.id).limit(80))
        ).scalars().all()
    ]
    provider = get_provider()
    return await provider.parse_workout_note(
        WorkoutNoteRequest(
            image=(
                ImagePayload(data=image_bytes, media_type=media_type)
                if image_bytes
                else None
            ),
            text=text,
            known_exercises=known,
        )
    )


async def create_workout(
    db: AsyncSession,
    *,
    user: User,
    actor_id: int,
    parsed: WorkoutParse | None = None,
    sets: list[dict] | None = None,
    performed_at: datetime | None = None,
    session_note: str | None = None,
    source: EntrySource = EntrySource.MANUAL,
    photo_path: str | None = None,
) -> Workout:
    """Persist a workout for ``user``, recorded by ``actor_id``.

    ``actor_id`` may differ from ``user.id`` — that is the whole point of the
    coach flow. Permission is checked by the caller; this function records who
    did it so the UI can label it and the audit log can show it.
    """
    raw_sets: list[dict] = []
    unmatched: list[str] = []

    if parsed is not None:
        unmatched = list(parsed.unmatched)
        raw_sets = [
            {
                "exercise": s.exercise,
                "set_no": s.set_no,
                "weight_kg": s.weight_kg,
                "reps": s.reps,
                "duration_s": s.duration_s,
                "rpe": s.rpe,
            }
            for s in parsed.sets
        ]
    if sets:
        raw_sets.extend(sets)

    if not raw_sets:
        raise ValidationError("세트가 하나도 없습니다.")

    when = performed_at or utcnow()
    workout = Workout(
        user_id=user.id,
        performed_at=when,
        local_date=local_date(when, user.timezone),
        session_note=session_note,
        logged_by=actor_id,
        source=source,
        photo_path=photo_path,
        unmatched=unmatched,
    )
    db.add(workout)
    await db.flush()

    for raw in raw_sets:
        name = (raw.get("exercise") or raw.get("exercise_name") or "").strip()
        if not name:
            continue
        exercise = await nutrition.match_exercise(db, name)
        db.add(
            WorkoutSet(
                workout_id=workout.id,
                exercise_id=exercise.id if exercise else None,
                exercise_name=name,
                set_no=int(raw.get("set_no") or 1),
                weight_kg=_maybe_float(raw.get("weight_kg")),
                reps=_maybe_int(raw.get("reps")),
                duration_s=_maybe_int(raw.get("duration_s")),
                rpe=_maybe_float(raw.get("rpe")),
            )
        )
        if exercise is None and name not in unmatched:
            unmatched.append(name)

    workout.unmatched = unmatched
    await db.flush()
    return workout


def _maybe_float(v) -> float | None:
    try:
        return float(v) if v is not None else None
    except (TypeError, ValueError):
        return None


def _maybe_int(v) -> int | None:
    try:
        return int(v) if v is not None else None
    except (TypeError, ValueError):
        return None


async def confirm_exercise(
    db: AsyncSession, *, workout_set: WorkoutSet, exercise_id: int
) -> WorkoutSet:
    """User (or coach) resolves an unmatched name → learn it as an alias."""
    exercise = await db.get(Exercise, exercise_id)
    if exercise is None:
        raise ValidationError("운동을 찾을 수 없습니다.")
    await nutrition.learn_exercise_alias(db, exercise.id, workout_set.exercise_name)
    workout_set.exercise_id = exercise.id
    workout = await db.get(Workout, workout_set.workout_id)
    if workout and workout_set.exercise_name in (workout.unmatched or []):
        workout.unmatched = [
            n for n in workout.unmatched if n != workout_set.exercise_name
        ]
    await db.flush()
    return workout_set


async def estimate_burn_kcal(db: AsyncSession, workout: Workout) -> float:
    """MET-based estimate, **display only**.

    Deliberately not fed into :mod:`app.services.targets`: the weight-trend
    back-calculation already includes training expenditure, so counting it
    again would inflate the TDEE estimate and raise the calorie target for
    exactly the people training hardest.
    """
    weight_row = (
        await db.execute(
            select(Weight)
            .where(Weight.user_id == workout.user_id)
            .order_by(Weight.date.desc())
            .limit(1)
        )
    ).scalar_one_or_none()
    body_kg = weight_row.trend_kg if weight_row else 70.0

    total = 0.0
    for s in workout.sets:
        met = 5.0
        if s.exercise_id:
            exercise = await db.get(Exercise, s.exercise_id)
            if exercise:
                met = exercise.met_value
        if s.duration_s:
            hours = s.duration_s / 3600.0
        else:
            # A working set plus its rest ≈ 3 minutes of the MET rate.
            hours = 3 / 60.0
        total += met * body_kg * hours
    return round(total, 1)
