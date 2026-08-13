"""메일 발송.

이 모듈이 없으면 실제 사용자가 로그인할 수 없으므로, 여기서 검증하는 것은
"메일이 예쁘게 나가는가"가 아니라 **"메일이 실패해도 로그인 요청이 살아남는가"**
입니다.
"""

from __future__ import annotations

import pytest

from app.config import settings
from app.services import mailer


def test_주소를_통째로_로그에_남기지_않는다():
    assert mailer.mask_email("someone@example.com") == "so***@example.com"
    assert mailer.mask_email("a@example.com") == "a***@example.com"
    # 형식이 아닌 값이 들어와도 원문을 흘리지 않습니다.
    assert mailer.mask_email("not-an-email") == "***"


def test_설정이_없으면_보내지_않는다(monkeypatch):
    monkeypatch.setattr(settings, "smtp_host", None)
    assert mailer.is_configured() is False


def test_로그인_코드_메일에_코드와_유효시간이_들어간다():
    mail = mailer.login_code_mail("me@example.com", "123456")
    assert "123456" in mail.text
    assert "123456" in (mail.html or "")
    assert "123456" in mail.subject
    assert str(settings.login_code_ttl_minutes) in mail.text
    # 본인이 요청하지 않은 사람에게 불안을 주지 않는 문구가 있어야 합니다.
    assert "무시" in mail.text


def test_메일_본문이_정상적인_MIME으로_조립된다(monkeypatch):
    monkeypatch.setattr(settings, "mail_from", "식판 <no-reply@sikpan.app>")
    msg = mailer._build(mailer.login_code_mail("me@example.com", "999999"))
    assert msg["To"] == "me@example.com"
    assert "no-reply@sikpan.app" in msg["From"]
    # 텍스트 대체본이 있어야 스팸 점수가 내려가고, 텍스트 전용 클라이언트에서도
    # 코드를 읽을 수 있습니다.
    assert msg.is_multipart()
    subtypes = {part.get_content_subtype() for part in msg.walk()}
    assert {"plain", "html"} <= subtypes


@pytest.mark.asyncio
async def test_SMTP가_죽어도_예외를_던지지_않는다(monkeypatch):
    """로그인 요청이 메일 서버 사정으로 실패하면 안 됩니다."""
    monkeypatch.setattr(settings, "smtp_host", "smtp.invalid")

    def boom(msg):
        raise OSError("연결 거부")

    monkeypatch.setattr(mailer, "_send_blocking", boom)
    sent = await mailer.send(mailer.login_code_mail("me@example.com", "111111"))
    assert sent is False


@pytest.mark.asyncio
async def test_설정이_있으면_실제로_전송을_시도한다(monkeypatch):
    monkeypatch.setattr(settings, "smtp_host", "smtp.example.com")
    captured = {}

    def fake(msg):
        captured["to"] = msg["To"]
        captured["subject"] = msg["Subject"]

    monkeypatch.setattr(mailer, "_send_blocking", fake)
    sent = await mailer.send(mailer.login_code_mail("me@example.com", "222222"))
    assert sent is True
    assert captured["to"] == "me@example.com"
    assert "222222" in captured["subject"]


@pytest.mark.asyncio
async def test_메일이_실패해도_로그인_코드_요청은_200이다(client, monkeypatch):
    """프로덕션에서 SMTP가 죽었을 때의 동작.

    코드는 이미 DB에 저장되어 있고, 사용자는 다시 시도할 수 있어야 합니다.
    여기서 500을 내면 사용자는 들어올 방법 자체를 잃습니다.
    """
    monkeypatch.setattr(settings, "expose_login_code", False)
    monkeypatch.setattr(settings, "smtp_host", "smtp.invalid")

    async def fail(mail):
        return False

    monkeypatch.setattr(mailer, "send", fail)

    r = await client.post(
        "/api/auth/request-code", json={"email": "down@example.com"}
    )
    assert r.status_code == 200
    body = r.json()
    # 프로덕션에서는 코드를 응답에 실어 보내지 않습니다.
    assert body["dev_code"] is None
    assert body["sent"] is False


@pytest.mark.asyncio
async def test_프로덕션에서는_코드를_응답에_넣지_않는다(client, monkeypatch):
    monkeypatch.setattr(settings, "expose_login_code", False)

    async def ok(mail):
        return True

    monkeypatch.setattr(mailer, "send", ok)

    r = await client.post(
        "/api/auth/request-code", json={"email": "prod@example.com"}
    )
    assert r.status_code == 200
    assert r.json()["dev_code"] is None
    assert r.json()["sent"] is True
