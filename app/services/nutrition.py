"""Nutrition reference data: seeding, lookup, and fuzzy matching.

The bundled ``foods.csv`` is a **starter table** of common Korean cafeteria and
home dishes, not the authoritative national database. Production should import
the 식약처 식품영양성분 통합 DB (공공데이터포털, ~92k rows) with
``scripts/import_mfds.py``; this module's API is identical either way.
"""

from __future__ import annotations

import csv
import logging
from dataclasses import dataclass
from pathlib import Path

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Exercise, ExerciseAlias, Food, FoodAlias, FoodCategory
from app.services.korean import normalize, similarity

log = logging.getLogger(__name__)

DATA_DIR = Path(__file__).resolve().parent.parent / "data"

# 표준 배식량 기본값 — 식단표에 중량이 없을 때 사용한다. (ROADMAP §2.2)
STANDARD_PORTION_G: dict[FoodCategory, float] = {
    FoodCategory.RICE: 210.0,
    FoodCategory.SOUP: 250.0,
    FoodCategory.MAIN: 120.0,
    FoodCategory.SIDE: 60.0,
    FoodCategory.KIMCHI: 40.0,
    FoodCategory.DESSERT: 100.0,
}

# Category inference from the name, used when a menu board gives no hint.
_CATEGORY_HINTS: list[tuple[tuple[str, ...], FoodCategory]] = [
    (("김치", "깍두기", "겉절이"), FoodCategory.KIMCHI),
    (("국", "탕", "찌개", "전골"), FoodCategory.SOUP),
    (("밥", "면", "국수", "떡국", "덮밥", "빵"), FoodCategory.RICE),
    (
        ("나물", "무침", "샐러드", "장아찌", "절임", "생채", "볶음김"),
        FoodCategory.SIDE,
    ),
    (
        ("요구르트", "우유", "과일", "주스", "떡", "케이크", "과자"),
        FoodCategory.DESSERT,
    ),
]

MATCH_ACCEPT_THRESHOLD = 0.72
MATCH_SUGGEST_THRESHOLD = 0.40


def guess_category(name: str) -> FoodCategory:
    n = normalize(name)
    for keywords, category in _CATEGORY_HINTS:
        if any(k in n for k in keywords):
            return category
    return FoodCategory.MAIN


@dataclass(slots=True)
class FoodMatch:
    food: Food
    score: float


# --------------------------------------------------------------------------
# Seeding
# --------------------------------------------------------------------------


async def seed_foods(db: AsyncSession, csv_path: Path | None = None) -> int:
    """Idempotent: skips names already present."""
    path = csv_path or DATA_DIR / "foods.csv"
    if not path.exists():
        log.warning("food seed 파일 없음: %s", path)
        return 0

    existing = {
        row for row in (await db.execute(select(Food.name_norm))).scalars().all()
    }
    added = 0
    with path.open(encoding="utf-8", newline="") as fh:
        for row in csv.DictReader(fh):
            name = (row.get("name") or "").strip()
            if not name:
                continue
            norm = normalize(name)
            if norm in existing:
                continue
            food = Food(
                name=name,
                name_norm=norm,
                category=FoodCategory(row.get("category") or "main"),
                kcal_100g=float(row.get("kcal_100g") or 0),
                carb_100g=float(row.get("carb_100g") or 0),
                protein_100g=float(row.get("protein_100g") or 0),
                fat_100g=float(row.get("fat_100g") or 0),
                sodium_mg_100g=(
                    float(row["sodium_mg_100g"]) if row.get("sodium_mg_100g") else None
                ),
                default_serving_g=float(row.get("default_serving_g") or 100),
                source=row.get("source") or "seed",
                code=row.get("code") or None,
            )
            db.add(food)
            await db.flush()
            for alias in filter(None, (row.get("aliases") or "").split("|")):
                alias = alias.strip()
                if alias:
                    db.add(
                        FoodAlias(
                            food_id=food.id, alias=alias, alias_norm=normalize(alias)
                        )
                    )
            existing.add(norm)
            added += 1
    log.info("foods seeded: %d", added)
    return added


async def seed_exercises(db: AsyncSession, csv_path: Path | None = None) -> int:
    path = csv_path or DATA_DIR / "exercises.csv"
    if not path.exists():
        log.warning("exercise seed 파일 없음: %s", path)
        return 0

    existing = {
        row for row in (await db.execute(select(Exercise.name_norm))).scalars().all()
    }
    added = 0
    with path.open(encoding="utf-8", newline="") as fh:
        for row in csv.DictReader(fh):
            name = (row.get("name") or "").strip()
            if not name:
                continue
            norm = normalize(name)
            if norm in existing:
                continue
            ex = Exercise(
                name=name,
                name_norm=norm,
                body_part=row.get("body_part") or "etc",
                equipment=row.get("equipment") or "etc",
                met_value=float(row.get("met_value") or 5.0),
            )
            db.add(ex)
            await db.flush()
            for alias in filter(None, (row.get("aliases") or "").split("|")):
                alias = alias.strip()
                if alias:
                    db.add(
                        ExerciseAlias(
                            exercise_id=ex.id,
                            alias=alias,
                            alias_norm=normalize(alias),
                        )
                    )
            existing.add(norm)
            added += 1
    log.info("exercises seeded: %d", added)
    return added


async def seed_all(db: AsyncSession) -> dict[str, int]:
    return {
        "foods": await seed_foods(db),
        "exercises": await seed_exercises(db),
    }


