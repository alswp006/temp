"""End-to-end: menu board → tray photo → correction → meal set → today view."""

from __future__ import annotations

from datetime import datetime, time, timedelta, timezone

import pytest

from app.jobs.queue import run_due_jobs
from tests.conftest import local_today, make_photo, register


@pytest.mark.asyncio
async def test_full_meal_flow(client):
    me = await register(client, "flow@example.com", "김기록")
    h = me["headers"]

    # 1. 식당 만들기
    r = await client.post(
        "/api/canteens", json={"name": "생활관 식당"}, headers=h
    )
    assert r.status_code == 201, r.text
    canteen = r.json()
    assert canteen["join_code"]

    # 2. 주간 식단표 사진 1장 → 초안 (저장은 아직 안 됨)
    r = await client.post(
        f"/api/canteens/{canteen['id']}/menu-board",
        files={"file": ("board.jpg", make_photo("board"), "image/jpeg")},
        headers=h,
    )
    assert r.status_code == 200, r.text
    draft = r.json()
    assert draft["slots"], "board parse should produce slots"
    # Items are pre-matched against the nutrition DB for review.
    first_item = draft["slots"][0]["items"][0]
    assert "matched_food_name" in first_item

    # 3. 확인 후 승인 → 저장
    today = local_today()
    draft["slots"][0]["date"] = today.isoformat()
    r = await client.post(
        f"/api/canteens/{canteen['id']}/menu-plans",
        json={"slots": draft["slots"], "source": "photo"},
        headers=h,
    )
    assert r.status_code == 201, r.text
    plans = r.json()
    assert len(plans) == len(draft["slots"])
    today_plan = next(p for p in plans if p["date"] == today.isoformat())
    assert len(today_plan["items"]) == 5

    # 4. 식판 사진 업로드 → 즉시 접수(202), 분석은 백그라운드
    r = await client.post(
        "/api/meals/photo",
        files={"file": ("tray.jpg", make_photo("tray-1"), "image/jpeg")},
        data={"canteen_id": str(canteen["id"]), "meal_type": "lunch"},
        headers=h,
    )
    assert r.status_code == 202, r.text
    meal = r.json()
    assert meal["status"] == "pending"
    assert meal["items"] == []

    # 5. 워커가 처리
    assert await run_due_jobs() == 1

    r = await client.get(f"/api/meals/{meal['id']}", headers=h)
    assert r.status_code == 200
    meal = r.json()
    assert meal["status"] == "ready", meal.get("error")
    assert meal["items"], "analysis should produce items"
    assert meal["kcal"] > 0
    assert meal["open_mode"] is False, "menu plan existed → 객관식 모드"
    assert meal["calls_used"] == 5, "cold slot pays the full K"
    assert meal["cache_hit"] is False

    # 매칭된 항목은 식단표의 메뉴를 가리켜야 한다
    assert any(i["menu_item_id"] for i in meal["items"])

    # 6. 자연어 수정
    rice = next(i for i in meal["items"] if i["category"] == "rice")
    r = await client.post(
        f"/api/meals/{meal['id']}/edit",
        json={"text": f"{rice['name']} 150으로"},
        headers=h,
    )
    assert r.status_code == 200, r.text
    result = r.json()
    assert result["action"] == "set_grams"
    edited = next(
        i for i in result["meal"]["items"] if i["id"] == rice["id"]
    )
    assert edited["final_g"] == 150.0
    assert edited["edited_by_user"] is True

    # 7. 세트로 저장 → 1탭 재사용
    r = await client.post(
        "/api/meal-sets/from-meal",
        json={"meal_id": meal["id"], "name": "생활관 점심"},
        headers=h,
    )
    assert r.status_code == 201, r.text
    meal_set = r.json()

    r = await client.post(
        f"/api/meal-sets/{meal_set['id']}/apply",
        json={"meal_type": "dinner"},
        headers=h,
    )
    assert r.status_code == 201, r.text
    applied = r.json()
    assert applied["source"] == "meal_set"
    assert applied["status"] == "ready"
    assert applied["calls_used"] == 0, "재사용은 모델 호출이 0이어야 한다"
    assert len(applied["items"]) == len(meal["items"])

    # 8. 오늘 화면
    r = await client.get("/api/today", headers=h)
    assert r.status_code == 200
    view = r.json()
    assert view["summary"]["meals"] == 2
    assert view["summary"]["kcal"] > 0
    assert view["quick_sets"][0]["name"] == "생활관 점심"


