"""audit actor can be anonymised

행위자가 탈퇴해도 **당한 사람**의 감사 기록은 남아야 합니다. 그 줄은 자기
데이터에 누가 손댔는지 보는 근거이고, 앱이 코드로 강제한다고 말한 안전장치 중
하나입니다. 동시에 탈퇴한 사람의 신원은 남으면 안 됩니다.

행을 남기고 사람만 지웁니다. 여기서는 컬럼을 NULL 허용으로 바꾸기만 하고,
실제로 비우는 일은 계정 삭제 서비스가 사용자 행을 지우기 **전에** 합니다.
DB 제약(ondelete)에 기대지 않는 이유는, SQLite에서 이름 없는 외래키를 배치
모드로 갈아끼우는 것이 조용히 깨지기 쉽고, 무엇을 남기고 무엇을 지울지는
애플리케이션이 명시적으로 정하는 편이 읽기 쉽기 때문입니다.

Revision ID: 8b41c02de6a7
Revises: 6c7759f98d89
Create Date: 2026-09-09
"""
from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "8b41c02de6a7"
down_revision: Union[str, None] = "6c7759f98d89"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


# 모델의 외래키에는 이름이 없습니다. SQLite에서 배치 모드로 갈아끼우려면 이름이
# 있어야 하므로, 알렘빅에 규칙을 주어 계산하게 합니다.
_NAMING = {"fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s"}
_FK = "fk_audit_logs_actor_user_id_users"


def upgrade() -> None:
    with op.batch_alter_table(
        "audit_logs", schema=None, naming_convention=_NAMING
    ) as batch_op:
        batch_op.alter_column(
            "actor_user_id", existing_type=sa.Integer(), nullable=True
        )
        batch_op.drop_constraint(_FK, type_="foreignkey")
        batch_op.create_foreign_key(
            _FK, "users", ["actor_user_id"], ["id"], ondelete="SET NULL"
        )


def downgrade() -> None:
    # NOT NULL로 되돌리려면 주인 없는 줄을 먼저 치워야 합니다.
    op.execute(sa.text("DELETE FROM audit_logs WHERE actor_user_id IS NULL"))
    with op.batch_alter_table(
        "audit_logs", schema=None, naming_convention=_NAMING
    ) as batch_op:
        batch_op.drop_constraint(_FK, type_="foreignkey")
        batch_op.create_foreign_key(
            _FK, "users", ["actor_user_id"], ["id"], ondelete="CASCADE"
        )
        batch_op.alter_column(
            "actor_user_id", existing_type=sa.Integer(), nullable=False
        )
