"""계정 삭제.

어려운 부분은 무엇을 지우는가가 아니라 **무엇을 지우지 않는가** 다. users 행
하나를 지우면 외래키 CASCADE가 남의 데이터까지 데려간다. 여기 있는 테스트는
전부 "남은 사람 쪽이 멀쩡한가"를 묻는다.
"""

import pytest
from httpx import AsyncClient
from sqlalchemy import select

from app.models import AuditLog, Battle, Canteen, Meal, User
from tests.conftest import register
from tests.test_permissions import connect


@pytest.mark.asyncio
async def test_내_계정과_내_기록이_사라진다(client: AsyncClient, db, photo_bytes):
    auth = await register(client, "gone@example.com")
    r = await client.post(
        "/api/meals/photo",
        headers=auth["headers"],
        files={"file": ("t.jpg", photo_bytes, "image/jpeg")},
    )
    assert r.status_code == 202
    user_id = auth["user"]["id"]

    r = await client.request(
        "DELETE",
        "/api/auth/me",
        headers=auth["headers"],
        json={"email": "gone@example.com"},
    )
    assert r.status_code == 200, r.text

    assert (await db.get(User, user_id)) is None
    rows = (
        await db.execute(select(Meal).where(Meal.user_id == user_id))
    ).scalars().all()
    assert rows == []


@pytest.mark.asyncio
async def test_이메일이_다르면_지우지_않는다(client: AsyncClient, db):
    auth = await register(client, "typo@example.com")
    r = await client.request(
        "DELETE",
        "/api/auth/me",
        headers=auth["headers"],
        json={"email": "other@example.com"},
    )
    assert r.status_code == 403, r.text
    assert (await db.get(User, auth["user"]["id"])) is not None


@pytest.mark.asyncio
async def test_코치가_탈퇴해도_멘티의_기록은_남는다(client: AsyncClient, db, photo_bytes):
    """대리 기록한 끼니는 멘티의 건강 기록이다. 코치가 나갔다고 사라지면 안 된다."""
    mentee = await register(client, "mentee@example.com")
    coach = await register(client, "coach@example.com")

    # 코치가 초대를 만들고, 멘티가 항목을 켜서 수락한다.
    await connect(
        client, coach, mentee, {"diet:read": True, "diet:write": True}
    )

    # 코치가 멘티 대신 끼니를 올린다.
    r = await client.post(
        "/api/meals/photo",
        headers=coach["headers"],
        files={"file": ("t.jpg", photo_bytes, "image/jpeg")},
        data={"for_user_id": str(mentee["user"]["id"])},
    )
    assert r.status_code == 202, r.text
    meal_id = r.json()["id"]

    # 코치가 탈퇴한다.
    r = await client.request(
        "DELETE",
        "/api/auth/me",
        headers=coach["headers"],
        json={"email": "coach@example.com"},
    )
    assert r.status_code == 200, r.text

    meal = await db.get(Meal, meal_id)
    assert meal is not None, "코치가 탈퇴하자 멘티의 끼니가 사라졌다"
    assert meal.user_id == mentee["user"]["id"]
    assert meal.logged_by == mentee["user"]["id"], "작성자가 소유자로 돌아가야 한다"


@pytest.mark.asyncio
async def test_멘티는_누가_손댔는지_계속_볼_수_있다(client: AsyncClient, db, photo_bytes):
    """행위자가 탈퇴해도 당한 사람의 감사 기록은 남는다 — 신원만 지워진다."""
    mentee = await register(client, "audited@example.com")
    coach = await register(client, "actor@example.com")

    await connect(
        client, coach, mentee, {"diet:read": True, "diet:write": True}
    )
    await client.post(
        "/api/meals/photo",
        headers=coach["headers"],
        files={"file": ("t.jpg", photo_bytes, "image/jpeg")},
        data={"for_user_id": str(mentee["user"]["id"])},
    )

    mentee_id = mentee["user"]["id"]
    before = (
        await db.execute(
            select(AuditLog).where(AuditLog.target_user_id == mentee_id)
        )
    ).scalars().all()
    assert before, "대리 기록이 감사 로그에 남지 않았다"

    await client.request(
        "DELETE",
        "/api/auth/me",
        headers=coach["headers"],
        json={"email": "actor@example.com"},
    )

    # 앞에서 이미 읽어 둔 객체가 세션에 남아 있으면 옛 값을 그대로 돌려줍니다.
    db.expire_all()
    after = (
        await db.execute(
            select(AuditLog).where(AuditLog.target_user_id == mentee_id)
        )
    ).scalars().all()
    assert len(after) == len(before), "멘티의 감사 기록이 사라졌다"
    assert all(r.actor_user_id is None for r in after), "탈퇴한 사람의 신원이 남았다"


@pytest.mark.asyncio
async def test_식당_주인이_탈퇴하면_남은_사람에게_넘어간다(client: AsyncClient, db):
    """한 명이 올린 식단표를 전부가 쓰는 구조라, 주인이 나갔다고 통째로
    사라지면 피해가 크다."""
    owner = await register(client, "owner@example.com")
    member = await register(client, "member@example.com")

    r = await client.post(
        "/api/canteens", headers=owner["headers"], json={"name": "구내식당"}
    )
    assert r.status_code == 201, r.text
    canteen_id, join_code = r.json()["id"], r.json()["join_code"]

    r = await client.post(
        "/api/canteens/join", headers=member["headers"], json={"join_code": join_code}
    )
    assert r.status_code in (200, 201), r.text

    await client.request(
        "DELETE",
        "/api/auth/me",
        headers=owner["headers"],
        json={"email": "owner@example.com"},
    )

    canteen = await db.get(Canteen, canteen_id)
    assert canteen is not None, "주인이 탈퇴하자 식당이 통째로 사라졌다"
    assert canteen.owner_user_id == member["user"]["id"]


@pytest.mark.asyncio
async def test_아무도_없는_식당은_같이_지운다(client: AsyncClient, db):
    owner = await register(client, "solo@example.com")
    r = await client.post(
        "/api/canteens", headers=owner["headers"], json={"name": "혼자 식당"}
    )
    canteen_id = r.json()["id"]

    await client.request(
        "DELETE",
        "/api/auth/me",
        headers=owner["headers"],
        json={"email": "solo@example.com"},
    )
    assert (await db.get(Canteen, canteen_id)) is None


@pytest.mark.asyncio
async def test_삭제_후_이메일이_남지_않는다(client: AsyncClient, db):
    """login_codes는 users를 가리키지 않고 이메일 문자열만 들고 있다. 외래키가
    없으니 CASCADE도 없고, 그대로 두면 '계정을 지웠다'고 해 놓고 주소가 DB에
    남는다."""
    from app.models import LoginCode

    email = "trace@example.com"
    auth = await register(client, email)
    await client.request(
        "DELETE", "/api/auth/me", headers=auth["headers"], json={"email": email}
    )

    rows = (
        await db.execute(select(LoginCode).where(LoginCode.email == email))
    ).scalars().all()
    assert rows == [], "탈퇴 후에도 이메일이 login_codes에 남아 있다"
