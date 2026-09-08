"""요청 빈도 제한.

두 층으로 나눕니다.

* **이메일별** — 이미 저장하고 있는 `login_codes` 행을 세면 됩니다. DB에
  남으므로 워커를 여러 개 띄워도, 재시작해도 그대로 유효합니다. 별도 테이블도
  마이그레이션도 필요 없습니다.
* **출발지별** — 주소를 바꿔 가며 계정을 찍어내는 것은 이메일별로는 못 막습니다.
  이건 프로세스 메모리에 셉니다.

메모리 카운터의 한계를 분명히 해 둡니다. 워커마다 따로 세고 재시작하면
사라지므로, 진짜 방어선은 앞단(리버스 프록시·CDN)이어야 합니다. 여기 있는 것은
"아무것도 없는 상태"보다 낫게 만드는 최소한이고, 실수로 도는 스크립트나 가벼운
남용을 막는 정도입니다.
"""

from __future__ import annotations

import time
from collections import defaultdict, deque


class SlidingWindow:
    """키마다 최근 [window]초 안의 호출 수를 셉니다."""

    def __init__(self, limit: int, window_seconds: float) -> None:
        self.limit = limit
        self.window = window_seconds
        self._hits: dict[str, deque[float]] = defaultdict(deque)

    def allow(self, key: str, *, now: float | None = None) -> bool:
        """한 번 세고, 한도 안이면 True."""
        t = time.monotonic() if now is None else now
        hits = self._hits[key]
        cutoff = t - self.window
        while hits and hits[0] < cutoff:
            hits.popleft()
        if len(hits) >= self.limit:
            return False
        hits.append(t)
        return True

    def reset(self, key: str | None = None) -> None:
        if key is None:
            self._hits.clear()
        else:
            self._hits.pop(key, None)


def client_key(request) -> str:
    """요청 출발지.

    프록시 뒤에서는 모든 요청이 프록시의 주소로 보이므로, 그 배치에서는 이
    한도가 사실상 전역 한도가 됩니다. X-Forwarded-For를 그냥 믿으면 헤더를
    지어내서 우회할 수 있으므로 믿지 않습니다 — 신뢰할 수 있는 프록시 설정은
    앱이 아니라 배포에서 정할 일입니다.
    """
    client = getattr(request, "client", None)
    return getattr(client, "host", None) or "unknown"
