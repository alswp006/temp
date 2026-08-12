"""Adaptive TDEE maths and the goal-setting safety guards."""

from __future__ import annotations

import pytest

from app.errors import SafetyGuardError
from app.models import Sex
from app.services.targets import (
    KCAL_PER_KG_FAT,
    assert_safe_target,
    bmr_mifflin,
    clamp_tdee,
    estimate_tdee_from_week,
    evaluate_target_safety,
    ewma_trend,
    protein_target,
    smooth_tdee,
)


def test_ewma_first_reading_is_itself():
    assert ewma_trend(None, 80.0) == 80.0


def test_ewma_smooths_a_spike():
    """A one-day 2kg jump should move the trend by ~0.2kg at α=0.1, not 2kg."""
    trend = ewma_trend(80.0, 82.0, alpha=0.1)
    assert trend == pytest.approx(80.2, abs=0.01)


def test_ewma_converges_on_a_sustained_change():
    trend = 80.0
    for _ in range(60):
        trend = ewma_trend(trend, 78.0, alpha=0.1)
    assert trend == pytest.approx(78.0, abs=0.05)


def test_bmr_male_vs_female_constant():
    male = bmr_mifflin(weight_kg=70, height_cm=175, age=30, sex=Sex.MALE)
    female = bmr_mifflin(weight_kg=70, height_cm=175, age=30, sex=Sex.FEMALE)
    assert male - female == pytest.approx(166.0)
    # Sanity: a 70kg/175cm/30yo man is around 1650 kcal.
    assert 1600 < male < 1720


def test_unspecified_sex_sits_between():
    kwargs = dict(weight_kg=70, height_cm=175, age=30)
    mid = bmr_mifflin(sex=Sex.UNSPECIFIED, **kwargs)
    assert (
        bmr_mifflin(sex=Sex.FEMALE, **kwargs)
        < mid
        < bmr_mifflin(sex=Sex.MALE, **kwargs)
    )


def test_tdee_backcalculation_holding_steady():
    """No weight change means intake equals expenditure."""
    assert estimate_tdee_from_week(
        avg_intake_kcal=2200, weekly_weight_change_kg=0.0
    ) == pytest.approx(2200)


def test_tdee_backcalculation_losing_weight():
    """Losing 0.5kg/week on 2000 kcal implies burning ~2550."""
    est = estimate_tdee_from_week(
        avg_intake_kcal=2000, weekly_weight_change_kg=-0.5
    )
    assert est == pytest.approx(2000 + 0.5 * KCAL_PER_KG_FAT / 7, abs=1)
    assert est > 2000


def test_smooth_weights_recent_week_most():
    # Recent 2500, then 2000, 2000 → weighted toward 2500.
    smoothed = smooth_tdee([2500, 2000, 2000])
    assert 2200 < smoothed < 2300
    assert smoothed == pytest.approx(2500 * 0.5 + 2000 * 0.3 + 2000 * 0.2)


def test_smooth_handles_partial_history():
    assert smooth_tdee([2400]) == pytest.approx(2400)
    assert smooth_tdee([]) == 0.0


def test_clamp_limits_weekly_swing_to_15_percent():
    assert clamp_tdee(4000, 2000) == pytest.approx(2300)
    assert clamp_tdee(1000, 2000) == pytest.approx(1700)
    assert clamp_tdee(2100, 2000) == pytest.approx(2100)  # inside the band


def test_clamp_noop_without_history():
    assert clamp_tdee(2400, None) == 2400


def test_protein_target_scales_with_weight():
    assert protein_target(70) == 126.0  # 70 * 1.8


# --- safety guards --------------------------------------------------------


def _verdict(target_kcal: float, **over):
    kwargs = dict(
        target_kcal=target_kcal,
        est_tdee=2400.0,
        weight_kg=70.0,
        height_cm=175.0,
        age=30,
        sex=Sex.MALE,
    )
    kwargs.update(over)
    return evaluate_target_safety(**kwargs)


def test_target_below_bmr_is_rejected():
    verdict = _verdict(1200)
    assert verdict.ok is False
    assert "기초대사량" in (verdict.reason or "")
    with pytest.raises(SafetyGuardError):
        assert_safe_target(verdict)


def test_reasonable_deficit_passes_clean():
    verdict = _verdict(2000)
    assert verdict.ok is True
    assert verdict.needs_confirmation is False
    assert_safe_target(verdict)  # does not raise


def test_moderate_deficit_needs_no_confirmation():
    verdict = _verdict(1700)  # 700 kcal/day ≈ 0.64 kg/week, under 1% of 70kg
    assert verdict.ok is True
    assert verdict.needs_confirmation is False
    assert verdict.weekly_loss_kg == pytest.approx(0.64, abs=0.02)


def test_aggressive_deficit_requires_confirmation_but_is_not_blocked():
    """A >1%/week loss rate is storable — it just needs the mentee to say yes.

    Needs a heavier body to isolate: for a 70kg person the BMR floor fires
    before the rate cap ever does, which is the guards composing correctly.
    """
    verdict = evaluate_target_safety(
        target_kcal=2000,
        est_tdee=3200.0,
        weight_kg=100.0,
        height_cm=180.0,
        age=30,
        sex=Sex.MALE,
    )
    assert verdict.ok is True                      # 2000 > BMR 1980
    assert verdict.needs_confirmation is True      # 1.09 kg/week > 1% of 100kg
    assert verdict.weekly_loss_kg > 1.0
    assert_safe_target(verdict)                    # not blocked, just flagged


def test_bmr_floor_fires_before_the_rate_cap_for_a_light_body():
    """Documents the interaction: an aggressive target for a 70kg person is
    rejected outright rather than merely flagged."""
    verdict = _verdict(1600)
    assert verdict.ok is False
    assert verdict.needs_confirmation is False


def test_missing_body_data_does_not_block():
    verdict = _verdict(1000, height_cm=None)
    assert verdict.ok is True
    assert verdict.bmr == 0.0
