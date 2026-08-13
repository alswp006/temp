"""Passwordless auth: magic-link code → JWT, plus ingest tokens."""

from __future__ import annotations

import logging
from datetime import timedelta

from fastapi import APIRouter
from sqlalchemy import select

from app.config import settings
from app.core.deps import CurrentUser, DbSession
from app.core.security import (
    create_access_token,
    hash_secret,
    new_api_token,
    new_login_code,
    verify_secret,
)
from app.core.timeutil import utcnow
from app.errors import NotFound, RateLimited, Unauthorized
from app.models import ApiToken, LoginCode, User
from app.services import mailer
from app.schemas import (
    ApiTokenCreate,
    ApiTokenCreated,
    ApiTokenOut,
    LoginRequest,
    LoginRequestResponse,
    LoginVerify,
    Ok,
    TokenResponse,
    UserOut,
    UserUpdate,
)

log = logging.getLogger(__name__)
router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/request-code", response_model=LoginRequestResponse)
async def request_code(payload: LoginRequest, db: DbSession) -> LoginRequestResponse:
    """Issue a one-time code. Creates the account on first request.

    The response is identical whether or not the account exists, so this
    endpoint can't be used to enumerate registered emails.
    """
    email = payload.email.lower()
    user = (
        await db.execute(select(User).where(User.email == email))
    ).scalar_one_or_none()
    if user is None:
        user = User(
            email=email,
            nickname=(payload.nickname or email.split("@")[0])[:40],
        )
        db.add(user)
        await db.flush()

    code = new_login_code()
    db.add(
        LoginCode(
            email=email,
            code_hash=hash_secret(code),
            expires_at=utcnow() + timedelta(minutes=settings.login_code_ttl_minutes),
        )
    )

    sent = await mailer.send(mailer.login_code_mail(email, code))
    if settings.expose_login_code:
        # 개발 환경: 메일 서버 없이도 들어올 수 있게 코드를 돌려줍니다.
        log.info("[dev] login code for %s: %s", mailer.mask_email(email), code)
    elif not sent:
        # 프로덕션에서 메일이 안 나가면 사용자는 들어올 방법이 없습니다.
        # 요청 자체는 성공으로 두되(코드는 이미 저장됐고 재시도가 가능해야
        # 합니다) 로그에는 크게 남깁니다.
        log.error(
            "로그인 코드를 보내지 못했습니다 (%s). SMTP 설정을 확인하세요.",
            mailer.mask_email(email),
        )

    return LoginRequestResponse(
        sent=sent or settings.expose_login_code,
        dev_code=code if settings.expose_login_code else None,
    )


@router.post("/verify", response_model=TokenResponse)
async def verify(payload: LoginVerify, db: DbSession) -> TokenResponse:
    email = payload.email.lower()
    record = (
        await db.execute(
            select(LoginCode)
            .where(LoginCode.email == email, LoginCode.consumed_at.is_(None))
            .order_by(LoginCode.created_at.desc())
            .limit(1)
        )
    ).scalar_one_or_none()

    if record is None or record.expires_at < utcnow():
        raise Unauthorized("코드가 만료되었거나 존재하지 않습니다.")
    if record.attempts >= settings.login_code_max_attempts:
        raise RateLimited("시도 횟수를 초과했습니다. 코드를 다시 요청해 주세요.")

    record.attempts += 1
    if not verify_secret(payload.code, record.code_hash):
        raise Unauthorized("코드가 일치하지 않습니다.")

    record.consumed_at = utcnow()
    user = (
        await db.execute(select(User).where(User.email == email))
    ).scalar_one_or_none()
    if user is None:
        raise NotFound("사용자를 찾을 수 없습니다.")

    return TokenResponse(
        access_token=create_access_token(user.id), user=UserOut.model_validate(user)
    )


@router.get("/me", response_model=UserOut)
async def me(user: CurrentUser) -> UserOut:
    return UserOut.model_validate(user)


@router.patch("/me", response_model=UserOut)
async def update_me(payload: UserUpdate, user: CurrentUser, db: DbSession) -> UserOut:
    for field, value in payload.model_dump(exclude_unset=True).items():
        if value is not None:
            setattr(user, field, value)
    await db.flush()
    return UserOut.model_validate(user)


# --- ingest tokens --------------------------------------------------------


@router.post("/tokens", response_model=ApiTokenCreated, status_code=201)
async def create_token(
    payload: ApiTokenCreate, user: CurrentUser, db: DbSession
) -> ApiTokenCreated:
    """Mint a token for the iOS Shortcut / Telegram bridge.

    The secret is returned once and stored only as an argon2 hash.
    """
    full, prefix, token_hash = new_api_token()
    row = ApiToken(
        user_id=user.id, name=payload.name, prefix=prefix, token_hash=token_hash
    )
    db.add(row)
    await db.flush()
    return ApiTokenCreated(token=full, info=ApiTokenOut.model_validate(row))


@router.get("/tokens", response_model=list[ApiTokenOut])
async def list_tokens(user: CurrentUser, db: DbSession) -> list[ApiTokenOut]:
    rows = (
        await db.execute(
            select(ApiToken)
            .where(ApiToken.user_id == user.id, ApiToken.revoked_at.is_(None))
            .order_by(ApiToken.created_at.desc())
        )
    ).scalars().all()
    return [ApiTokenOut.model_validate(r) for r in rows]


@router.delete("/tokens/{token_id}", response_model=Ok)
async def revoke_token(token_id: int, user: CurrentUser, db: DbSession) -> Ok:
    row = await db.get(ApiToken, token_id)
    if row is None or row.user_id != user.id:
        raise NotFound("토큰을 찾을 수 없습니다.")
    row.revoked_at = utcnow()
    return Ok()
