"""Mentorship: consent, delegated writes, the weight rule, and revocation."""

from __future__ import annotations

import pytest

from tests.conftest import make_photo, register


async def connect(client, mentor, mentee, permissions: dict[str, bool], type_="coach"):
    r = await client.post(
        "/api/mentorships/invite", json={"type": type_}, headers=mentor["headers"]
    )
    assert r.status_code == 201, r.text
    code = r.json()["invite_code"]

    r = await client.post(
        "/api/mentorships/accept",
        json={"invite_code": code, "permissions": permissions},
        headers=mentee["headers"],
    )
    assert r.status_code == 200, r.text
    return r.json()


@pytest.mark.asyncio
async def test_invite_preview_shows_scopes_before_consent(client):
    coach = await register(client, "coach1@example.com", "트레이너")
    r = await client.post(
        "/api/mentorships/invite", json={"type": "coach"}, headers=coach["headers"]
    )
    code = r.json()["invite_code"]

    # No auth needed: this is the screen shown before the mentee decides.
    r = await client.get(f"/api/mentorships/invite/{code}")
    assert r.status_code == 200
    preview = r.json()
    assert preview["mentor_name"] == "트레이너"
    scopes = {s["scope"] for s in preview["scopes"]}
    assert "workout:write" in scopes
    assert "diet:read" in scopes
    # 체중 대리 입력이라는 선택지 자체가 존재하지 않아야 한다.
    assert not any("weight:write" in s for s in scopes)
    assert preview["weight_write_available"] is False


@pytest.mark.asyncio
async def test_defaults_are_off(client):
    coach = await register(client, "coach2@example.com")
    mentee = await register(client, "mentee2@example.com")
    m = await connect(client, coach, mentee, permissions={})
    assert all(v is False for v in m["permissions"].values())

    # 아무것도 허용하지 않았으므로 조회도 막혀야 한다
    r = await client.get(
        "/api/meals", params={"user_id": mentee["user"]["id"]}, headers=coach["headers"]
    )
    assert r.status_code == 403


@pytest.mark.asyncio
async def test_coach_can_log_a_workout_and_it_is_labelled(client):
    coach = await register(client, "coach3@example.com", "김코치")
    mentee = await register(client, "mentee3@example.com", "박멘티")
    await connect(
        client,
        coach,
        mentee,
        {"workout:read": True, "workout:write": True},
    )

    # Route A: a photo of the notebook.
    r = await client.post(
        "/api/workouts/photo",
        files={"file": ("note.jpg", make_photo("note"), "image/jpeg")},
        data={"for_user_id": str(mentee["user"]["id"])},
        headers=coach["headers"],
    )
    assert r.status_code == 201, r.text
    workout = r.json()
    assert workout["user_id"] == mentee["user"]["id"]
    assert workout["logged_by"] == coach["user"]["id"]
    assert workout["logged_by_name"] == "김코치"
    assert workout["sets"]

    # 멘티 화면에도 보이고, 누가 썼는지 표시된다
    r = await client.get("/api/workouts", headers=mentee["headers"])
    mine = r.json()
    assert len(mine) == 1
    assert mine[0]["logged_by_name"] == "김코치"

    # 그리고 감사 로그에 남는다
    r = await client.get("/api/audit-log", headers=mentee["headers"])
    log = r.json()
    assert any(
        e["entity"] == "workout" and e["actor_name"] == "김코치" for e in log
    )


@pytest.mark.asyncio
async def test_mentee_can_undo_a_delegated_record(client):
    """되돌리기: 멘티는 대리 기록을 언제든 수정·삭제할 수 있다."""
    coach = await register(client, "coach4@example.com")
    mentee = await register(client, "mentee4@example.com")
    await connect(client, coach, mentee, {"workout:write": True, "workout:read": True})

    r = await client.post(
        "/api/workouts/text",
        json={
            "user_id": mentee["user"]["id"],
            "text": "스쿼트 60에 10개 3세트",
        },
        headers=coach["headers"],
    )
    assert r.status_code == 201, r.text
    workout = r.json()
    assert len(workout["sets"]) == 3

    r = await client.delete(f"/api/workouts/{workout['id']}", headers=mentee["headers"])
    assert r.status_code == 200
    assert (await client.get("/api/workouts", headers=mentee["headers"])).json() == []


