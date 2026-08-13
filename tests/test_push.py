"""푸시 알림.

여기서 지키려는 것은 "알림이 나간다"가 아니라 **"나가면 안 될 때 안 나간다"**
입니다. 하루 2회 상한은 로드맵의 "만들지 않을 것"에 적힌 제품 결정이고,
죽은 토큰 정리는 큐가 막히지 않기 위한 운영 요구입니다.
"""

from __future__ import annotations

import pytest
from sqlalchemy import select

from app.jobs.queue import run_due_jobs
from app.models import DevicePlatform, DeviceToken, Job, Notification
from app.services import push
from app.services.notify import notify
from tests.conftest import register


def fcm_token(seed: str) -> str:
    """실제 FCM 토큰과 비슷한 길이의 문자열. 짧은 더미를 쓰면 길이 검증만
    우회하고 실제와 닮지 않습니다."""
    return f"{seed}:APA91b" + "x" * 120


class FakeProvider(push.PushProvider):
    """보낸 것을 기억하는 가짜. 토큰별로 결과를 지정할 수 있습니다."""

    name = "fake"

    def __init__(self, dead: set[str] | None = None, boom: set[str] | None = None):
        self.sent: list[push.PushMessage] = []
        self.dead = dead or set()
        self.boom = boom or set()

    async def send(self, message: push.PushMessage) -> bool:
        if message.token in self.dead:
            raise push.DeadToken("UNREGISTERED")
        if message.token in self.boom:
            raise RuntimeError("일시적 장애")
        self.sent.append(message)
        return True


@pytest.fixture(autouse=True)
def _fake_provider():
    fake = FakeProvider()
    push.set_provider(fake)
    yield fake
    push.set_provider(None)


async def _user_with_device(client, db, email: str, token: str) -> int:
    me = await register(client, email)
    r = await client.post(
        "/api/devices",
        json={"token": token, "platform": "ios"},
        headers=me["headers"],
    )
    assert r.status_code == 201, r.text
    return me["user"]["id"]


@pytest.mark.asyncio
async def test_기기_등록과_해제(client, db):
    me = await register(client, "dev@example.com")
    r = await client.post(
        "/api/devices",
        json={"token": fcm_token("tok-1"), "platform": "android", "app_version": "0.1.0"},
        headers=me["headers"],
    )
    assert r.status_code == 201
    device_id = r.json()["id"]
    assert r.json()["platform"] == "android"

    r = await client.get("/api/devices", headers=me["headers"])
    assert len(r.json()) == 1

    r = await client.delete(f"/api/devices/{device_id}", headers=me["headers"])
    assert r.status_code == 200
    r = await client.get("/api/devices", headers=me["headers"])
    assert r.json() == []


@pytest.mark.asyncio
async def test_같은_토큰이_다른_사용자에게_넘어가면_주인이_바뀐다(client, db):
    """기기를 중고로 넘긴 경우.

    토큰을 (user, token) 복합키로 두면 이전 주인에게도 알림이 계속 갑니다.
    남의 식사 기록 알림이 뜨는 것은 명백한 사고입니다.
    """
    first = await register(client, "old@example.com")
    second = await register(client, "new@example.com")

    await client.post(
        "/api/devices", json={"token": fcm_token("shared")}, headers=first["headers"]
    )
    await client.post(
        "/api/devices", json={"token": fcm_token("shared")}, headers=second["headers"]
    )
    await db.commit()

    rows = (
        await db.execute(select(DeviceToken).where(DeviceToken.token == fcm_token("shared")))
    ).scalars().all()
    assert len(rows) == 1, "토큰은 하나만 존재해야 합니다"
    assert rows[0].user_id == second["user"]["id"]


@pytest.mark.asyncio
async def test_알림을_만들면_푸시_잡이_예약된다(client, db, _fake_provider):
    user_id = await _user_with_device(client, db, "n@example.com", fcm_token("tok-n"))

    await notify(
        db,
        user_id=user_id,
        kind="meal_ready",
        title="식사 분석 완료",
        body="513kcal",
        payload={"meal_id": 7},
    )
    await db.commit()

    jobs = (
        await db.execute(select(Job).where(Job.kind == "push_notification"))
    ).scalars().all()
    assert len(jobs) == 1

    assert await run_due_jobs() >= 1
    assert len(_fake_provider.sent) == 1
    message = _fake_provider.sent[0]
    assert message.token == fcm_token("tok-n")
    assert message.title == "식사 분석 완료"
    # FCM data는 값이 전부 문자열이어야 합니다.
    assert message.data["meal_id"] == "7"
    assert all(isinstance(v, str) for v in message.data.values())


