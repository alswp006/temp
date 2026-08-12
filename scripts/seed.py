#!/usr/bin/env python3
"""Seed reference data (foods, exercises). Idempotent."""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.db import create_all, dispose_engine, session_scope  # noqa: E402
from app.services import nutrition  # noqa: E402


async def main() -> None:
    await create_all()
    async with session_scope() as db:
        counts = await nutrition.seed_all(db)
    print(f"seeded: {counts}")
    await dispose_engine()


if __name__ == "__main__":
    asyncio.run(main())
