"""알림 생성의 유일한 입구.

전에는 다섯 군데에서 `Notification(...)`을 직접 만들었습니다. 그러면 여섯
번째를 추가하는 사람이 푸시를 붙이는 걸 잊습니다 — 잊어도 아무 경고가 없고,
증상은 "어떤 알림만 푸시가 안 온다"는 형태로 한참 뒤에 나타납니다.

그래서 입구를 하나로 만들고, 그 입구가 행 저장과 푸시 예약을 함께 합니다.
"""

from __future__ import annotations

from sqlalchemy.ext.asyncio import AsyncSession

from app.jobs.queue import enqueue
from app.models import Notification


async def notify(
    db: AsyncSession,
    *,
    user_id: int,
    kind: str,
    title: str,
    body: str | None = None,
    payload: dict | None = None,
    push: bool = True,
) -> Notification:
    """알림 행을 만들고 푸시를 예약합니다.

    푸시는 잡 큐로 나갑니다 — 요청 경로에서 FCM을 부르면 구글이 느린 날
    사용자의 저장 버튼도 같이 느려집니다.

    ``push=False``는 "앱에서 보이면 충분한" 알림에 씁니다. 로드맵이 금지한
    미기록 독촉 같은 것이 여기 해당합니다.
    """
    row = Notification(
        user_id=user_id,
        kind=kind,
        title=title,
        body=body,
        payload=payload or {},
    )
    db.add(row)
    await db.flush()

    if push:
        await enqueue(db, "push_notification", {"notification_id": row.id})
    return row
