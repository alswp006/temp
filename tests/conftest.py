"""Test harness.

Environment is configured *before* any app import, because settings and the DB
engine are both module-level singletons built from it.
"""

from __future__ import annotations

import os
import tempfile
from pathlib import Path

_TMP = Path(tempfile.mkdtemp(prefix="sikpan-test-"))
os.environ.setdefault("ENV", "test")
os.environ.setdefault("DATABASE_URL", f"sqlite+aiosqlite:///{_TMP / 'test.db'}")
os.environ.setdefault("MEDIA_ROOT", str(_TMP / "media"))
os.environ.setdefault("VISION_PROVIDER", "stub")
os.environ.setdefault("RUN_WORKER_IN_PROCESS", "false")
os.environ.setdefault("SECRET_KEY", "test-secret-key-not-for-production")

import io  # noqa: E402
from datetime import datetime, timezone  # noqa: E402

import pytest  # noqa: E402
import pytest_asyncio  # noqa: E402
from httpx import ASGITransport, AsyncClient  # noqa: E402
from PIL import Image  # noqa: E402

from app.db import SessionLocal, engine  # noqa: E402
from app.jobs import handlers  # noqa: F401,E402 - registers job handlers
from app.main import app  # noqa: E402
from app.models import Base  # noqa: E402
from app.services import nutrition  # noqa: E402


@pytest_asyncio.fixture(scope="function")
async def db():
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)
    async with SessionLocal() as session:
        await nutrition.seed_all(session)
        await session.commit()
    async with SessionLocal() as session:
        yield session


@pytest_asyncio.fixture(scope="function")
async def client(db):
    transport = ASGITransport(app=app)
    async with AsyncClient(
        transport=transport, base_url="http://test", timeout=30.0
    ) as ac:
        yield ac


def make_photo(seed: str = "tray", size: tuple[int, int] = (900, 700)) -> bytes:
    """A deterministic JPEG. The stub provider hashes the bytes, so a given
    seed always produces the same reading."""
    img = Image.new("RGB", size)
    # Fill with a seed-dependent gradient so different seeds differ in bytes.
    base = sum(ord(c) for c in seed) % 200
    px = img.load()
    for y in range(0, size[1], 7):
        for x in range(0, size[0], 7):
            value = (base + x // 7 + y // 7) % 256
            for dy in range(7):
                for dx in range(7):
                    if x + dx < size[0] and y + dy < size[1]:
                        px[x + dx, y + dy] = (value, (value * 3) % 256, (value * 7) % 256)
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=80)
    return buf.getvalue()


async def register(client: AsyncClient, email: str, nickname: str = "테스터") -> dict:
    """Full magic-link login, returning ``{token, user, headers}``."""
    r = await client.post(
        "/api/auth/request-code", json={"email": email, "nickname": nickname}
    )
    assert r.status_code == 200, r.text
    code = r.json()["dev_code"]
    assert code, "dev_code should be exposed in test env"

    r = await client.post("/api/auth/verify", json={"email": email, "code": code})
    assert r.status_code == 200, r.text
    payload = r.json()
    return {
        "token": payload["access_token"],
        "user": payload["user"],
        "headers": {"Authorization": f"Bearer {payload['access_token']}"},
    }


def utc(y, m, d, hh=12, mm=0) -> datetime:
    return datetime(y, m, d, hh, mm, tzinfo=timezone.utc)


def local_today():
    """The date the *app* means by "today".

    Everything user-facing is bucketed by ``local_date`` in the user's own
    timezone (Asia/Seoul by default), so a test that reaches for
    ``date.today()`` on a UTC container silently tests a different day for the
    nine hours after 15:00 UTC.
    """
    from app.core.timeutil import today_local

    return today_local(DEFAULT_TZ)


DEFAULT_TZ = "Asia/Seoul"


@pytest.fixture
def photo_bytes():
    return make_photo()
