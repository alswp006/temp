"""Telegram bridge — the Phase 1 client, with zero app development.

Why this exists at all: for the first three months the only user is the person
building it, and the fastest path to "사진 한 장 보내면 끝" is a chat window that
already has a camera button, push notifications, and an inbox. Everything here
maps onto the same API the PWA uses; nothing is Telegram-specific below this
module.

Message grammar (deliberately tiny — it has to be typeable one-handed):

* a photo               → 식사 기록
* ``72.4``              → 체중 기록
* ``/link sk_…``        → 계정 연결
* ``/오늘`` or ``/today`` → 오늘 요약
* anything else         → 마지막 식사에 대한 자연어 수정, 실패하면 운동 파싱
"""

from __future__ import annotations

import logging
import re

import httpx
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.core.security import split_api_token, verify_secret
from app.core.timeutil import infer_meal_type, local_date, today_local, utcnow
from app.errors import Unauthorized
from app.jobs.queue import enqueue
from app.models import (
    ApiToken,
    EntrySource,
    Meal,
    MealStatus,
    User,
)
from app.services import reports, targets, workouts
from app.services.edits import apply_natural_edit
from app.services.photos import process_upload

log = logging.getLogger(__name__)

API_ROOT = "https://api.telegram.org"
_WEIGHT = re.compile(r"^\s*(\d{2,3}(?:\.\d)?)\s*(?:kg|킬로)?\s*$")


async def send_message(chat_id: str | int, text: str) -> None:
    if not settings.telegram_bot_token:
        log.info("[telegram:dry-run] %s → %s", chat_id, text)
        return
    async with httpx.AsyncClient(timeout=15.0) as client:
        await client.post(
            f"{API_ROOT}/bot{settings.telegram_bot_token}/sendMessage",
            json={"chat_id": chat_id, "text": text, "parse_mode": "HTML"},
        )


async def _download_photo(file_id: str) -> bytes | None:
    if not settings.telegram_bot_token:
        return None
    token = settings.telegram_bot_token
    async with httpx.AsyncClient(timeout=60.0) as client:
        meta = await client.get(f"{API_ROOT}/bot{token}/getFile", params={"file_id": file_id})
        meta.raise_for_status()
        path = meta.json()["result"]["file_path"]
        blob = await client.get(f"{API_ROOT}/file/bot{token}/{path}")
        blob.raise_for_status()
        return blob.content


async def _user_for_chat(db: AsyncSession, chat_id: str) -> User | None:
    return (
        await db.execute(select(User).where(User.telegram_chat_id == str(chat_id)))
    ).scalar_one_or_none()


async def _link(db: AsyncSession, chat_id: str, raw_token: str) -> str:
    """Bind a chat to an account using an ingest token."""
    parts = split_api_token(raw_token.strip())
    if not parts:
        return "토큰 형식이 올바르지 않습니다. 앱 설정에서 발급한 sk_… 토큰을 보내주세요."
    prefix, secret = parts
    rows = (
        await db.execute(
            select(ApiToken).where(
                ApiToken.prefix == prefix, ApiToken.revoked_at.is_(None)
            )
        )
    ).scalars().all()
    for row in rows:
        if verify_secret(secret, row.token_hash):
            user = await db.get(User, row.user_id)
            if user is None:
                break
            # A chat maps to exactly one account; re-linking moves it.
            existing = await _user_for_chat(db, chat_id)
            if existing and existing.id != user.id:
                existing.telegram_chat_id = None
            user.telegram_chat_id = str(chat_id)
            row.last_used_at = utcnow()
            await db.flush()
            return f"{user.nickname}님 계정에 연결했습니다. 이제 사진만 보내면 됩니다."
    return "유효하지 않은 토큰입니다."


