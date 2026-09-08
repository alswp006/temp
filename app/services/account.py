"""계정 삭제.

App Store 심사지침 5.1.1(v)는 계정을 만들 수 있는 앱이라면 앱 안에서 계정을
지울 수 있어야 한다고 요구합니다. 그 요구를 떠나서도, 건강 데이터를 맡긴
사람이 되찾아 갈 방법은 있어야 합니다.

어려운 부분은 "무엇을 지우는가"가 아니라 **"무엇을 지우지 않는가"** 입니다.
users 행 하나를 지우면 외래키 CASCADE가 딸려 나가는데, 그중 몇 개는 남의
데이터입니다.

  Meal.logged_by      코치가 멘티 대신 기록한 끼니. 코치가 탈퇴했다고 멘티의
                      건강 기록이 사라지면 안 됩니다.
  Workout.logged_by   같은 이유.
  Canteen.owner       식당을 만든 사람이 나가면 같은 식당 사람들의 식단표가
                      통째로 날아갑니다. 한 명이 올리면 전부가 쓰는 구조라
                      피해가 큽니다.
  Battle.owner        배틀을 만든 사람이 나가면 참가자 전원의 배틀이 사라집니다.
  AuditLog.actor      내가 남의 데이터에 한 일의 기록. 그건 **당한 사람**의
                      기록이므로 남기고, 신원만 지웁니다.

그래서 users를 지우기 전에 이것들을 먼저 옮겨 놓습니다. 순서가 곧 안전장치라
한 함수 안에 모아 두었습니다.
"""

from __future__ import annotations

import logging
import shutil

from sqlalchemy import delete, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.models import (
    AuditLog,
    LoginCode,
    Battle,
    BattleParticipant,
    Canteen,
    Meal,
    Membership,
    User,
    Workout,
)

log = logging.getLogger(__name__)


async def _hand_over_canteens(db: AsyncSession, user_id: int) -> None:
    """내가 만든 식당을 남은 사람에게 넘깁니다.

    아무도 없으면 지웁니다 — 쓰는 사람이 없는 식당이고, 그 식단표도 마찬가지
    입니다.
    """
    canteens = (
        await db.execute(select(Canteen).where(Canteen.owner_user_id == user_id))
    ).scalars().all()

    for canteen in canteens:
        heir = (
            await db.execute(
                select(Membership)
                .where(
                    Membership.canteen_id == canteen.id,
                    Membership.user_id != user_id,
                )
                .order_by(Membership.id)
                .limit(1)
            )
        ).scalar_one_or_none()
        if heir is None:
            await db.delete(canteen)
            log.info("빈 식당을 지웁니다: canteen=%s", canteen.id)
        else:
            canteen.owner_user_id = heir.user_id
            log.info(
                "식당 주인을 넘깁니다: canteen=%s → user=%s", canteen.id, heir.user_id
            )


async def _hand_over_battles(db: AsyncSession, user_id: int) -> None:
    """내가 만든 배틀을 남은 참가자에게 넘깁니다."""
    battles = (
        await db.execute(select(Battle).where(Battle.owner_user_id == user_id))
    ).scalars().all()

    for battle in battles:
        heir = (
            await db.execute(
                select(BattleParticipant)
                .where(
                    BattleParticipant.battle_id == battle.id,
                    BattleParticipant.user_id != user_id,
                )
                .order_by(BattleParticipant.id)
                .limit(1)
            )
        ).scalar_one_or_none()
        if heir is None:
            await db.delete(battle)
        else:
            battle.owner_user_id = heir.user_id


def _purge_media(user_id: int) -> None:
    """이 사용자의 사진 폴더를 통째로 지웁니다.

    경로가 `{kind}/{user_id}/…` 라서 종류별로 한 폴더씩입니다. 지우지 못해도
    계정 삭제 자체는 진행합니다 — DB에서 사라진 사진은 어차피 화면에 닿지
    않고, 파일 하나 때문에 탈퇴를 막을 이유가 없습니다.
    """
    root = settings.media_root
    if not root.exists():
        return
    for kind_dir in root.iterdir():
        if not kind_dir.is_dir():
            continue
        target = kind_dir / str(user_id)
        if target.is_dir():
            try:
                shutil.rmtree(target)
            except OSError as exc:  # noqa: PERF203
                log.warning("사진 삭제 실패 (%s): %s", target, exc)


async def delete_account(db: AsyncSession, user: User) -> None:
    """계정과 그 사람의 데이터를 지웁니다. 남의 데이터는 지키면서."""
    user_id = user.id

    # ① 남이 소유한 기록의 '작성자'가 나인 경우, 소유자 본인으로 되돌립니다.
    #    logged_by는 NOT NULL이라 비울 수 없고, 비울 이유도 없습니다 — 그
    #    기록의 주인은 처음부터 user_id 쪽입니다.
    await db.execute(
        update(Meal)
        .where(Meal.logged_by == user_id, Meal.user_id != user_id)
        .values(logged_by=Meal.user_id)
    )
    await db.execute(
        update(Workout)
        .where(Workout.logged_by == user_id, Workout.user_id != user_id)
        .values(logged_by=Workout.user_id)
    )

    # ② 남이 당한 일의 기록은 남기고, 행위자만 지웁니다.
    await db.execute(
        update(AuditLog)
        .where(AuditLog.actor_user_id == user_id, AuditLog.target_user_id != user_id)
        .values(actor_user_id=None)
    )
    # 내가 당한 기록은 내 데이터이므로 함께 지웁니다.
    await db.execute(delete(AuditLog).where(AuditLog.target_user_id == user_id))

    # ③ 여럿이 쓰는 것은 넘기거나, 아무도 없으면 지웁니다.
    await _hand_over_canteens(db, user_id)
    await _hand_over_battles(db, user_id)

    await db.flush()

    # ④ 로그인 코드는 users를 가리키지 않습니다. 이메일 문자열만 들고 있어서
    #    외래키 CASCADE가 데려가지 않고, 그대로 두면 "계정을 지웠다"고 해 놓고
    #    이메일 주소가 DB에 남습니다.
    await db.execute(delete(LoginCode).where(LoginCode.email == user.email))

    # ⑤ 나머지는 외래키 CASCADE가 데려갑니다 — 내 끼니·운동·체중·알림·기기
    #    토큰·연결·목표·보정 표본.
    await db.delete(user)
    await db.flush()

    _purge_media(user_id)
    log.info("계정을 삭제했습니다: user=%s", user_id)