@pytest.mark.asyncio
async def test_scope_is_enforced_per_domain(client):
    """운동 권한만 준 코치는 식단을 못 쓴다."""
    coach = await register(client, "coach5@example.com")
    mentee = await register(client, "mentee5@example.com")
    await connect(client, coach, mentee, {"workout:write": True})

    r = await client.post(
        "/api/meals/photo",
        files={"file": ("t.jpg", make_photo("x"), "image/jpeg")},
        data={"for_user_id": str(mentee["user"]["id"])},
        headers=coach["headers"],
    )
    assert r.status_code == 403
    assert r.json()["error"] == "forbidden"


@pytest.mark.asyncio
async def test_there_is_no_way_to_write_someone_elses_weight(client):
    """체중은 본인만 입력한다 — 어떤 scope로도 열리지 않는다.

    The endpoint takes no ``user_id`` at all, which is the enforcement: there
    is no request you can construct that writes another account's weight.
    """
    coach = await register(client, "coach6@example.com")
    mentee = await register(client, "mentee6@example.com")
    await connect(
        client,
        coach,
        mentee,
        {k: True for k in ("diet:read", "diet:write", "workout:read",
                           "workout:write", "weight:read", "photo:read",
                           "goal:propose")},
    )

    # Even with every scope granted, a coach's weight POST records their own.
    r = await client.post(
        "/api/weights",
        json={"raw_kg": 70.0, "user_id": mentee["user"]["id"]},
        headers=coach["headers"],
    )
    assert r.status_code == 201
    assert (await client.get("/api/weights", headers=mentee["headers"])).json() == []

    # And the guard function refuses explicitly.
    from app.services.permissions import WeightWriteForbidden, require_self_for_weight

    with pytest.raises(WeightWriteForbidden):
        require_self_for_weight(coach["user"]["id"], mentee["user"]["id"])


@pytest.mark.asyncio
async def test_coach_goal_proposal_is_inert_until_accepted(client):
    coach = await register(client, "coach7@example.com")
    mentee = await register(client, "mentee7@example.com")
    await client.patch(
        "/api/auth/me",
        json={"height_cm": 175, "birth_year": 1995, "sex": "male"},
        headers=mentee["headers"],
    )
    await client.post("/api/weights", json={"raw_kg": 75.0}, headers=mentee["headers"])
    await connect(client, coach, mentee, {"goal:propose": True, "diet:read": True})

    r = await client.post(
        "/api/targets/propose",
        json={
            "user_id": mentee["user"]["id"],
            "target_kcal": 2000,
            "target_protein_g": 140,
            "note": "이번 달은 이 정도로",
        },
        headers=coach["headers"],
    )
    assert r.status_code == 201, r.text
    proposal = r.json()
    assert proposal["accepted_at"] is None, "제안은 수락 전까지 효력이 없다"
    assert proposal["method"] == "coach"

    # 멘티에게 알림이 간다
    notes = (await client.get("/api/notifications", headers=mentee["headers"])).json()
    assert any(n["kind"] == "target_proposed" for n in notes)

    r = await client.post(
        f"/api/targets/{proposal['id']}/accept", headers=mentee["headers"]
    )
    assert r.status_code == 200
    assert r.json()["accepted_at"] is not None


