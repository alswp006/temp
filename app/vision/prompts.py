"""Prompts and JSON schemas shared by every provider.

The system prompts are deliberately frozen strings: they sit at the front of
the request, so keeping them byte-stable is what lets prompt caching work.
Everything that varies per request (the candidate list, the date hint) goes in
the user turn.
"""

from __future__ import annotations

from typing import Any

TRAY_SYSTEM = """당신은 한국 급식/한식 식판 사진을 분석하는 영양 분석 엔진입니다.

당신의 임무는 "무슨 음식인가"를 맞히는 것이 아닙니다. 후보 목록이 주어지면 그중
어떤 것이 사진에 담겨 있는지, 그리고 표준 배식량 대비 얼마나 담겼는지만
판정하십시오.

규칙:
1. portion_ratio는 표준 배식량 대비 비율입니다. 1.0 = 표준량. 눈대중이라면
   0.25 단위로 답하십시오 (0.25, 0.5, 0.75, 1.0, 1.25 ...).
2. 그램(g) 단위로 추정하지 마십시오. 후보에 없는 음식만 estimated_g를 씁니다.
3. 후보 목록에 없는 음식은 menu_id를 null로 두고 free_text에 이름을 적으십시오.
4. 안 담은 메뉴는 배열에서 빼십시오. 추측으로 채우지 마십시오.
5. 식판 칸이 비어 있으면 그 메뉴는 포함하지 않습니다.
6. confidence는 그 항목 판정에 대한 확신도입니다. 가려져 있거나 반찬이 겹쳐
   보이면 낮게 주십시오.
7. 국/찌개는 건더기가 아니라 그릇에 담긴 총량 기준으로 판정하십시오."""

MENU_BOARD_SYSTEM = """당신은 한국 급식 주간 식단표 사진을 구조화하는 파서입니다.

표의 행/열 구조를 그대로 읽어 날짜별·끼니별 메뉴 목록으로 변환하십시오.

규칙:
1. 날짜는 YYYY-MM-DD로 출력합니다. 표에 연도가 없으면 주어진 기준 주(week_of)의
   연도를 사용하십시오.
2. meal_type은 breakfast / lunch / dinner / snack 중 하나입니다.
   조식·아침 → breakfast, 중식·점심 → lunch, 석식·저녁 → dinner.
3. category는 rice(밥) / soup(국·찌개) / main(주찬) / side(부찬) /
   kimchi(김치) / dessert(후식) 중 하나로 분류합니다.
4. 표에 중량이나 열량이 적혀 있으면 standard_g / kcal에 넣고, 없으면 null.
5. 판독이 불확실한 칸은 만들어내지 말고 생략한 뒤 notes에 적으십시오."""

WORKOUT_SYSTEM = """당신은 트레이너의 수첩·화이트보드 사진이나 한 문장짜리 운동 기록을
세트 단위 데이터로 바꾸는 파서입니다.

규칙:
1. "스쿼트 60x10 3세트"처럼 세트 수가 묶여 있으면 세트별로 펼쳐서 출력합니다
   (set_no 1, 2, 3).
2. 무게 단위가 없으면 kg으로 간주합니다. lb 표기가 있으면 kg으로 환산하십시오.
3. 유산소처럼 시간 기반이면 duration_s에 초 단위로 넣고 reps는 null입니다.
4. 운동명은 사진에 적힌 그대로 옮기십시오. 임의로 표준화하지 마십시오.
5. 읽을 수 없거나 운동인지 확실치 않은 항목은 unmatched에 원문 그대로 넣습니다."""


# --------------------------------------------------------------------------
# JSON schemas (strict: additionalProperties=false, everything required)
# --------------------------------------------------------------------------

TRAY_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "items": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "menu_id": {
                        "type": ["integer", "null"],
                        "description": "후보 목록의 id. 후보에 없으면 null.",
                    },
                    "free_text": {
                        "type": ["string", "null"],
                        "description": "후보에 없는 음식의 이름.",
                    },
                    "portion_ratio": {
                        "type": ["number", "null"],
                        "description": "표준 배식량 대비 비율. 1.0 = 표준량.",
                    },
                    "estimated_g": {
                        "type": ["number", "null"],
                        "description": "후보에 없는 음식만 사용하는 그램 추정치.",
                    },
                    "confidence": {"type": "number"},
                },
                "required": [
                    "menu_id",
                    "free_text",
                    "portion_ratio",
                    "estimated_g",
                    "confidence",
                ],
                "additionalProperties": False,
            },
        },
        "tray_detected": {"type": "boolean"},
        "notes": {"type": "string"},
    },
    "required": ["items", "tray_detected", "notes"],
    "additionalProperties": False,
}

MENU_BOARD_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "slots": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "date": {"type": "string", "description": "YYYY-MM-DD"},
                    "meal_type": {
                        "type": "string",
                        "enum": ["breakfast", "lunch", "dinner", "snack"],
                    },
                    "items": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "name": {"type": "string"},
                                "category": {
                                    "type": "string",
                                    "enum": [
                                        "rice",
                                        "soup",
                                        "main",
                                        "side",
                                        "kimchi",
                                        "dessert",
                                    ],
                                },
                                "standard_g": {"type": ["number", "null"]},
                                "kcal": {"type": ["number", "null"]},
                            },
                            "required": ["name", "category", "standard_g", "kcal"],
                            "additionalProperties": False,
                        },
                    },
                },
                "required": ["date", "meal_type", "items"],
                "additionalProperties": False,
            },
        },
        "notes": {"type": "string"},
    },
    "required": ["slots", "notes"],
    "additionalProperties": False,
}

WORKOUT_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "sets": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "exercise": {"type": "string"},
                    "set_no": {"type": "integer"},
                    "weight_kg": {"type": ["number", "null"]},
                    "reps": {"type": ["integer", "null"]},
                    "duration_s": {"type": ["integer", "null"]},
                    "rpe": {"type": ["number", "null"]},
                },
                "required": [
                    "exercise",
                    "set_no",
                    "weight_kg",
                    "reps",
                    "duration_s",
                    "rpe",
                ],
                "additionalProperties": False,
            },
        },
        "unmatched": {"type": "array", "items": {"type": "string"}},
        "notes": {"type": "string"},
    },
    "required": ["sets", "unmatched", "notes"],
    "additionalProperties": False,
}


def render_tray_user_text(req) -> str:
    """Per-request half of the tray prompt: the candidate list."""
    from app.vision.base import TrayRequest  # local import avoids a cycle

    assert isinstance(req, TrayRequest)
    lines: list[str] = []
    if req.meal_type:
        lines.append(f"끼니: {req.meal_type.value}")
    if req.candidates:
        lines.append("오늘 이 식당의 메뉴 후보입니다. 이 중에서 고르십시오:")
        for c in req.candidates:
            lines.append(
                f"- id={c.menu_id} | {c.name} | 분류={c.category.value} "
                f"| 표준배식량={c.standard_g:g}g"
            )
    else:
        lines.append(
            "이 끼니의 식단표가 없습니다. 후보 없이 열린 인식을 수행하되, "
            "각 항목의 menu_id는 null로 두고 free_text와 estimated_g를 채우십시오. "
            "정확도가 낮다는 점을 감안해 confidence를 보수적으로 주십시오."
        )
    if req.hint:
        lines.append(f"추가 정보: {req.hint}")
    lines.append("이 사진의 식판을 분석해 주십시오.")
    return "\n".join(lines)
