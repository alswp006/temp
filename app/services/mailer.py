"""메일 발송.

이 모듈이 없으면 이 앱에는 실제 사용자가 존재할 수 없습니다. 로그인 코드가
서버 로그에만 찍히므로, 서버를 돌리는 사람 말고는 아무도 들어올 수 없습니다.

설계에서 지킨 것 두 가지:

1. **발송 실패가 로그인 요청을 실패시키지 않습니다.** SMTP는 흔하게 느리고
   흔하게 죽습니다. 코드는 이미 DB에 저장되었으므로, 메일이 못 나갔다고
   요청을 500으로 만들면 사용자는 다시 시도할 방법조차 잃습니다. 대신 로그에
   크게 남기고, 개발 모드에서는 코드를 응답에 실어 보냅니다.

2. **주소를 로그에 통째로 남기지 않습니다.** 이메일은 개인정보이고 로그는
   오래 삽니다. `ab***@example.com` 형태로만 적습니다.
"""

from __future__ import annotations

import asyncio
import logging
import smtplib
import ssl
from dataclasses import dataclass
from email.message import EmailMessage
from email.utils import formataddr, parseaddr

from app.config import settings

log = logging.getLogger(__name__)


def mask_email(address: str) -> str:
    """`someone@example.com` → `so***@example.com`"""
    local, _, domain = address.partition("@")
    if not domain:
        return "***"
    head = local[:2] if len(local) > 2 else local[:1]
    return f"{head}***@{domain}"


@dataclass(slots=True)
class Mail:
    to: str
    subject: str
    text: str
    html: str | None = None


class MailNotConfigured(RuntimeError):
    """SMTP 설정이 없습니다. 개발 환경의 정상 상태이기도 합니다."""


def is_configured() -> bool:
    return bool(settings.smtp_host)


def _build(mail: Mail) -> EmailMessage:
    msg = EmailMessage()
    name, addr = parseaddr(settings.mail_from)
    msg["From"] = formataddr((name, addr)) if name else addr
    msg["To"] = mail.to
    msg["Subject"] = mail.subject
    msg.set_content(mail.text)
    if mail.html:
        msg.add_alternative(mail.html, subtype="html")
    return msg


def _send_blocking(msg: EmailMessage) -> None:
    """동기 smtplib. 호출부에서 스레드로 넘깁니다.

    aiosmtplib을 쓰지 않은 이유는 의존성을 하나 덜기 위해서입니다. 로그인
    코드 발송은 초당 수천 건이 아니라 사람 손에 묶인 빈도라, 스레드 하나면
    충분합니다.
    """
    context = ssl.create_default_context()
    if settings.smtp_ssl:
        server: smtplib.SMTP = smtplib.SMTP_SSL(
            settings.smtp_host,
            settings.smtp_port,
            timeout=settings.mail_timeout_seconds,
            context=context,
        )
    else:
        server = smtplib.SMTP(
            settings.smtp_host,
            settings.smtp_port,
            timeout=settings.mail_timeout_seconds,
        )
    with server:
        server.ehlo()
        if settings.smtp_starttls and not settings.smtp_ssl:
            server.starttls(context=context)
            server.ehlo()
        if settings.smtp_user:
            server.login(settings.smtp_user, settings.smtp_password or "")
        server.send_message(msg)


async def send(mail: Mail) -> bool:
    """메일 한 통. 보냈으면 True.

    예외를 밖으로 던지지 않습니다 — 호출부(로그인 요청)가 메일 서버 사정으로
    실패해서는 안 됩니다.
    """
    if not is_configured():
        log.info(
            "[메일 미설정] %s 앞으로 보내지 않음: %s",
            mask_email(mail.to),
            mail.subject,
        )
        return False

    msg = _build(mail)
    try:
        # 표준 라이브러리만 씁니다. anyio는 starlette를 통해 들어오는
        # 전이 의존이라, 직접 import하면 email-validator 때와 같은 종류의
        # "깨끗한 환경에서만 터지는" 버그가 됩니다.
        await asyncio.to_thread(_send_blocking, msg)
    except Exception as exc:  # noqa: BLE001 - 어떤 SMTP 오류도 삼킨다
        log.error(
            "메일 발송 실패 (%s → %s): %s",
            settings.smtp_host,
            mask_email(mail.to),
            exc,
        )
        return False

    log.info("메일 발송: %s → %s", mail.subject, mask_email(mail.to))
    return True


# --------------------------------------------------------------------------
# 템플릿
# --------------------------------------------------------------------------


def login_code_mail(to: str, code: str) -> Mail:
    minutes = settings.login_code_ttl_minutes
    text = (
        f"식판 로그인 코드: {code}\n\n"
        f"{minutes}분 안에 앱에 입력해 주세요.\n"
        "본인이 요청하지 않았다면 이 메일은 무시하셔도 됩니다. "
        "코드만으로는 아무 일도 일어나지 않습니다.\n"
    )
    # 코드를 크게, 그 외엔 최소한으로. 메일 클라이언트마다 CSS 지원이 달라
    # 인라인 스타일과 테이블만 씁니다.
    html = f"""\
<div style="font-family:-apple-system,'Apple SD Gothic Neo','Malgun Gothic',sans-serif;
            max-width:420px;margin:0 auto;padding:32px 24px;color:#1c1e22">
  <div style="font-size:15px;color:#5b6068;margin-bottom:24px">식판 로그인</div>
  <div style="font-size:38px;font-weight:700;letter-spacing:8px;
              background:#f0ede6;border-radius:14px;padding:20px;text-align:center">
    {code}
  </div>
  <p style="font-size:14px;color:#5b6068;line-height:1.6;margin-top:24px">
    {minutes}분 안에 앱에 입력해 주세요.
  </p>
  <p style="font-size:12px;color:#8b9098;line-height:1.6">
    본인이 요청하지 않았다면 이 메일은 무시하셔도 됩니다.
    코드만으로는 아무 일도 일어나지 않습니다.
  </p>
</div>"""
    return Mail(to=to, subject=f"식판 로그인 코드 {code}", text=text, html=html)
