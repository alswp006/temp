"""Korean text normalisation and fuzzy matching.

Menu boards, OCR output, and hand-typed food names disagree constantly:
"김치찌개", "김치 찌개", "김치찌게", "돼지고기김치찌개(국내산)". Matching them to a
nutrition DB row needs more than equality, and pulling in a full morphological
analyser is overkill for names this short.

Approach: normalise → decompose Hangul into jamo → character-bigram Dice, with
a substring bonus. Jamo decomposition is what makes 찌개/찌게 near-identical
(they differ in one vowel out of ~10 jamo) instead of a whole-syllable miss.
"""

from __future__ import annotations

import re
import unicodedata

# Hangul syllable block arithmetic.
_SBASE = 0xAC00
_LCOUNT, _VCOUNT, _TCOUNT = 19, 21, 28
_NCOUNT = _VCOUNT * _TCOUNT  # 588
_SCOUNT = _LCOUNT * _NCOUNT  # 11172

_CHOSUNG = "ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ"
_JUNGSUNG = "ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ"
_JONGSUNG = " ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ"

_PARENS = re.compile(r"[(（\[［{][^)）\]］}]*[)）\]］}]")
_NOISE = re.compile(r"[^0-9a-z가-힣ㄱ-ㅎㅏ-ㅣ]+")

# Menu-board decorations that carry no identity: origin labels, allergen
# numbers, portion markers.
_STOPWORDS = (
    "국내산",
    "수입산",
    "냉동",
    "냉장",
    "자율",
    "선택",
    "추가",
    "특식",
    "기타",
)


def normalize(text: str) -> str:
    """Lowercase, strip parentheticals/punctuation/stopwords, drop spaces."""
    if not text:
        return ""
    s = unicodedata.normalize("NFC", text).strip().lower()
    s = _PARENS.sub(" ", s)
    s = _NOISE.sub(" ", s)
    for word in _STOPWORDS:
        s = s.replace(word, " ")
    return "".join(s.split())


def tokens(text: str) -> list[str]:
    """Whitespace tokens after light cleaning (spaces preserved, unlike
    :func:`normalize`)."""
    if not text:
        return []
    s = unicodedata.normalize("NFC", text).strip().lower()
    s = _PARENS.sub(" ", s)
    s = _NOISE.sub(" ", s)
    return [t for t in s.split() if t and t not in _STOPWORDS]


def to_jamo(text: str) -> str:
    """Decompose Hangul syllables into their component jamo.

    Non-Hangul characters pass through unchanged, so mixed strings such as
    "닭가슴살100g" still work.
    """
    out: list[str] = []
    for ch in text:
        code = ord(ch) - _SBASE
        if 0 <= code < _SCOUNT:
            out.append(_CHOSUNG[code // _NCOUNT])
            out.append(_JUNGSUNG[(code % _NCOUNT) // _TCOUNT])
            t = code % _TCOUNT
            if t:
                out.append(_JONGSUNG[t])
        else:
            out.append(ch)
    return "".join(out)


def _bigrams(s: str) -> set[str]:
    if len(s) < 2:
        return {s} if s else set()
    return {s[i : i + 2] for i in range(len(s) - 1)}


def _dice(a: str, b: str) -> float:
    ba, bb = _bigrams(a), _bigrams(b)
    if not ba or not bb:
        return 0.0
    return 2 * len(ba & bb) / (len(ba) + len(bb))


def similarity(a: str, b: str) -> float:
    """Similarity in [0, 1] between two Korean food/exercise names."""
    na, nb = normalize(a), normalize(b)
    if not na or not nb:
        return 0.0
    if na == nb:
        return 1.0

    score = _dice(to_jamo(na), to_jamo(nb))

    # "김치찌개" inside "돼지고기김치찌개" should beat a raw bigram score. Weight
    # by how much of the longer string the shorter one covers, so a two-char
    # fragment of a ten-char name doesn't score as a match.
    if na in nb or nb in na:
        shorter, longer = (na, nb) if len(na) <= len(nb) else (nb, na)
        coverage = len(shorter) / len(longer)
        score = max(score, 0.60 + 0.40 * coverage)

    # Shared whole tokens are a strong signal ("훈제 오리" vs "오리 훈제").
    ta, tb = set(tokens(a)), set(tokens(b))
    if ta and tb:
        overlap = len(ta & tb) / max(len(ta), len(tb))
        if overlap:
            score = max(score, 0.55 + 0.45 * overlap)

    return round(min(score, 1.0), 4)


def best_matches(
    query: str, candidates: dict[str, object], *, limit: int = 3, threshold: float = 0.0
) -> list[tuple[object, float]]:
    """Rank ``candidates`` (name → payload) against ``query``."""
    scored = [
        (payload, similarity(query, name))
        for name, payload in candidates.items()
    ]
    scored = [(p, s) for p, s in scored if s >= threshold]
    scored.sort(key=lambda pair: pair[1], reverse=True)
    return scored[:limit]
