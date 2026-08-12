#!/usr/bin/env python3
"""식약처 식품영양성분 통합 DB (공공데이터포털) 적재기.

The bundled ``app/data/foods.csv`` is a ~150-row starter table so the app is
useful the minute it boots. This replaces it with the real ~92k-row national
database.

Download: 공공데이터포털 → "식품의약품안전처 식품영양성분DB" → CSV.

Column names in that export have changed more than once, so this maps by a set
of known aliases rather than fixed positions, reports what it could not map,
and refuses to write a garbage row silently.

    python scripts/import_mfds.py 20240101_음식DB.csv [--encoding cp949] [--replace]
"""

from __future__ import annotations

import argparse
import asyncio
import csv
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from sqlalchemy import delete, select  # noqa: E402

from app.db import create_all, dispose_engine, session_scope  # noqa: E402
from app.models import Food, FoodAlias, FoodCategory  # noqa: E402
from app.services.korean import normalize  # noqa: E402
from app.services.nutrition import guess_category  # noqa: E402

# Column aliases seen across MFDS exports. First match wins.
COLUMNS: dict[str, tuple[str, ...]] = {
    "code": ("식품코드", "FOOD_CD", "식품코드(DB)"),
    "name": ("식품명", "DESC_KOR", "FOOD_NM_KR"),
    "kcal": ("에너지(kcal)", "에너지(㎉)", "NUTR_CONT1", "열량(kcal)"),
    "carb": ("탄수화물(g)", "NUTR_CONT2", "탄수화물"),
    "protein": ("단백질(g)", "NUTR_CONT3", "단백질"),
    "fat": ("지방(g)", "NUTR_CONT4", "지방"),
    "sodium": ("나트륨(mg)", "NUTR_CONT6", "나트륨"),
    "serving": ("영양성분함량기준량", "SERVING_SIZE", "1회제공량"),
    "group": ("식품대분류명", "식품군", "GROUP_NAME"),
}


def pick(row: dict, key: str) -> str | None:
    for alias in COLUMNS[key]:
        if alias in row and str(row[alias]).strip():
            return str(row[alias]).strip()
    return None


def to_float(value: str | None, default: float = 0.0) -> float:
    if not value:
        return default
    cleaned = "".join(ch for ch in value if ch.isdigit() or ch in ".-")
    try:
        return float(cleaned)
    except ValueError:
        return default


def serving_grams(value: str | None) -> float:
    """'100g' / '100 g' / '1회 200ml' → 100.0 / 200.0"""
    grams = to_float(value, 100.0)
    return grams if 1 <= grams <= 2000 else 100.0


async def run(path: Path, encoding: str, replace: bool, limit: int | None) -> None:
    await create_all()

    async with session_scope() as db:
        if replace:
            await db.execute(delete(FoodAlias))
            await db.execute(delete(Food))
            print("기존 food 데이터를 비웠습니다.")
            existing: set[str] = set()
        else:
            existing = set((await db.execute(select(Food.name_norm))).scalars().all())

        added = skipped = malformed = 0
        with path.open(encoding=encoding, newline="", errors="replace") as fh:
            reader = csv.DictReader(fh)
            if not reader.fieldnames:
                raise SystemExit("CSV 헤더를 읽지 못했습니다.")
            print(f"컬럼 {len(reader.fieldnames)}개 인식: {reader.fieldnames[:6]} …")

            for i, row in enumerate(reader):
                if limit and added >= limit:
                    break
                name = pick(row, "name")
                if not name:
                    malformed += 1
                    continue
                norm = normalize(name)
                if not norm or norm in existing:
                    skipped += 1
                    continue

                kcal = to_float(pick(row, "kcal"), -1.0)
                if kcal < 0:
                    # No energy value means the row is useless for our purpose.
                    malformed += 1
                    continue

                group = pick(row, "group") or ""
                category = (
                    FoodCategory.KIMCHI
                    if "김치" in group
                    else guess_category(f"{name} {group}")
                )

                db.add(
                    Food(
                        code=pick(row, "code"),
                        name=name,
                        name_norm=norm,
                        category=category,
                        kcal_100g=kcal,
                        carb_100g=to_float(pick(row, "carb")),
                        protein_100g=to_float(pick(row, "protein")),
                        fat_100g=to_float(pick(row, "fat")),
                        sodium_mg_100g=to_float(pick(row, "sodium"), 0.0) or None,
                        default_serving_g=serving_grams(pick(row, "serving")),
                        source="mfds",
                    )
                )
                existing.add(norm)
                added += 1

                if added % 2000 == 0:
                    await db.flush()
                    print(f"  … {added}건")

        await db.flush()

    print(f"완료: 추가 {added} / 중복 {skipped} / 형식 오류 {malformed}")
    if malformed > added * 0.2:
        print(
            "⚠ 형식 오류 비율이 높습니다. --encoding cp949 를 시도하거나 "
            "COLUMNS 매핑에 이 파일의 컬럼명을 추가하십시오."
        )
    await dispose_engine()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv", type=Path)
    parser.add_argument("--encoding", default="utf-8-sig")
    parser.add_argument(
        "--replace", action="store_true", help="기존 food 테이블을 비우고 적재"
    )
    parser.add_argument("--limit", type=int, default=None)
    args = parser.parse_args()

    if not args.csv.exists():
        raise SystemExit(f"파일이 없습니다: {args.csv}")
    asyncio.run(run(args.csv, args.encoding, args.replace, args.limit))


if __name__ == "__main__":
    main()
