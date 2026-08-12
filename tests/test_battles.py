"""Battle scoring — and the things that deliberately do *not* score."""

from __future__ import annotations

from datetime import timedelta

import pytest

from app.models import Sex, User
from app.services import scoring
from tests.conftest import local_today, register


@pytest.mark.asyncio
async def test_weight_value_never_affects_score(db):
    """감량 속도 경쟁은 무리한 절식을 유도하므로 점수에서 뺀다.

    Logging *that* you weighed yourself is worth 1 point. What the number says
    is worth nothing — a 5kg loss and a 5kg gain score identically.
    """
    from app.services.targets import record_weight

    heavy = User(email="h@example.com", nickname="무거움", sex=Sex.MALE)
    light = User(email="l@example.com", nickname="가벼움", sex=Sex.MALE)
    db.add_all([heavy, light])
    await db.flush()

    today = local_today()
    await record_weight(db, heavy, on_date=today - timedelta(days=1), raw_kg=100.0)
    await record_weight(db, heavy, on_date=today, raw_kg=99.0)   # -1kg
    await record_weight(db, light, on_date=today - timedelta(days=1), raw_kg=60.0)
    await record_weight(db, light, on_date=today, raw_kg=61.0)   # +1kg
    await db.flush()

    a = await scoring.compute_day(db, heavy, today)
    b = await scoring.compute_day(db, light, today)
    assert a.weight == b.weight == scoring.POINTS_WEIGHT
    assert a.total == b.total


@pytest.mark.asyncio
async def test_meal_points_are_capped(db):
    """끼니당 2점, 하루 최대 6점 — 하루에 열 번 찍어도 6점."""
    from app.core.timeutil import utcnow
    from app.models import EntrySource, Meal, MealStatus, MealType

    user = User(email="cap@example.com", nickname="상한")
    db.add(user)
    await db.flush()

    today = local_today()
    for i in range(10):
        db.add(
            Meal(
                user_id=user.id,
                shot_at=utcnow(),
                local_date=today,
                meal_type=MealType.SNACK,
                status=MealStatus.READY,
                source=EntrySource.MANUAL,
                logged_by=user.id,
            )
        )
    await db.flush()

    breakdown = await scoring.compute_day(db, user, today)
    assert breakdown.meals == scoring.MAX_MEAL_POINTS


@pytest.mark.asyncio
async def test_nutrition_points_need_a_logged_meal(db):
    """0kcal은 완벽한 적자가 아니라 미기록이다."""
    from app.core.timeutil import week_start
    from app.models import Target

    user = User(email="zero@example.com", nickname="영")
    db.add(user)
    await db.flush()
    today = local_today()
    db.add(
        Target(
            user_id=user.id,
            week_start=week_start(today),
            target_kcal=0,
            target_protein_g=0,
        )
    )
    await db.flush()

    breakdown = await scoring.compute_day(db, user, today)
    assert breakdown.kcal_on_target == 0
    assert breakdown.protein_target == 0
    assert breakdown.total == 0


@pytest.mark.asyncio
async def test_delegated_workout_scores_the_same(db):
    """코치가 써 준 운동도 한 것은 한 것이다."""
    from app.core.timeutil import utcnow
    from app.models import EntrySource, Workout

    coach = User(email="c@example.com", nickname="코치")
    mentee = User(email="m@example.com", nickname="멘티")
    db.add_all([coach, mentee])
    await db.flush()

    today = local_today()
    db.add(
        Workout(
            user_id=mentee.id,
            performed_at=utcnow(),
            local_date=today,
            logged_by=coach.id,          # 대리 기록
            source=EntrySource.PHOTO,
        )
    )
    await db.flush()

    breakdown = await scoring.compute_day(db, mentee, today)
    assert breakdown.workout == scoring.POINTS_WORKOUT


@pytest.mark.asyncio
async def test_leaderboard_exposes_no_private_numbers(client):
    """공개되는 것은 점수·기록률·연속일수뿐."""
    a = await register(client, "ba@example.com", "가")
    b = await register(client, "bb@example.com", "나")

    r = await client.post(
        "/api/battles", json={"name": "1주 리그", "weeks": 1}, headers=a["headers"]
    )
    assert r.status_code == 201, r.text
    battle = r.json()

    r = await client.post(
        "/api/battles/join",
        json={"join_code": battle["join_code"]},
        headers=b["headers"],
    )
    assert r.status_code == 200

    await client.post(
        "/api/meals/manual",
        json={"meal_type": "lunch", "items": [{"name": "흰쌀밥", "final_g": 210}]},
        headers=a["headers"],
    )
    await client.post("/api/weights", json={"raw_kg": 70.0}, headers=a["headers"])

    r = await client.get(f"/api/battles/{battle['id']}/leaderboard", headers=a["headers"])
    assert r.status_code == 200, r.text
    board = r.json()
    assert len(board) == 2

    allowed = {"user_id", "nickname", "team", "points", "logged_days", "streak"}
    for row in board:
        assert set(row) == allowed, "리더보드에 사적인 수치가 새면 안 된다"

    leader = next(row for row in board if row["nickname"] == "가")
    assert leader["points"] >= scoring.POINTS_PER_MEAL + scoring.POINTS_WEIGHT
    assert board[0]["nickname"] == "가"


@pytest.mark.asyncio
async def test_own_breakdown_is_visible_to_self(client):
    a = await register(client, "own@example.com", "본인")
    r = await client.post(
        "/api/battles", json={"name": "혼자", "weeks": 1}, headers=a["headers"]
    )
    battle = r.json()
    await client.post(
        "/api/meals/manual",
        json={"meal_type": "lunch", "items": [{"name": "잡곡밥", "final_g": 210}]},
        headers=a["headers"],
    )
    await client.get(f"/api/battles/{battle['id']}/leaderboard", headers=a["headers"])

    r = await client.get(f"/api/battles/{battle['id']}/me", headers=a["headers"])
    assert r.status_code == 200
    mine = r.json()
    assert mine["total"] >= scoring.POINTS_PER_MEAL
    assert mine["rules"]["meal_cap"] == scoring.MAX_MEAL_POINTS
    assert any(d["breakdown"]["meals"] > 0 for d in mine["days"])


@pytest.mark.asyncio
async def test_non_participant_cannot_read_leaderboard(client):
    a = await register(client, "in@example.com")
    outsider = await register(client, "out@example.com")
    battle = (
        await client.post(
            "/api/battles", json={"name": "사설", "weeks": 1}, headers=a["headers"]
        )
    ).json()

    r = await client.get(
        f"/api/battles/{battle['id']}/leaderboard", headers=outsider["headers"]
    )
    assert r.status_code == 403