@pytest.mark.asyncio
async def test_second_shooter_reuses_the_baseline(client):
    """The cost architecture: first shooter pays K=5, the next pays K=1."""
    owner = await register(client, "owner@example.com", "주인")
    r = await client.post(
        "/api/canteens", json={"name": "구내식당"}, headers=owner["headers"]
    )
    canteen = r.json()

    today = local_today()
    await client.put(
        f"/api/canteens/{canteen['id']}/menu-plans",
        json={
            "date": today.isoformat(),
            "meal_type": "lunch",
            "items": [
                {"name": "잡곡밥", "category": "rice", "standard_g": 210},
                {"name": "된장찌개", "category": "soup", "standard_g": 250},
                {"name": "제육볶음", "category": "main", "standard_g": 120},
            ],
        },
        headers=owner["headers"],
    )

    # 동료가 같은 식당에 합류
    mate = await register(client, "mate@example.com", "동료")
    r = await client.post(
        "/api/canteens/join",
        json={"join_code": canteen["join_code"]},
        headers=mate["headers"],
    )
    assert r.status_code == 200

    photo = make_photo("shared-tray")

    r = await client.post(
        "/api/meals/photo",
        files={"file": ("t.jpg", photo, "image/jpeg")},
        data={"canteen_id": str(canteen["id"]), "meal_type": "lunch"},
        headers=owner["headers"],
    )
    first_id = r.json()["id"]
    await run_due_jobs()
    first = (await client.get(f"/api/meals/{first_id}", headers=owner["headers"])).json()
    assert first["calls_used"] == 5
    assert first["cache_hit"] is False

    r = await client.post(
        "/api/meals/photo",
        files={"file": ("t.jpg", photo, "image/jpeg")},
        data={"canteen_id": str(canteen["id"]), "meal_type": "lunch"},
        headers=mate["headers"],
    )
    second_id = r.json()["id"]
    await run_due_jobs()
    second = (await client.get(f"/api/meals/{second_id}", headers=mate["headers"])).json()

    assert second["status"] == "ready"
    # Warm slot: 1 call if the reading agrees with the baseline, 1+3 if it
    # disagrees and escalates. Either way it costs less than a cold K=5.
    assert second["calls_used"] < first["calls_used"], "warm slot must cost less"
    assert second["calls_used"] in (1, 4)
    # cache_hit is true exactly when no escalation was needed.
    assert second["cache_hit"] is (second["calls_used"] == 1)


@pytest.mark.asyncio
async def test_open_mode_when_no_menu_plan(client):
    """식단표가 없으면 열린 인식 모드로 떨어지고, 그 사실이 결과에 표시된다."""
    me = await register(client, "open@example.com")
    r = await client.post(
        "/api/meals/photo",
        files={"file": ("t.jpg", make_photo("nomenu"), "image/jpeg")},
        headers=me["headers"],
    )
    meal_id = r.json()["id"]
    await run_due_jobs()

    meal = (await client.get(f"/api/meals/{meal_id}", headers=me["headers"])).json()
    assert meal["status"] == "ready"
    assert meal["open_mode"] is True
    assert meal["items"], "open mode still produces a best-effort reading"
    # 열린 인식은 신뢰도가 낮게 표시되어야 한다
    assert all(i["confidence"] < 0.7 for i in meal["items"])


@pytest.mark.asyncio
async def test_correcting_the_slot_reanalyses_against_the_menu(client):
    """A late dinner shot at 23:30 is inferred as 간식 and misses the menu
    plan. Fixing the slot must re-run analysis, not just relabel it."""
    me = await register(client, "slot@example.com")
    h = me["headers"]

    canteen = (
        await client.post("/api/canteens", json={"name": "야간식당"}, headers=h)
    ).json()
    today = local_today()
    await client.put(
        f"/api/canteens/{canteen['id']}/menu-plans",
        json={
            "date": today.isoformat(),
            "meal_type": "dinner",
            "items": [
                {"name": "잡곡밥", "category": "rice", "standard_g": 210},
                {"name": "김치찌개", "category": "soup", "standard_g": 250},
            ],
        },
        headers=h,
    )

    # 23:30 local → inferred as 간식, so no menu plan matches.
    late = datetime.combine(today, time(14, 30), tzinfo=timezone.utc)  # 23:30 KST
    r = await client.post(
        "/api/meals/photo",
        files={"file": ("t.jpg", make_photo("late"), "image/jpeg")},
        data={"canteen_id": str(canteen["id"]), "shot_at": late.isoformat()},
        headers=h,
    )
    meal_id = r.json()["id"]
    assert r.json()["meal_type"] == "snack"
    await run_due_jobs()

    meal = (await client.get(f"/api/meals/{meal_id}", headers=h)).json()
    assert meal["open_mode"] is True

    r = await client.patch(f"/api/meals/{meal_id}", json={"meal_type": "dinner"}, headers=h)
    assert r.status_code == 200
    assert r.json()["status"] == "pending", "슬롯을 고치면 다시 분석해야 한다"
    await run_due_jobs()

    meal = (await client.get(f"/api/meals/{meal_id}", headers=h)).json()
    assert meal["meal_type"] == "dinner"
    assert meal["open_mode"] is False
    assert any(i["menu_item_id"] for i in meal["items"]), "이제 식단표에 매칭돼야 한다"