async def handle_update(db: AsyncSession, update: dict) -> str | None:
    """Process one Telegram update. Returns the reply text (also sent)."""
    message = update.get("message") or update.get("edited_message")
    if not message:
        return None

    chat_id = str(message.get("chat", {}).get("id", ""))
    if not chat_id:
        return None

    text = (message.get("text") or message.get("caption") or "").strip()

    if text.startswith("/link"):
        reply = await _link(db, chat_id, text[5:])
        await send_message(chat_id, reply)
        return reply

    user = await _user_for_chat(db, chat_id)
    if user is None:
        reply = (
            "계정이 연결되어 있지 않습니다.\n"
            "앱 → 더보기 → 토큰 발급 후 <code>/link sk_…</code> 형식으로 보내주세요."
        )
        await send_message(chat_id, reply)
        return reply

    # --- photo ------------------------------------------------------------
    photos = message.get("photo") or []
    if photos:
        # Telegram sends several sizes; the last is the largest.
        blob = await _download_photo(photos[-1]["file_id"])
        if blob is None:
            reply = "사진을 내려받지 못했습니다."
        else:
            reply = await _ingest_photo(db, user, blob, caption=text)
        await send_message(chat_id, reply)
        return reply

    # --- weight -----------------------------------------------------------
    weight_match = _WEIGHT.match(text)
    if weight_match:
        kg = float(weight_match.group(1))
        row = await targets.record_weight(
            db, user, on_date=today_local(user.timezone), raw_kg=kg
        )
        reply = f"체중 {kg}kg 기록했습니다. (추세 {row.trend_kg}kg)"
        await send_message(chat_id, reply)
        return reply

    # --- today ------------------------------------------------------------
    if text in ("/오늘", "/today", "오늘"):
        summary = await reports.day_summary(db, user, today_local(user.timezone))
        remaining = summary.remaining_kcal
        reply = (
            f"오늘 {summary.kcal:.0f}kcal · 단백질 {summary.protein_g:.0f}g · "
            f"{summary.meals}끼"
            + (f"\n남은 kcal {remaining:.0f}" if remaining is not None else "")
        )
        await send_message(chat_id, reply)
        return reply

    if not text:
        return None

    # --- natural edit, else workout --------------------------------------
    last_meal = (
        await db.execute(
            select(Meal)
            .where(Meal.user_id == user.id, Meal.status == MealStatus.READY)
            .order_by(Meal.shot_at.desc())
            .limit(1)
        )
    ).scalar_one_or_none()

    if last_meal is not None:
        result = await apply_natural_edit(db, last_meal, text)
        if result.action != "none":
            await send_message(chat_id, result.message)
            return result.message

    parsed = await workouts.parse_note(db, text=text)
    if parsed.sets:
        workout = await workouts.create_workout(
            db,
            user=user,
            actor_id=user.id,
            parsed=parsed,
            source=EntrySource.VOICE,
        )
        await db.refresh(workout, ["sets"])
        reply = f"운동 {len(workout.sets)}세트 기록했습니다."
        if parsed.unmatched:
            reply += f"\n확인 필요: {', '.join(parsed.unmatched)}"
    else:
        reply = (
            "이해하지 못했습니다.\n"
            "· 사진을 보내면 식사가 기록됩니다\n"
            "· 숫자만 보내면 체중입니다 (예: 72.4)\n"
            "· '밥 150으로' 처럼 마지막 식사를 고칠 수 있습니다\n"
            "· '스쿼트 60에 10개 3세트' 처럼 운동도 됩니다"
        )
    await send_message(chat_id, reply)
    return reply


async def _ingest_photo(
    db: AsyncSession, user: User, blob: bytes, caption: str = ""
) -> str:
    stored = process_upload(blob, user_id=user.id, tz_name=user.timezone, kind="meal")
    when = stored.shot_at
    meal = Meal(
        user_id=user.id,
        canteen_id=None,
        shot_at=when,
        local_date=local_date(when, user.timezone),
        meal_type=infer_meal_type(when, user.timezone),
        photo_path=stored.path,
        status=MealStatus.PENDING,
        source=EntrySource.PHOTO,
        logged_by=user.id,
        note=caption or None,
    )
    db.add(meal)
    await db.flush()
    await enqueue(db, "analyze_meal", {"meal_id": meal.id})
    return "접수했습니다. 분석이 끝나면 알려드릴게요."


def verify_webhook_secret(header_value: str | None) -> None:
    expected = settings.telegram_webhook_secret
    if expected and header_value != expected:
        raise Unauthorized("잘못된 웹훅 시크릿입니다.")
