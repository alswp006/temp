"""Auth primitives: magic-link codes, JWT access tokens, ingest API tokens.

There are no passwords. Two credential types exist:

* **Access tokens** (JWT, short-ish lived) — issued after a magic-link code is
  verified. Used by the PWA.
* **API tokens** (``sk_<prefix>_<secret>``) — long-lived, hashed at rest, used
  by the iOS Shortcut and the Telegram bridge, which cannot run a login flow.
"""

from __future__ import annotations

import hmac
import secrets
from datetime import timedelta
from typing import Any

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError

from app.config import settings
from app.core.timeutil import utcnow
from app.errors import Unauthorized

_hasher = PasswordHasher(time_cost=2, memory_cost=64 * 1024, parallelism=2)

ALGORITHM = "HS256"
TOKEN_PREFIX_LEN = 8


# --- hashing --------------------------------------------------------------


def hash_secret(raw: str) -> str:
    return _hasher.hash(raw)


def verify_secret(raw: str, hashed: str) -> bool:
    try:
        return _hasher.verify(hashed, raw)
    except (VerifyMismatchError, Exception):  # noqa: BLE001 - any failure is a mismatch
        return False


# --- magic-link codes -----------------------------------------------------


def new_login_code() -> str:
    """6 digits. Short enough to type from a phone, rate-limited on verify."""
    return f"{secrets.randbelow(1_000_000):06d}"


def codes_equal(a: str, b: str) -> bool:
    return hmac.compare_digest(a, b)


# --- JWT ------------------------------------------------------------------


def create_access_token(user_id: int, *, extra: dict[str, Any] | None = None) -> str:
    now = utcnow()
    payload: dict[str, Any] = {
        "sub": str(user_id),
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(minutes=settings.access_token_ttl_minutes)).timestamp()),
        "typ": "access",
    }
    if extra:
        payload.update(extra)
    return jwt.encode(payload, settings.secret_key, algorithm=ALGORITHM)


def decode_access_token(token: str) -> int:
    try:
        payload = jwt.decode(token, settings.secret_key, algorithms=[ALGORITHM])
    except jwt.ExpiredSignatureError as exc:
        raise Unauthorized("토큰이 만료되었습니다. 다시 로그인해 주세요.") from exc
    except jwt.PyJWTError as exc:
        raise Unauthorized("유효하지 않은 토큰입니다.") from exc
    if payload.get("typ") != "access":
        raise Unauthorized("유효하지 않은 토큰입니다.")
    try:
        return int(payload["sub"])
    except (KeyError, TypeError, ValueError) as exc:
        raise Unauthorized("유효하지 않은 토큰입니다.") from exc


# --- ingest API tokens ----------------------------------------------------


def new_api_token() -> tuple[str, str, str]:
    """Return ``(full_token, prefix, hash)``. The full token is shown once."""
    prefix = secrets.token_hex(TOKEN_PREFIX_LEN // 2)
    secret = secrets.token_urlsafe(32)
    full = f"sk_{prefix}_{secret}"
    return full, prefix, hash_secret(secret)


def split_api_token(token: str) -> tuple[str, str] | None:
    """``sk_<prefix>_<secret>`` → ``(prefix, secret)``; ``None`` if malformed."""
    if not token.startswith("sk_"):
        return None
    parts = token.split("_", 2)
    if len(parts) != 3 or not parts[1] or not parts[2]:
        return None
    return parts[1], parts[2]


# --- misc -----------------------------------------------------------------


def join_code(length: int = 8) -> str:
    """Human-shareable code. Excludes visually ambiguous characters."""
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    return "".join(secrets.choice(alphabet) for _ in range(length))
