"""Deterministic offline provider.

This is not a toy: it is what makes the whole system runnable, demoable, and
CI-testable with no API key and no network. It derives every answer from a hash
of the image bytes, so the same photo always yields the same reading, while the
per-call ``nonce`` injects the small variance that the K-call median exists to
smooth out.
"""

from __future__ import annotations

import hashlib
from datetime import date, timedelta

from app.models import FoodCategory, MealType
from app.vision.base import (
    DetectedItem,
    MenuBoardParse,
    MenuBoardRequest,
    ParsedMenuItem,
    ParsedMenuSlot,
    ParsedWorkoutSet,
    TrayAnalysis,
    TrayRequest,
    VisionProvider,
    WorkoutNoteRequest,
    WorkoutParse,
)

# Quantised the same way the prompt asks a real model to answer.
_RATIOS = [0.5, 0.75, 1.0, 1.0, 1.0, 1.25, 1.5]


def _rng_stream(*parts: object) -> list[int]:
    """A deterministic byte stream from arbitrary inputs."""
    seed = "|".join(str(p) for p in parts).encode("utf-8")
    digest = hashlib.sha256(seed).digest()
    # 64 bytes is plenty for a tray; extend by rehashing if a caller needs more.
    return list(digest + hashlib.sha256(digest).digest())


class StubVisionProvider(VisionProvider):
    name = "stub"

    async def analyze_tray(self, req: TrayRequest) -> TrayAnalysis:
        fingerprint = hashlib.sha256(req.image.data).hexdigest()[:16]
        stream = _rng_stream(fingerprint, req.nonce, len(req.candidates))

        if not req.candidates:
            # Open mode: no candidate list, so guess conservatively and say so.
            return TrayAnalysis(
                items=[
                    DetectedItem(
                        free_text="흰쌀밥",
                        estimated_g=200.0,
                        confidence=0.40,
                    ),
                    DetectedItem(
                        free_text="반찬(미상)",
                        estimated_g=90.0,
                        confidence=0.30,
                    ),
                ],
                tray_detected=True,
                notes="식단표 없음 — 열린 인식 모드(오차 큼).",
            )

        items: list[DetectedItem] = []
        for idx, cand in enumerate(req.candidates):
            b = stream[idx % len(stream)]
            # ~1 in 8 candidates wasn't taken. Rice is always taken.
            if cand.category is not FoodCategory.RICE and b % 8 == 0:
                continue
            ratio = _RATIOS[(b + req.nonce) % len(_RATIOS)]
            confidence = 0.72 + (stream[(idx + 7) % len(stream)] % 25) / 100.0
            items.append(
                DetectedItem(
                    menu_id=cand.menu_id,
                    portion_ratio=ratio,
                    confidence=round(min(confidence, 0.97), 2),
                )
            )

        # Occasionally there is something on the tray the menu board didn't list.
        if stream[3] % 5 == 0:
            items.append(
                DetectedItem(free_text="요구르트", estimated_g=65.0, confidence=0.42)
            )

        return TrayAnalysis(items=items, tray_detected=True, notes="")

    async def parse_menu_board(self, req: MenuBoardRequest) -> MenuBoardParse:
        monday = req.week_of or date.today()
        monday = monday - timedelta(days=monday.weekday())
        template: list[tuple[str, FoodCategory, float]] = [
            ("잡곡밥", FoodCategory.RICE, 210),
            ("된장찌개", FoodCategory.SOUP, 250),
            ("제육볶음", FoodCategory.MAIN, 120),
            ("시금치나물", FoodCategory.SIDE, 60),
            ("배추김치", FoodCategory.KIMCHI, 40),
        ]
        slots = [
            ParsedMenuSlot(
                date=monday + timedelta(days=day),
                meal_type=MealType.LUNCH,
                items=[
                    ParsedMenuItem(name=name, category=cat, standard_g=g)
                    for name, cat, g in template
                ],
            )
            for day in range(5)
        ]
        return MenuBoardParse(slots=slots, notes="stub provider")

    async def parse_workout_note(self, req: WorkoutNoteRequest) -> WorkoutParse:
        if req.text:
            return _parse_workout_text(req.text)
        return WorkoutParse(
            sets=[
                ParsedWorkoutSet(exercise="바벨 스쿼트", set_no=n, weight_kg=60, reps=10)
                for n in (1, 2, 3)
            ],
            notes="stub provider",
        )


def _parse_workout_text(text: str) -> WorkoutParse:
    """A small rule-based parser for lines like
    ``스쿼트 60에 10개 3세트, 랫풀 50에 12개 3세트``.

    It exists so the voice/text entry path works without a model call at all —
    most trainer shorthand is this regular, and a free local parse is strictly
    better than a paid remote one when it succeeds.
    """
    import re

    pattern = re.compile(
        r"(?P<name>[^\d,·/]+?)\s*"
        r"(?P<weight>\d+(?:\.\d+)?)\s*(?:kg)?\s*(?:에|x|X|\*|×)\s*"
        r"(?P<reps>\d+)\s*(?:개|회|reps?)?\s*"
        r"(?:(?P<sets>\d+)\s*(?:세트|set)s?)?"
    )
    sets: list[ParsedWorkoutSet] = []
    unmatched: list[str] = []
    for chunk in re.split(r"[,\n]", text):
        chunk = chunk.strip()
        if not chunk:
            continue
        m = pattern.search(chunk)
        if not m:
            unmatched.append(chunk)
            continue
        name = m.group("name").strip()
        weight = float(m.group("weight"))
        reps = int(m.group("reps"))
        count = int(m.group("sets") or 1)
        for n in range(1, count + 1):
            sets.append(
                ParsedWorkoutSet(exercise=name, set_no=n, weight_kg=weight, reps=reps)
            )
    return WorkoutParse(sets=sets, unmatched=unmatched)