@pytest.mark.asyncio
async def test_coach_cannot_propose_below_bmr(client):
    """기초대사량 하한은 시스템이 강제한다 — 코치도 예외가 아니다."""
    coach = await register(client, "coach8@example.com")
    mentee = await register(client, "mentee8@example.com")
    await client.patch(
        "/api/auth/me",
        json={"height_cm": 180, "birth_year": 1990, "sex": "male"},
        headers=mentee["headers"],
    )
    await client.post("/api/weights", json={"raw_kg": 85.0}, headers=mentee["headers"])
    await connect(client, coach, mentee, {"goal:propose": True})

    r = await client.post(
        "/api/targets/propose",
        json={"user_id": mentee["user"]["id"], "target_kcal": 1000, "target_protein_g": 150},
        headers=coach["headers"],
    )
    assert r.status_code == 422
    assert r.json()["error"] == "safety_guard"
    assert "기초대사량" in r.json()["message"]


@pytest.mark.asyncio
async def test_revocation_is_immediate(client):
    coach = await register(client, "coach9@example.com")
    mentee = await register(client, "mentee9@example.com")
    m = await connect(client, coach, mentee, {"diet:read": True, "workout:read": True})

    r = await client.get(
        "/api/meals", params={"user_id": mentee["user"]["id"]}, headers=coach["headers"]
    )
    assert r.status_code == 200

    r = await client.put(
        f"/api/mentorships/{m['id']}/permissions",
        json={"permissions": {"diet:read": False}},
        headers=mentee["headers"],
    )
    assert r.status_code == 200

    r = await client.get(
        "/api/meals", params={"user_id": mentee["user"]["id"]}, headers=coach["headers"]
    )
    assert r.status_code == 403


@pytest.mark.asyncio
async def test_ending_a_mentorship_cuts_access(client):
    coach = await register(client, "coach10@example.com")
    mentee = await register(client, "mentee10@example.com")
    m = await connect(client, coach, mentee, {"diet:read": True})

    r = await client.delete(f"/api/mentorships/{m['id']}", headers=mentee["headers"])
    assert r.status_code == 200

    r = await client.get(
        "/api/meals", params={"user_id": mentee["user"]["id"]}, headers=coach["headers"]
    )
    assert r.status_code == 403
    assert (
        await client.get("/api/mentorships", headers=coach["headers"])
    ).json() == []


@pytest.mark.asyncio
async def test_dashboard_hides_ungranted_sections(client):
    coach = await register(client, "coach11@example.com")
    mentee = await register(client, "mentee11@example.com", "가림")
    await connect(client, coach, mentee, {"workout:read": True})

    cards = (
        await client.get("/api/mentorships/dashboard", headers=coach["headers"])
    ).json()
    assert len(cards) == 1
    card = cards[0]
    assert card["nickname"] == "가림"
    assert card["workouts_today"] is not None
    assert card["meals_today"] is None, "diet:read 없이 식단 수가 보이면 안 된다"
    assert card["weight_today"] is None


@pytest.mark.asyncio
async def test_peer_mentor_limit(client):
    """동료 멘토는 최대 2명."""
    peer = await register(client, "peer@example.com")
    for i in range(2):
        m = await register(client, f"buddy{i}@example.com")
        await connect(client, peer, m, {"workout:read": True}, type_="peer")

    r = await client.post(
        "/api/mentorships/invite", json={"type": "peer"}, headers=peer["headers"]
    )
    assert r.status_code == 422
    assert "멘티 수를 초과" in r.json()["message"]


@pytest.mark.asyncio
async def test_photo_scope_is_separate_from_diet_scope(client):
    """사진은 얼굴·명찰이 찍힐 수 있어 별도 권한으로 분리한다."""
    coach = await register(client, "coach12@example.com")
    mentee = await register(client, "mentee12@example.com")
    await connect(client, coach, mentee, {"diet:read": True})  # photo:read 없음

    r = await client.post(
        "/api/meals/photo",
        files={"file": ("t.jpg", make_photo("private"), "image/jpeg")},
        headers=mentee["headers"],
    )
    meal = r.json()

    r = await client.get(f"/api/media/{meal['photo_path']}", headers=coach["headers"])
    assert r.status_code == 403

    r = await client.get(f"/api/media/{meal['photo_path']}", headers=mentee["headers"])
    assert r.status_code == 200
    assert r.headers["content-type"] == "image/jpeg"
