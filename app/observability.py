"""크래시 리포팅.

이게 없으면 실기기에서 뭐가 깨지는지 알 방법이 없습니다. 사용자는 대개
버그를 신고하지 않고 그냥 앱을 지웁니다.

## 이 앱에서 특별히 조심할 것

건강 데이터를 다루므로 **기본값이 "안 보낸다"** 입니다.

* `send_default_pii`는 기본이 False — 헤더·쿠키·본문이 통째로 올라가지
  않습니다.
* 그래도 새는 것들이 있어서 :func:`_scrub`으로 한 번 더 거릅니다. 이메일
  주소, 인증 토큰, 사진 경로가 대상입니다. 사진 경로는 그 자체로 파일을
  가리키지는 않지만(미디어 라우트가 권한을 봅니다) 로그에 남길 이유가 없습니다.
* DSN이 없으면 통째로 비활성이고 sentry-sdk를 import조차 하지 않습니다.
"""

from __future__ import annotations

import logging
import re
from typing import Any

from app.config import settings

log = logging.getLogger(__name__)

_enabled = False

# 값이 통째로 실려도 곤란한 키들. 대소문자 무시.
_SECRET_KEYS = re.compile(
    r"authorization|cookie|token|password|secret|api[_-]?key|dsn",
    re.I,
)
_EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+")


def _mask_emails(text: str) -> str:
    return _EMAIL.sub(lambda m: _mask_one(m.group()), text)


def _mask_one(address: str) -> str:
    local, _, domain = address.partition("@")
    head = local[:2] if len(local) > 2 else local[:1]
    return f"{head}***@{domain}"


def _scrub(value: Any, depth: int = 0) -> Any:
    """이벤트에서 개인정보를 지웁니다.

    깊이를 제한하는 이유: 센트리 이벤트는 스택 프레임마다 지역변수를 담아
    상당히 깊어질 수 있고, 여기서 무한히 파고들면 예외 처리 경로가 느려집니다.
    """
    if depth > 6:
        return value
    if isinstance(value, dict):
        out = {}
        for k, v in value.items():
            if isinstance(k, str) and _SECRET_KEYS.search(k):
                out[k] = "[제거됨]"
            else:
                out[k] = _scrub(v, depth + 1)
        return out
    if isinstance(value, list):
        return [_scrub(v, depth + 1) for v in value]
    if isinstance(value, str):
        return _mask_emails(value)
    return value


def _before_send(event: dict, hint: dict) -> dict | None:
    try:
        return _scrub(event)
    except Exception:  # noqa: BLE001 - 스크러빙 실패로 이벤트를 잃지 않는다
        # 지우지 못했으면 보내지 않습니다. 새는 것보다 잃는 게 낫습니다.
        return None


def init() -> bool:
    """설정되어 있으면 켭니다. 켰으면 True."""
    global _enabled
    if not settings.sentry_dsn:
        log.info("크래시 리포팅 비활성 (SENTRY_DSN 없음)")
        return False

    try:
        import sentry_sdk
    except ImportError:
        log.warning(
            "SENTRY_DSN이 있는데 sentry-sdk가 없습니다. "
            'pip install -e ".[sentry]" 를 하세요.'
        )
        return False

    sentry_sdk.init(
        dsn=settings.sentry_dsn,
        environment=settings.env,
        release=f"sikpan@{settings.release}",
        traces_sample_rate=settings.sentry_traces_sample_rate,
        send_default_pii=settings.sentry_send_default_pii,
        before_send=_before_send,
    )
    _enabled = True
    log.info("크래시 리포팅 활성 (env=%s)", settings.env)
    return True


def capture(exc: BaseException, **context: Any) -> None:
    """예외 하나를 보냅니다. 비활성이면 로그로만 남습니다."""
    if not _enabled:
        log.error("처리되지 않은 예외: %s (%s)", exc, context, exc_info=exc)
        return
    import sentry_sdk

    with sentry_sdk.new_scope() as scope:
        for key, value in context.items():
            scope.set_tag(key, str(value))
        sentry_sdk.capture_exception(exc)


def set_user(user_id: int | None) -> None:
    """누구에게 일어난 일인지만 남깁니다 — 아이디만, 이메일은 아닙니다."""
    if not _enabled:
        return
    import sentry_sdk

    sentry_sdk.set_user({"id": str(user_id)} if user_id else None)
