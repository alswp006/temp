"""FastAPI dependencies."""

from __future__ import annotations

from typing import Annotated

from fastapi import Depends, Header
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.security import decode_access_token, split_api_token, verify_secret
from app.core.timeutil import utcnow
from app.db import get_session
from app.errors import Unauthorized
from app.models import ApiToken, User

DbSession = Annotated[AsyncSession, Depends(get_session)]


async def _user_from_api_token(db: AsyncSession, token: str) -> User | None:
    parts = split_api_token(token)
    if not parts:
        return None
    prefix, secret = parts
    rows = (
        await db.execute(
            select(ApiToken).where(ApiToken.prefix == prefix, ApiToken.revoked_at.is_(None))
        )
    ).scalars().all()
    for row in rows:
        if verify_secret(secret, row.token_hash):
            row.last_used_at = utcnow()
            return await db.get(User, row.user_id)
    return None


async def current_user(
    db: DbSession,
    authorization: Annotated[str | None, Header()] = None,
) -> User:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise Unauthorized("인증이 필요합니다.")
    token = authorization[7:].strip()

    user = (
        await _user_from_api_token(db, token)
        if token.startswith("sk_")
        else await db.get(User, decode_access_token(token))
    )
    if user is None or not user.is_active:
        raise Unauthorized("사용자를 찾을 수 없습니다.")
    return user


CurrentUser = Annotated[User, Depends(current_user)]