@pytest.mark.asyncio
async def test_push_False면_잡을_만들지_않는다(client, db):
    """앱에서 보이면 충분한 알림 — 독촉으로 기록을 왜곡시키지 않습니다."""
    user_id = await _user_with_device(client, db, "q@example.com", fcm_token("tok-q"))
    await notify(
        db, user_id=user_id, kind="quiet", title="조용한 알림", push=False
    )
    await db.commit()

    jobs = (
        await db.execute(select(Job).where(Job.kind == "push_notification"))
    ).scalars().all()
    assert jobs == []


@pytest.mark.asyncio
async def test_하루_두_번을_넘기지_않는다(client, db, _fake_provider):
    user_id = await _user_with_device(client, db, "cap@example.com", fcm_token("tok-cap"))

    for i in range(4):
        n = await notify(
            db, user_id=user_id, kind="meal_ready", title=f"알림 {i}"
        )
        await db.commit()
        await push.deliver(db, n.id)
        await db.commit()

    assert len(_fake_provider.sent) == push.MAX_PUSH_PER_DAY

    # 상한에 걸린 알림도 행은 남습니다 — 앱을 열면 보여야 합니다.
    rows = (
        await db.execute(select(Notification).where(Notification.user_id == user_id))
    ).scalars().all()
    assert len(rows) == 4


@pytest.mark.asyncio
async def test_죽은_토큰은_정리된다(client, db):
    """FCM이 UNREGISTERED를 주면 다시 보내지 않습니다.

    계속 재시도하면 큐가 그 기기 때문에 매번 실패합니다.
    """
    push.set_provider(FakeProvider(dead={fcm_token("tok-dead")}))
    user_id = await _user_with_device(client, db, "dead@example.com", fcm_token("tok-dead"))

    n = await notify(db, user_id=user_id, kind="meal_ready", title="확인")
    await db.commit()
    sent = await push.deliver(db, n.id)
    await db.commit()

    assert sent == 0
    row = (
        await db.execute(select(DeviceToken).where(DeviceToken.token == fcm_token("tok-dead")))
    ).scalar_one()
    assert row.revoked_at is not None


@pytest.mark.asyncio
async def test_한_기기가_실패해도_나머지에는_보낸다(client, db):
    provider = FakeProvider(boom={fcm_token("tok-bad")})
    push.set_provider(provider)

    me = await register(client, "multi@example.com")
    for token in (fcm_token("tok-bad"), fcm_token("tok-good")):
        await client.post(
            "/api/devices", json={"token": token}, headers=me["headers"]
        )
    await db.commit()

    n = await notify(db, user_id=me["user"]["id"], kind="meal_ready", title="확인")
    await db.commit()
    sent = await push.deliver(db, n.id)

    assert sent == 1
    assert provider.sent[0].token == fcm_token("tok-good")


@pytest.mark.asyncio
async def test_기기가_없으면_조용히_넘어간다(client, db, _fake_provider):
    me = await register(client, "nodevice@example.com")
    n = await notify(db, user_id=me["user"]["id"], kind="meal_ready", title="확인")
    await db.commit()

    assert await push.deliver(db, n.id) == 0
    assert _fake_provider.sent == []


@pytest.mark.asyncio
async def test_같은_알림을_두_번_보내지_않는다(client, db, _fake_provider):
    """잡이 재시도되어도 사용자에게 두 번 울리면 안 됩니다."""
    user_id = await _user_with_device(client, db, "once@example.com", fcm_token("tok-once"))
    n = await notify(db, user_id=user_id, kind="meal_ready", title="확인")
    await db.commit()

    await push.deliver(db, n.id)
    await db.commit()
    await push.deliver(db, n.id)

    assert len(_fake_provider.sent) == 1


@pytest.mark.asyncio
async def test_자격증명이_없으면_비활성이지만_알림은_남는다(db, client):
    """설정이 없다고 기능이 사라지지 않습니다."""
    push.set_provider(push.PushProvider())  # noop
    me = await register(client, "noop@example.com")
    await client.post(
        "/api/devices", json={"token": fcm_token("tok-noop")}, headers=me["headers"]
    )
    await db.commit()

    n = await notify(db, user_id=me["user"]["id"], kind="meal_ready", title="확인")
    await db.commit()
    assert await push.deliver(db, n.id) == 0

    r = await client.get("/api/notifications", headers=me["headers"])
    assert any(x["title"] == "확인" for x in r.json())
