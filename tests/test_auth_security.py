"""로그인 경로의 보안 계약.

여기 있는 것들은 전부 "조용히 안전하지 않았던" 것들이라, 회귀하면 아무도
눈치채지 못합니다. 그래서 테스트로 못 박습니다.
"""

import os

import pytest
from httpx import AsyncClient
from sqlalchemy import select

from app.config import Settings
from app.models import LoginCode


@pytest.mark.asyncio
async def test_틀린_코드는_시도_횟수를_소진한다(client: AsyncClient, db):
    """실패 응답이 예외로 나가면서 세션이 롤백돼, 시도 횟수 증가분이 함께
    사라지고 있었다. 그래서 6자리 코드를 무제한으로 대입할 수 있었다."""
    email = "brute@example.com"
    r = await client.post("/api/auth/request-code", json={"email": email})
    assert r.status_code == 200
    real_code = r.json()["dev_code"]

    for i in range(5):
        r = await client.post(
            "/api/auth/verify", json={"email": email, "code": "000000"}
        )
        assert r.status_code == 401, f"{i}번째 시도"

    # 여섯 번째부터는 막힌다 — 맞는 코드를 넣어도.
    r = await client.post(
        "/api/auth/verify", json={"email": email, "code": real_code}
    )
    assert r.status_code == 429, r.text

    record = (
        await db.execute(
            select(LoginCode).where(LoginCode.email == email)
        )
    ).scalars().first()
    assert record.attempts >= 5, "시도 횟수가 저장되지 않았다"


@pytest.mark.asyncio
async def test_맞는_코드는_한도_안에서_통과한다(client: AsyncClient):
    """시도 횟수를 세는 것이 정상 로그인을 막으면 안 된다."""
    email = "ok@example.com"
    r = await client.post("/api/auth/request-code", json={"email": email})
    code = r.json()["dev_code"]

    for _ in range(3):
        await client.post(
            "/api/auth/verify", json={"email": email, "code": "000000"}
        )

    r = await client.post("/api/auth/verify", json={"email": email, "code": code})
    assert r.status_code == 200, r.text


def test_프로덕션은_로그인_코드_노출을_거부한다():
    """기본값이 True였기 때문에, compose를 안 쓰고 uvicorn으로 직접 띄운
    배포는 OTP를 응답에 그대로 실어 보내고 있었다."""
    with pytest.raises(ValueError, match="EXPOSE_LOGIN_CODE"):
        Settings(env="prod", expose_login_code=True, secret_key="x")


def test_프로덕션은_고정되지_않은_비밀키를_거부한다(monkeypatch):
    """기본 secret_key는 프로세스마다 새로 만들어진다. 재시작하면 전원
    로그아웃되고, 워커를 여러 개 띄우면 워커마다 키가 달라 무작위 401이 난다."""
    monkeypatch.delenv("SECRET_KEY", raising=False)
    with pytest.raises(ValueError, match="SECRET_KEY"):
        Settings(env="prod", expose_login_code=False)


def test_프로덕션도_비밀키를_고정하면_뜬다(monkeypatch):
    monkeypatch.setenv("SECRET_KEY", "fixed-key-from-env")
    s = Settings(env="prod", expose_login_code=False)
    assert s.expose_login_code is False


def test_개발_기본값은_코드를_응답에_싣지_않는다(monkeypatch):
    monkeypatch.delenv("EXPOSE_LOGIN_CODE", raising=False)
    assert Settings(env="dev").expose_login_code is False


@pytest.mark.asyncio
async def test_없는_식당으로_올리면_거절한다(client: AsyncClient, photo_bytes):
    """앱은 고른 식당 id를 기기에 저장한다. 그 식당이 사라지면 서버는 403을
    내는데, 앱에는 그 선택을 지울 방법이 없어 사진 업로드가 영구히 실패했다.
    서버 쪽 계약을 고정해 두고, 클라이언트는 이 403을 보고 선택을 버린다."""
    from tests.conftest import register

    auth = await register(client, "canteen@example.com")
    r = await client.post(
        "/api/meals/photo",
        headers=auth["headers"],
        files={"file": ("tray.jpg", photo_bytes, "image/jpeg")},
        data={"canteen_id": "99999"},
    )
    assert r.status_code == 403, r.text

    # 식당 없이 보내면 통과해야 한다 — 식당은 정확도 장치이지 기록의 전제가
    # 아니다. 클라이언트의 자가 복구가 이 경로로 재시도한다.
    r = await client.post(
        "/api/meals/photo",
        headers=auth["headers"],
        files={"file": ("tray.jpg", photo_bytes, "image/jpeg")},
    )
    assert r.status_code == 202, r.text
