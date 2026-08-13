"""크래시 리포팅.

여기서 검증하는 것은 "오류가 전송되는가"가 아니라 **"전송될 때 무엇이 같이
따라가지 않는가"** 입니다. 건강 데이터를 다루는 앱에서 크래시 리포터는
개인정보가 새는 가장 흔한 경로입니다.
"""

from __future__ import annotations

from app import observability
from app.config import settings


def test_이메일을_마스킹한다():
    event = {"message": "someone@example.com 처리 중 실패"}
    scrubbed = observability._scrub(event)
    assert "someone@example.com" not in scrubbed["message"]
    assert "so***@example.com" in scrubbed["message"]


def test_중첩된_곳의_이메일도_지운다():
    event = {
        "extra": {"users": [{"note": "a@b.com에게 전송"}]},
        "breadcrumbs": [{"message": "login: verylong@corp.co.kr"}],
    }
    scrubbed = observability._scrub(event)
    assert "a@b.com" not in str(scrubbed)
    assert "verylong@corp.co.kr" not in str(scrubbed)


def test_비밀_키는_값을_통째로_지운다():
    event = {
        "request": {
            "headers": {
                "Authorization": "Bearer sk-live-verysecret",
                "Cookie": "session=abc",
                "User-Agent": "Sikpan/0.1",
            }
        },
        "extra": {"anthropic_api_key": "sk-ant-xxx", "SECRET_KEY": "hunter2"},
    }
    scrubbed = observability._scrub(event)
    headers = scrubbed["request"]["headers"]
    assert headers["Authorization"] == "[제거됨]"
    assert headers["Cookie"] == "[제거됨]"
    # 비밀이 아닌 것은 남깁니다 — 다 지우면 디버깅이 불가능해집니다.
    assert headers["User-Agent"] == "Sikpan/0.1"
    assert scrubbed["extra"]["anthropic_api_key"] == "[제거됨]"
    assert scrubbed["extra"]["SECRET_KEY"] == "[제거됨]"


def test_깊이가_깊어도_멈춘다():
    """예외 처리 경로가 느려지면 안 됩니다."""
    deep: dict = {"v": "a@b.com"}
    for _ in range(40):
        deep = {"nested": deep}
    # 터지지 않고 끝나기만 하면 됩니다.
    observability._scrub(deep)


def test_스크러빙이_실패하면_이벤트를_버린다(monkeypatch):
    """새는 것보다 잃는 게 낫습니다."""

    def boom(value, depth=0):
        raise RuntimeError("스크러빙 실패")

    monkeypatch.setattr(observability, "_scrub", boom)
    assert observability._before_send({"message": "x"}, {}) is None


def test_DSN이_없으면_켜지지_않는다(monkeypatch):
    monkeypatch.setattr(settings, "sentry_dsn", None)
    assert observability.init() is False


def test_비활성일_때_capture는_던지지_않는다():
    """리포터가 꺼져 있다고 예외 처리 경로가 깨지면 안 됩니다."""
    observability._enabled = False
    observability.capture(ValueError("테스트"), job_kind="analyze_meal")
    observability.set_user(7)  # 조용히 무시
