"""Natural-language corrections: '밥 150으로', '국 안 먹음', '고기 두 배'.

Correcting a meal has to be faster than the mistake was annoying. Opening a
form, finding the row, and tapping a stepper is slower than saying the fix out
loud — so the Telegram/voice path parses one short sentence instead.

This is intentionally rule-based, not a model call: the grammar is tiny, the
latency budget is a few milliseconds, and a wrong parse must be obvious rather
than plausible.

Three things make it actually work on real sentences:

1. **The command words are stripped before matching.** Scoring the whole
   sentence against item names lets the number and the particle drown the food
   word — "밥 150으로" scores terribly against "잡곡밥".
2. **Category words are first-class.** Nobody looking at a tray says
   "잡곡밥 150으로". They say "밥". 밥/국/고기/반찬/김치/후식 resolve by category.
3. **Matching happens on the space-collapsed sentence**, because "두 배" and
   "두배" are the same instruction, and a one-character instruction ("반", "빼")
   only counts as a whole token — otherwise "반찬" reads as "반" and a side dish
   silently halves itself.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import FoodCategory, Meal, MealItem
from app.services.korean import normalize, similarity, tokens
from app.services.recognition import recompute_meal_item

_REMOVE_WORDS = (
    "안먹음",
    "안먹었음",
    "안먹어",
    "안먹",
    "빼줘",
    "빼기",
    "빼",
    "삭제",
    "지워",
    "지우기",
    "없음",
    "제외",
)

_MULTIPLIERS: dict[str, float] = {
    "두배": 2.0,
    "2배": 2.0,
    "세배": 3.0,
    "3배": 3.0,
    "1.5배": 1.5,
    "절반": 0.5,
    "반만": 0.5,
    "반": 0.5,
}

# 식판을 보고 말할 때 사람들이 실제로 쓰는 단어들.
_CATEGORY_WORDS: dict[str, FoodCategory] = {
    "밥": FoodCategory.RICE,
    "공기밥": FoodCategory.RICE,
    "쌀밥": FoodCategory.RICE,
    "국": FoodCategory.SOUP,
    "국물": FoodCategory.SOUP,
    "찌개": FoodCategory.SOUP,
    "탕": FoodCategory.SOUP,
    "고기": FoodCategory.MAIN,
    "주찬": FoodCategory.MAIN,
    "메인": FoodCategory.MAIN,
    "반찬": FoodCategory.SIDE,
    "부찬": FoodCategory.SIDE,
    "나물": FoodCategory.SIDE,
    "김치": FoodCategory.KIMCHI,
    "후식": FoodCategory.DESSERT,
    "과일": FoodCategory.DESSERT,
    "디저트": FoodCategory.DESSERT,
}

_GRAM = re.compile(r"(\d+(?:\.\d+)?)")

# Everything that is instruction rather than subject. Note that the particles
# are *not* listed bare here: an unanchored "로" turns 브로콜리 into 브 콜리.
_COMMAND_NOISE = re.compile(
    r"\d+(?:\.\d+)?\s*(?:kg|g|그램|그람|개|인분)?\s*(?:으?로|만큼|정도)?"
    r"|바꿔줘|바꿔|고쳐줘|고쳐|해줘|해라|먹었어|먹음"
)
# Subject particles, only where a particle can actually be: the end.
_TRAILING_PARTICLE = re.compile(r"(?:으로|로|은|는|이|가|을|를|만)$")

MATCH_THRESHOLD = 0.45


@dataclass(slots=True)
class EditResult:
    action: str            # set_grams | scale | remove | none
    item_name: str | None
    value: float | None
    message: str


def _match_command(compact: str, toks: list[str], table) -> str | None:
    """Find the instruction word, longest first.

    A one-character word is only an instruction when it stands alone or ends
    the sentence. Without that rule "반찬 100으로" contains "반" and the side
    dish halves instead of being set to 100 g.
    """
    for word in sorted(table, key=len, reverse=True):
        if len(word) == 1:
            if word in toks or compact.endswith(word):
                return word
        elif word in compact:
            return word
    return None


def _strip_command(compact: str, *matched: str | None) -> str:
    """Drop the instruction part, keep the subject.

    '밥150으로' → '밥', '고기두배' → '고기', '국안먹음' → '국'
    """
    stripped = compact
    for word in matched:
        if word:
            stripped = stripped.replace(word, " ")
    stripped = _COMMAND_NOISE.sub(" ", stripped)
    subject = " ".join(stripped.split()).strip()

    # '밥은' → '밥'. But 오이 also ends in a particle-looking syllable, so only
    # trim when what's left is still a plausible subject: a category word, or
    # two syllables and up.
    trimmed = _TRAILING_PARTICLE.sub("", subject)
    if trimmed and (len(trimmed) >= 2 or trimmed in _CATEGORY_WORDS):
        return trimmed
    return subject


def _score(item: MealItem, raw: str, phrase: str) -> float:
    """Best of: the stripped phrase, each of its tokens, the whole sentence."""
    candidates = [phrase, raw, *tokens(phrase)]
    return max((similarity(c, item.name) for c in candidates if c), default=0.0)


def _resolve_target(
    items: list[MealItem], raw: str, phrase: str
) -> tuple[MealItem | None, str | None]:
    """Return ``(item, error_message)``."""
    if not items:
        return None, "수정할 항목이 없습니다."

    # 1. Category word — the way people actually refer to a tray compartment.
    category = _CATEGORY_WORDS.get(normalize(phrase))
    if category is not None:
        in_category = [i for i in items if i.category is category]
        if len(in_category) == 1:
            return in_category[0], None
        if len(in_category) > 1:
            # Don't guess between two side dishes; say which ones there are.
            names = ", ".join(i.name for i in in_category)
            return None, f"어느 쪽인가요? {names}"
        # Nothing in that category — fall through to name matching.

    # 2. Name similarity.
    scored = sorted(
        ((_score(i, raw, phrase), i) for i in items),
        key=lambda pair: pair[0],
        reverse=True,
    )
    best_score, best_item = scored[0]
    if best_score < MATCH_THRESHOLD:
        return None, f"'{raw}'에 해당하는 항목을 찾지 못했습니다."
    return best_item, None


async def apply_natural_edit(db: AsyncSession, meal: Meal, text: str) -> EditResult:
    items = list(
        (
            await db.execute(select(MealItem).where(MealItem.meal_id == meal.id))
        ).scalars().all()
    )

    raw = text.strip()
    # Spaces are noise here — "두 배" and "두배" are one instruction — so the
    # whole sentence is matched space-collapsed.
    compact = normalize(raw)
    toks = tokens(raw)

    removal = _match_command(compact, toks, _REMOVE_WORDS)
    multiplier = _match_command(compact, toks, _MULTIPLIERS)
    phrase = _strip_command(compact, removal, multiplier)

    target, error = _resolve_target(items, raw, phrase)
    if target is None:
        return EditResult("none", None, None, error or "이해하지 못했습니다.")

    if removal:
        name = target.name
        await db.delete(target)
        await db.flush()
        return EditResult("remove", name, None, f"{name}을(를) 뺐습니다.")

    if multiplier:
        factor = _MULTIPLIERS[multiplier]
        await recompute_meal_item(db, target, grams=target.final_g * factor)
        return EditResult(
            "scale",
            target.name,
            factor,
            f"{target.name}을(를) {factor:g}배로 바꿨습니다 ({target.final_g:g}g).",
        )

    match = _GRAM.search(compact)
    if match:
        grams = float(match.group(1))
        if 0 < grams <= 3000:
            await recompute_meal_item(db, target, grams=grams)
            return EditResult(
                "set_grams",
                target.name,
                grams,
                f"{target.name}을(를) {grams:g}g으로 바꿨습니다.",
            )

    return EditResult(
        "none",
        target.name,
        None,
        f"'{raw}'를 어떻게 반영할지 모르겠습니다. "
        "예: '밥 150으로', '국 안 먹음', '고기 두 배'",
    )
