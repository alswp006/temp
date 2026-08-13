"""푸시 알림.

여기까지 오기 전에는 알림이 DB 행일 뿐이라, 코치가 코멘트를 남겨도 멘티가
앱을 열어야만 알 수 있었습니다.

## 설계에서 지킨 것

**푸시는 잡 큐를 통해 나갑니다.** 요청 경로에서 FCM을 부르면, 구글이 느린 날
사용자의 저장 버튼도 같이 느려집니다. 알림 행은 즉시 커밋되고 전송은 워커가
맡습니다.

**끄는 것이 기본입니다.** 자격증명이 없으면 `noop`으로 조용히 돕니다. 알림은
여전히 쌓이고 앱을 열면 보입니다 — 푸시가 없다고 기능이 사라지지 않습니다.

**하루 2회를 넘기지 않습니다.** 로드맵의 "만들지 않을 것"에 명시된 제약이고,
독촉으로 기록을 왜곡시키지 않겠다는 제품 결정입니다. 여기서 강제합니다.

## FCM을 고른 이유

iOS(APNs 경유)와 안드로이드를 한 경로로 처리합니다. HTTP v1은 OAuth2를
요구하는데, 서비스 계정 JSON으로 JWT를 만들어 토큰을 받는 것뿐이라 PyJWT와
httpx만으로 됩니다 — google-auth를 새로 넣지 않았습니다.
"""

from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass
from datetime import timedelta

import httpx
import jwt
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.core.timeutil import utcnow
from app.models import DeviceToken, Notification

log = logging.getLogger(__name__)

_SCOPE = "https://www.googleapis.com/auth/firebase.messaging"
_TOKEN_URL = "https://oauth2.googleapis.com/token"

# 하루에 이보다 많이 보내지 않습니다.
MAX_PUSH_PER_DAY = 2


@dataclass(slots=True)
class PushMessage:
    token: str
    title: str
    body: str | None
    data: dict[str, str]


class PushProvider:
    name = "noop"

    async def send(self, message: PushMessage) -> bool:
        """보냈으면 True. 토큰이 죽었으면 :class:`DeadToken`을 던집니다."""
        log.info("[푸시 미설정] %s: %s", message.token[:12], message.title)
        return False

    async def aclose(self) -> None:
        return None


class DeadToken(Exception):
    """FCM이 이 토큰은 더 이상 유효하지 않다고 답했습니다."""


class FcmProvider(PushProvider):
    name = "fcm"

    def __init__(self) -> None:
        if not settings.fcm_credentials_file:
            raise RuntimeError("FCM_CREDENTIALS_FILE이 없습니다.")
        creds = json.loads(settings.fcm_credentials_file.read_text(encoding="utf-8"))
        self._client_email = creds["client_email"]
        self._private_key = creds["private_key"]
        self._project_id = settings.fcm_project_id or creds["project_id"]
        self._http = httpx.AsyncClient(timeout=settings.push_timeout_seconds)
        self._access_token: str | None = None
        self._expires_at: float = 0.0

    async def _token(self) -> str:
        # 액세스 토큰은 1시간짜리입니다. 매 발송마다 새로 받으면 알림 한 건에
        # 왕복이 두 번이 됩니다.
        now = time.time()
        if self._access_token and now < self._expires_at - 60:
            return self._access_token

        assertion = jwt.encode(
            {
                "iss": self._client_email,
                "scope": _SCOPE,
                "aud": _TOKEN_URL,
                "iat": int(now),
                "exp": int(now + 3600),
            },
            self._private_key,
            algorithm="RS256",
        )
        res = await self._http.post(
            _TOKEN_URL,
            data={
                "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                "assertion": assertion,
            },
        )
        res.raise_for_status()
        payload = res.json()
        self._access_token = payload["access_token"]
        self._expires_at = now + float(payload.get("expires_in", 3600))
        return self._access_token

    async def send(self, message: PushMessage) -> bool:
        token = await self._token()
        url = (
            f"https://fcm.googleapis.com/v1/projects/{self._project_id}"
            "/messages:send"
        )
        res = await self._http.post(
            url,
            headers={"Authorization": f"Bearer {token}"},
            json={
                "message": {
                    "token": message.token,
                    "notification": {
                        "title": message.title,
                        "body": message.body or "",
                    },
                    "data": message.data,
                    # iOS에서 알림음과 배지를 쓰려면 apns 블록이 필요합니다.
                    "apns": {
                        "payload": {"aps": {"sound": "default"}},
                    },
                    "android": {"priority": "high"},
                }
            },
        )
        if res.status_code == 404 or (
            res.status_code == 400 and "INVALID_ARGUMENT" in res.text
        ):
            # 앱을 지웠거나 토큰이 갈렸습니다. 계속 재시도하면 큐가 막힙니다.
            raise DeadToken(res.text[:200])
        res.raise_for_status()
        return True

    async def aclose(self) -> None:
        await self._http.aclose()