@pytest.mark.asyncio
async def test_manual_meal_costs_nothing(client):
    me = await register(client, "manual@example.com")
    r = await client.post(
        "/api/meals/manual",
        json={
            "meal_type": "lunch",
            "items": [
                {"name": "흰쌀밥", "final_g": 210},
                {"name": "김치찌개", "final_g": 250},
            ],
        },
        headers=me["headers"],
    )
    assert r.status_code == 201, r.text
    meal = r.json()
    assert meal["status"] == "ready"
    assert meal["calls_used"] == 0
    assert meal["kcal"] > 300
    # 이름으로 영양 DB에 매칭되어야 한다
    assert all(i["food_id"] for i in meal["items"])


@pytest.mark.asyncio
async def test_weight_trend_and_target(client):
    me = await register(client, "weight@example.com")
    h = me["headers"]

    await client.patch(
        "/api/auth/me",
        json={"height_cm": 175, "birth_year": 1995, "sex": "male", "goal_type": "lose"},
        headers=h,
    )

    base = local_today() - timedelta(days=6)
    for i, kg in enumerate([80.0, 80.4, 79.8, 79.9, 79.6, 79.7, 79.4]):
        r = await client.post(
            "/api/weights",
            json={"date": (base + timedelta(days=i)).isoformat(), "raw_kg": kg},
            headers=h,
        )
        assert r.status_code == 201, r.text

    r = await client.get("/api/weights", headers=h)
    rows = r.json()
    assert len(rows) == 7
    # 추세는 원시값보다 평탄해야 한다
    raw_spread = max(x["raw_kg"] for x in rows) - min(x["raw_kg"] for x in rows)
    trend_spread = max(x["trend_kg"] for x in rows) - min(x["trend_kg"] for x in rows)
    assert trend_spread < raw_spread

    # 데이터가 3주에 못 미치므로 BMR 기반으로 떨어져야 한다
    r = await client.get("/api/targets/tdee", headers=h)
    est = r.json()
    assert est["method"] in ("bmr", "adaptive", "insufficient_data")

    r = await client.post("/api/targets/refresh", headers=h)
    assert r.status_code == 200, r.text
    target = r.json()
    assert target["target_kcal"] > 1000

    # 사용자는 목표를 덮어쓸 수 있다
    r = await client.put(
        "/api/targets/current",
        json={"target_kcal": 2100, "target_protein_g": 140, "pinned": True},
        headers=h,
    )
    assert r.status_code == 200, r.text
    assert r.json()["target_kcal"] == 2100
    assert r.json()["pinned"] is True

    # 기초대사량 아래로는 못 내린다
    r = await client.put(
        "/api/targets/current", json={"target_kcal": 900}, headers=h
    )
    assert r.status_code == 422
    assert r.json()["error"] == "safety_guard"


@pytest.mark.asyncio
async def test_retry_failed_meal(client, monkeypatch):
    me = await register(client, "retry@example.com")
    h = me["headers"]

    from app.errors import UpstreamError
    from app.vision import get_provider

    provider = get_provider()
    original = provider.analyze_tray

    async def boom(_req):
        raise UpstreamError("모델이 삐졌습니다")

    monkeypatch.setattr(provider, "analyze_tray", boom)

    r = await client.post(
        "/api/meals/photo",
        files={"file": ("t.jpg", make_photo("fail"), "image/jpeg")},
        headers=h,
    )
    meal_id = r.json()["id"]
    await run_due_jobs()

    meal = (await client.get(f"/api/meals/{meal_id}", headers=h)).json()
    assert meal["status"] == "failed"
    assert meal["error"]

    monkeypatch.setattr(provider, "analyze_tray", original)
    r = await client.post(f"/api/meals/{meal_id}/retry", headers=h)
    assert r.status_code == 200
    await run_due_jobs()

    meal = (await client.get(f"/api/meals/{meal_id}", headers=h)).json()
    assert meal["status"] == "ready"
    assert meal["error"] is None


@pytest.mark.asyncio
async def test_food_search(client):
    me = await register(client, "search@example.com")
    r = await client.get("/api/foods/search", params={"q": "김치찌게"}, headers=me["headers"])
    assert r.status_code == 200
    results = r.json()
    assert results
    assert results[0]["food"]["name"] == "김치찌개"
    assert results[0]["score"] > 0.8
