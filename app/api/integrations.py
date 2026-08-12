"""Inbound webhooks."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Header, Request

from app.core.deps import DbSession
from app.integrations import telegram

router = APIRouter(prefix="/integrations", tags=["integrations"])


@router.post("/telegram/webhook")
async def telegram_webhook(
    request: Request,
    db: DbSession,
    x_telegram_bot_api_secret_token: Annotated[str | None, Header()] = None,
) -> dict:
    telegram.verify_webhook_secret(x_telegram_bot_api_secret_token)
    update = await request.json()
    reply = await telegram.handle_update(db, update)
    # Telegram retries on a non-2xx, so always ack; the reply already went out
    # over sendMessage.
    return {"ok": True, "reply": reply}
