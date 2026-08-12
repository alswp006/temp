"""K-call aggregation and the cost-saving call policy."""

from __future__ import annotations

import pytest

from app.models import RecognitionBaseline
from app.services.recognition import (
    Aggregate,
    CallPolicy,
    aggregate_analyses,
)
from app.vision.base import DetectedItem, TrayAnalysis


def analysis(*items, tray=True) -> TrayAnalysis:
    return TrayAnalysis(items=list(items), tray_detected=tray)


def item(menu_id=None, ratio=None, free_text=None, grams=None, conf=0.9):
    return DetectedItem(
        menu_id=menu_id,
        portion_ratio=ratio,
        free_text=free_text,
        estimated_g=grams,
        confidence=conf,
    )


def test_median_ignores_a_single_outlier():
    """One call reading a double portion should not move the answer."""
    analyses = [
        analysis(item(1, 1.0)),
        analysis(item(1, 1.0)),
        analysis(item(1, 3.0)),  # outlier
        analysis(item(1, 1.0)),
        analysis(item(1, 1.25)),
    ]
    agg = aggregate_analyses(analyses)
    assert len(agg.items) == 1
    assert agg.items[0].portion_ratio == 1.0


def test_item_seen_by_a_minority_is_dropped_at_high_k():
    analyses = [
        analysis(item(1, 1.0), item(2, 1.0)),
        analysis(item(1, 1.0)),
        analysis(item(1, 1.0)),
        analysis(item(1, 1.0)),
        analysis(item(1, 1.0)),
    ]
    agg = aggregate_analyses(analyses)
    assert {i.menu_id for i in agg.items} == {1}


def test_item_seen_by_a_majority_survives():
    analyses = [
        analysis(item(1, 1.0), item(2, 0.5)),
        analysis(item(1, 1.0), item(2, 0.5)),
        analysis(item(1, 1.0), item(2, 0.75)),
        analysis(item(1, 1.0)),
        analysis(item(1, 1.0)),
    ]
    agg = aggregate_analyses(analyses)
    by_id = agg.by_menu_id()
    assert set(by_id) == {1, 2}
    assert by_id[2].detect_rate == pytest.approx(0.6)
    assert by_id[2].portion_ratio == 0.5


def test_single_call_keeps_everything():
    """With K=1 there is no consensus to measure, so nothing is discarded."""
    agg = aggregate_analyses([analysis(item(1, 1.0), item(2, 0.5))])
    assert len(agg.items) == 2


def test_confidence_is_discounted_by_detection_rate():
    analyses = [
        analysis(item(1, 1.0, conf=0.9)),
        analysis(item(1, 1.0, conf=0.9)),
        analysis(item(1, 1.0, conf=0.9)),
        analysis(),
        analysis(),
    ]
    agg = aggregate_analyses(analyses)
    assert agg.items[0].detect_rate == pytest.approx(0.6)
    assert agg.items[0].confidence == pytest.approx(0.54, abs=0.01)


def test_free_text_items_aggregate_by_normalised_name():
    analyses = [
        analysis(item(free_text="요구르트", grams=65)),
        analysis(item(free_text="요구르트 ", grams=70)),
        analysis(item(free_text="요구르트", grams=65)),
    ]
    agg = aggregate_analyses(analyses)
    assert len(agg.items) == 1
    assert agg.items[0].estimated_g == 65.0


def test_duplicate_items_within_one_call_counted_once():
    """A model listing the same menu twice must not inflate the detect rate."""
    agg = aggregate_analyses([analysis(item(1, 1.0), item(1, 2.0))])
    assert len(agg.items) == 1
    assert agg.items[0].portion_ratio == 1.0


def test_empty_input():
    assert aggregate_analyses([]).items == []


# --- call policy ----------------------------------------------------------


def baseline(menu_id: int, ratio: float, detect: float = 1.0):
    return RecognitionBaseline(
        canteen_id=1,
        date=None,
        meal_type=None,
        menu_item_id=menu_id,
        portion_ratio=ratio,
        detect_rate=detect,
        sample_n=1,
    )


def test_cold_slot_pays_full_k():
    policy = CallPolicy(k_cold=5, k_warm=1)
    assert policy.initial_k(has_baseline=False) == 5


def test_warm_slot_pays_one_call():
    """This is the mechanism that makes per-user cost fall as a canteen fills."""
    policy = CallPolicy(k_cold=5, k_warm=1)
    assert policy.initial_k(has_baseline=True) == 1


def test_agreement_does_not_escalate():
    policy = CallPolicy(tolerance=0.35)
    agg = Aggregate(items=[], calls=1)
    from app.services.recognition import AggregatedItem

    agg.items = [AggregatedItem(1, None, 1.0, None, 0.9, 1.0)]
    assert policy.disagrees(agg, {1: baseline(1, 1.1)}) is False


def test_portion_far_from_baseline_escalates():
    from app.services.recognition import AggregatedItem

    policy = CallPolicy(tolerance=0.35)
    agg = Aggregate(items=[AggregatedItem(1, None, 2.0, None, 0.9, 1.0)], calls=1)
    assert policy.disagrees(agg, {1: baseline(1, 1.0)}) is True


def test_unexpected_item_escalates():
    from app.services.recognition import AggregatedItem

    policy = CallPolicy()
    agg = Aggregate(items=[AggregatedItem(9, None, 1.0, None, 0.9, 1.0)], calls=1)
    assert policy.disagrees(agg, {1: baseline(1, 1.0)}) is True


def test_missing_reliable_item_escalates():
    """The baseline says this menu is always on the tray; this call missed it."""
    policy = CallPolicy()
    agg = Aggregate(items=[], calls=1)
    assert policy.disagrees(agg, {1: baseline(1, 1.0, detect=1.0)}) is True


def test_missing_unreliable_item_does_not_escalate():
    policy = CallPolicy()
    agg = Aggregate(items=[], calls=1)
    assert policy.disagrees(agg, {1: baseline(1, 1.0, detect=0.4)}) is False


def test_no_baseline_never_escalates():
    policy = CallPolicy()
    assert policy.disagrees(Aggregate(), {}) is False
