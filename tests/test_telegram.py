"""The Telegram bridge — the Phase 1 client with no app to build."""

from __future__ import annotations

import pytest

from app.integrations import telegram
from app.models import User
from tests.conftest import make_photo, register


def update(chat_id: str, text: str | None = None, photo: bool = False) -> dict:
    msg: dict = {"chat": {"id": chat_id}}
    if text is not None:
        msg["text"] = text
    if photo:
        msg["photo"] = [{"file_id": "small"}, {"file_id": "large"}]
    return {"message": msg}


@pytest.fixture(autouse=True)
def _silence_outbound(monkeypatch):
    """Never touch api.telegram.org from a test."""
    sent: list[tuple[str, str]] = []

    async def fake_send(chat_id, text):
        sent.append((str(chat_id), text))

    monkeypatch.setattr(telegram, "send_message", fake_send)
    return sent


@pytest.mark.asyncio
async def test_unlinked_chat_is_told_how_to_link(db):
    reply = await telegram.handle_update(db, update("999", "안녕"))
    assert "연결되어 있지 않습니다" in reply
    assert "/link" in reply


@pytest.mark.asyncio
async def test_link_with_an_ingest_token(client, db):
    me = await register(client, "tg@example.com", "텔레")
    r = await client.post(
        "/api/auth/tokens", json={"name": "telegram"}, headers=me["headers"]
    )
    token = r.json()["token"]

    reply = await telegram.handle_update(db, update("42", f"/link {token}"))
    assert "연결했습니다" in reply

    user = await db.get(User, me["user"]["id"])
    await db.refresh(user)
    assert user.telegram_chat_id == "42"


@pytest.mark.asyncio
async def test_bad_token_is_rejected(db):
    reply = await telegram.handle_update(db, update("43", "/link sk_dead_beef"))
    assert "유효하지 않은" in reply


async def _link_chat(client, db, email, chat_id):
    me = await register(client, email)
    r = await client.post(
        "/api/auth/tokens", json={"name": "tg"}, headers=me["headers"]
    )
    await telegram.handle_update(db, update(chat_id, f"/link {r.json()['token']}"))
    await db.commit()
    return me


@pytest.mark.asyncio
async def test_a_bare_number_is_a_weight(client, db):
    await _link_chat(client, db, "w@example.com", "50")
    reply = await telegram.handle_update(db, update("50", "72.4"))
    assert "72.4kg 기록" in reply
    assert "추세" in reply


@pytest.mark.asyncio
async def test_a_sentence_becomes_a_workout(client, db):
    await _link_chat(client, db, "wo@example.com", "51")
    reply = await telegram.handle_update(
        db, update("51", "스쿼트 60에 10개 3세트, 랫풀 50에 12개 3세트")
    )
    assert "6세트 기록" in reply


@pytest.mark.asyncio
async def test_photo_is_queued_for_analysis(client, db, monkeypatch):
    me = await _link_chat(client, db, "p@example.com", "52")

    async def fake_download(_file_id):
        return make_photo("tg-tray")

    monkeypatch.setattr(telegram, "_download_photo", fake_download)

    reply = await telegram.handle_update(db, update("52", photo=True))
    assert "접수했습니다" in reply
    await db.commit()

    from app.jobs.queue import run_due_jobs

    assert await run_due_jobs() >= 1

    r = await client.get("/api/meals", headers=me["headers"])
    meals = r.json()
    assert len(meals) == 1
    assert meals[0]["status"] == "ready"
    assert meals[0]["items"]


@pytest.mark.asyncio
async def test_text_edits_the_last_meal(client, db):
    me = await _link_chat(client, db, "e@example.com", "53")
    await client.post(
        "/api/meals/manual",
        json={"meal_type": "lunch", "items": [{"name": "흰쌀밥", "final_g": 210}]},
        headers=me["headers"],
    )

    reply = await telegram.handle_update(db, update("53", "흰쌀밥 150으로"))
    assert "150g으로" in reply
    await db.commit()

    r = await client.get("/api/meals", headers=me["headers"])
    assert r.json()[0]["items"][0]["final_g"] == 150.0


@pytest.mark.asyncio
async def test_today_summary(client, db):
    me = await _link_chat(client, db, "t@example.com", "54")
    await client.post(
        "/api/meals/manual",
        json={"meal_type": "lunch", "items": [{"name": "잡곡밥", "final_g": 210}]},
        headers=me["headers"],
    )
    reply = await telegram.handle_update(db, update("54", "/오늘"))
    assert "kcal" in reply
    assert "1끼" in reply


@pytest.mark.asyncio
async def test_webhook_secret_is_enforced(client, monkeypatch):
    from app.config import settings
    from app.errors import Unauthorized

    monkeypatch.setattr(settings, "telegram_webhook_secret", "s3cret")
    with pytest.raises(Unauthorized):
        telegram.verify_webhook_secret("wrong")
    telegram.verify_webhook_secret("s3cret")  # does not raise

    r = await client.post(
        "/api/integrations/telegram/webhook",
        json=update("1", "hi"),
        headers={"X-Telegram-Bot-Api-Secret-Token": "nope"},
    )
    assert r.status_code == 401