async def is_seeded(db: AsyncSession) -> bool:
    count = await db.scalar(select(func.count()).select_from(Food))
    return bool(count)


# --------------------------------------------------------------------------
# Matching
# --------------------------------------------------------------------------


async def match_food(
    db: AsyncSession, name: str, *, limit: int = 3
) -> list[FoodMatch]:
    """Rank foods against a free-text name.

    Exact hits on the canonical name or an alias short-circuit. Otherwise we
    narrow with a cheap substring filter before scoring — scanning 92k rows
    through the Python similarity function on every meal item would not fly.
    """
    norm = normalize(name)
    if not norm:
        return []

    exact = (
        await db.execute(select(Food).where(Food.name_norm == norm).limit(1))
    ).scalar_one_or_none()
    if exact:
        return [FoodMatch(food=exact, score=1.0)]

    alias = (
        await db.execute(
            select(Food)
            .join(FoodAlias, FoodAlias.food_id == Food.id)
            .where(FoodAlias.alias_norm == norm)
            .limit(1)
        )
    ).scalar_one_or_none()
    if alias:
        return [FoodMatch(food=alias, score=0.98)]

    # Candidate narrowing: any row sharing a 2-char window with the query.
    windows = {norm[i : i + 2] for i in range(max(len(norm) - 1, 1))}
    clauses = [Food.name_norm.contains(w) for w in list(windows)[:8]]
    stmt = select(Food)
    if clauses:
        from sqlalchemy import or_

        stmt = stmt.where(or_(*clauses))
    candidates = (await db.execute(stmt.limit(400))).scalars().all()

    if not candidates:
        candidates = (await db.execute(select(Food).limit(400))).scalars().all()

    scored = [FoodMatch(food=f, score=similarity(name, f.name)) for f in candidates]

    # Aliases can win where the canonical name loses ("사레레" → 사이드 레터럴).
    alias_rows = (
        await db.execute(
            select(FoodAlias).where(
                FoodAlias.food_id.in_([f.id for f in candidates])
            )
        )
    ).scalars().all()
    best_alias: dict[int, float] = {}
    for row in alias_rows:
        s = similarity(name, row.alias)
        if s > best_alias.get(row.food_id, 0.0):
            best_alias[row.food_id] = s
    for m in scored:
        alias_score = best_alias.get(m.food.id, 0.0)
        if alias_score > m.score:
            m.score = alias_score

    scored = [m for m in scored if m.score >= MATCH_SUGGEST_THRESHOLD]
    scored.sort(key=lambda m: m.score, reverse=True)
    return scored[:limit]


async def resolve_food(db: AsyncSession, name: str) -> Food | None:
    """Best match above the accept threshold, else ``None``."""
    matches = await match_food(db, name, limit=1)
    if matches and matches[0].score >= MATCH_ACCEPT_THRESHOLD:
        return matches[0].food
    return None


async def match_exercise(db: AsyncSession, name: str) -> Exercise | None:
    norm = normalize(name)
    if not norm:
        return None

    exact = (
        await db.execute(select(Exercise).where(Exercise.name_norm == norm).limit(1))
    ).scalar_one_or_none()
    if exact:
        return exact

    alias = (
        await db.execute(
            select(Exercise)
            .join(ExerciseAlias, ExerciseAlias.exercise_id == Exercise.id)
            .where(ExerciseAlias.alias_norm == norm)
            .limit(1)
        )
    ).scalar_one_or_none()
    if alias:
        return alias

    exercises = (await db.execute(select(Exercise))).scalars().all()
    aliases = (await db.execute(select(ExerciseAlias))).scalars().all()
    by_id = {e.id: e for e in exercises}

    best: tuple[Exercise | None, float] = (None, 0.0)
    for e in exercises:
        s = similarity(name, e.name)
        if s > best[1]:
            best = (e, s)
    for a in aliases:
        s = similarity(name, a.alias)
        if s > best[1] and a.exercise_id in by_id:
            best = (by_id[a.exercise_id], s)

    return best[0] if best[1] >= MATCH_ACCEPT_THRESHOLD else None


async def learn_exercise_alias(db: AsyncSession, exercise_id: int, alias: str) -> None:
    """A user confirmed an unmatched name → remember it for next time."""
    norm = normalize(alias)
    if not norm:
        return
    dupe = (
        await db.execute(
            select(ExerciseAlias).where(
                ExerciseAlias.exercise_id == exercise_id,
                ExerciseAlias.alias_norm == norm,
            )
        )
    ).scalar_one_or_none()
    if dupe:
        return
    db.add(
        ExerciseAlias(
            exercise_id=exercise_id, alias=alias, alias_norm=norm, learned=True
        )
    )


# --------------------------------------------------------------------------
# Arithmetic
# --------------------------------------------------------------------------


def macros_for(food: Food | None, grams: float) -> dict[str, float]:
    """Per-100g reference → absolute macros for ``grams``."""
    if food is None or grams <= 0:
        return {"kcal": 0.0, "carb_g": 0.0, "protein_g": 0.0, "fat_g": 0.0}
    factor = grams / 100.0
    return {
        "kcal": round(food.kcal_100g * factor, 1),
        "carb_g": round(food.carb_100g * factor, 1),
        "protein_g": round(food.protein_100g * factor, 1),
        "fat_g": round(food.fat_100g * factor, 1),
    }