_provider: PushProvider | None = None


def get_provider() -> PushProvider:
    global _provider
    if _provider is None:
        try:
            _provider = (
                FcmProvider() if settings.push_provider == "fcm" else PushProvider()
            )
        except Exception as exc:  # noqa: BLE001
            # 자격증명이 잘못됐다고 서버가 죽으면 안 됩니다.
            log.warning("푸시 프로바이더 초기화 실패, 비활성화합니다: %s", exc)
            _provider = PushProvider()
        log.info("push provider = %s", _provider.name)
    return _provider


def set_provider(provider: PushProvider | None) -> None:
    """테스트에서 가짜를 끼웁니다."""
    global _provider
    _provider = provider


async def close_provider() -> None:
    global _provider
    if _provider is not None:
        await _provider.aclose()
        _provider = None


# --------------------------------------------------------------------------
# 발송
# --------------------------------------------------------------------------


async def _sent_today(db: AsyncSession, user_id: int) -> int:
    since = utcnow() - timedelta(days=1)
    rows = (
        await db.execute(
            select(Notification).where(
                Notification.user_id == user_id,
                Notification.created_at >= since,
                Notification.pushed_at.is_not(None),
            )
        )
    ).scalars().all()
    return len(rows)


async def deliver(db: AsyncSession, notification_id: int) -> int:
    """알림 하나를 그 사용자의 모든 기기로. 보낸 기기 수를 돌려줍니다."""
    notification = await db.get(Notification, notification_id)
    if notification is None or notification.pushed_at is not None:
        return 0

    if await _sent_today(db, notification.user_id) >= MAX_PUSH_PER_DAY:
        # 하루 2회 상한. 알림 자체는 남으므로 앱을 열면 보입니다.
        log.info(
            "푸시 상한(하루 %d회)에 걸려 보내지 않습니다: user=%s",
            MAX_PUSH_PER_DAY,
            notification.user_id,
        )
        notification.pushed_at = utcnow()
        return 0

    devices = (
        await db.execute(
            select(DeviceToken).where(
                DeviceToken.user_id == notification.user_id,
                DeviceToken.revoked_at.is_(None),
            )
        )
    ).scalars().all()
    if not devices:
        notification.pushed_at = utcnow()
        return 0

    provider = get_provider()
    sent = 0
    for device in devices:
        message = PushMessage(
            token=device.token,
            title=notification.title,
            body=notification.body,
            # FCM data는 값이 전부 문자열이어야 합니다.
            data={
                "kind": notification.kind,
                "notification_id": str(notification.id),
                **{k: str(v) for k, v in (notification.payload or {}).items()},
            },
        )
        try:
            if await provider.send(message):
                sent += 1
        except DeadToken:
            device.revoked_at = utcnow()
            log.info("죽은 토큰을 정리합니다: device=%s", device.id)
        except Exception as exc:  # noqa: BLE001
            # 한 기기가 실패해도 나머지 기기에는 보냅니다.
            log.warning("푸시 실패 (device=%s): %s", device.id, exc)

    notification.pushed_at = utcnow()
    return sent
