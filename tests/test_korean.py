"""Korean normalisation and fuzzy matching."""

from __future__ import annotations

import pytest

from app.services.korean import normalize, similarity, to_jamo, tokens


def test_normalize_strips_parentheticals_and_stopwords():
    assert normalize("배추김치(국내산)") == "배추김치"
    assert normalize("제육 볶음") == "제육볶음"
    assert normalize("돈까스 [수입산]") == "돈까스"
    assert normalize("") == ""


def test_jamo_decomposition():
    # 김 = ㄱ + ㅣ + ㅁ
    assert to_jamo("김") == "ㄱㅣㅁ"
    assert to_jamo("가") == "ㄱㅏ"          # no final consonant
    assert to_jamo("abc") == "abc"         # non-Hangul passes through


def test_identical_names_score_one():
    assert similarity("김치찌개", "김치찌개") == 1.0
    assert similarity("김치 찌개", "김치찌개") == 1.0


def test_common_misspelling_scores_high():
    """찌개/찌게 differ by one jamo out of ten, which is the whole point of
    decomposing before comparing."""
    assert similarity("김치찌개", "김치찌게") > 0.8


def test_substring_beats_unrelated():
    contained = similarity("김치찌개", "돼지고기김치찌개")
    unrelated = similarity("김치찌개", "고등어구이")
    assert contained > 0.7
    assert unrelated < 0.4
    assert contained > unrelated


def test_token_reorder_still_matches():
    assert similarity("훈제 오리", "오리 훈제") > 0.7


def test_short_fragment_does_not_dominate():
    """A 2-char fragment of a long name should not score as a confident match."""
    assert similarity("김", "김치볶음밥돌솥비빔밥") < 0.75


@pytest.mark.parametrize(
    "a,b",
    [("", "김치"), ("김치", ""), ("", "")],
)
def test_empty_inputs(a, b):
    assert similarity(a, b) == 0.0


def test_tokens_drop_noise():
    assert tokens("제육볶음 (국내산)") == ["제육볶음"]
