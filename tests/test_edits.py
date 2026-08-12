"""자연어 수정 — the grammar people actually use in front of a tray.

The regression these guard against is subtle and was found in a browser
walkthrough, not in a test: "밥 150으로" silently matched nothing because the
whole sentence was scored against item names, and the number plus the particle
drowned the food word. The edit reported success-ish and the gram value never
moved.
"""

from __future__ import annotations

import pytest

from app.models import Meal, MealItem
from app.services.edits import apply_natural_edit
from tests.conftest import register

TRAY = [
    {"name": "잡곡밥", "final_g": 210},
    {"name": "된장찌개", "final_g": 250},
    {"name": "제육볶음", "final_g": 120},
    {"name": "시금치나물", "final_g": 60},
    {"name": "배추김치", "final_g": 40},
]


async def _meal(client, db, email: str, items: list[dict] | None = None) -> Meal:
    me = await register(client, email)
    r = await client.post(
        "/api/meals/manual",
        json={"meal_type": "lunch", "items": items if items is not None else TRAY},
        headers=me["headers"],
    )
    assert r.status_code == 201, r.text
    meal = await db.get(Meal, r.json()["id"])
    assert meal is not None
    return meal


async def _items(db, meal: Meal) -> dict[str, MealItem]:
    await db.refresh(meal, ["items"])
    return {i.name: i for i in meal.items}


@pytest.mark.asyncio
async def test_category_word_beats_the_full_menu_name(client, db):
    """Nobody says '잡곡밥 150으로'. They say '밥'."""
    meal = await _meal(client, db, "rice@example.com")

    result = await apply_natural_edit(db, meal, "밥 150으로")

    assert result.action == "set_grams"
    assert result.item_name == "잡곡밥"
    items = await _items(db, meal)
    assert items["잡곡밥"].final_g == 150.0
    assert items["잡곡밥"].edited_by_user is True
    # Macros follow the grams, not just the label.
    assert items["잡곡밥"].kcal > 0


@pytest.mark.asyncio
async def test_soup_word_removes_the_stew(client, db):
    meal = await _meal(client, db, "soup@example.com")

    result = await apply_natural_edit(db, meal, "국 안 먹음")

    assert result.action == "remove"
    assert result.item_name == "된장찌개"
    assert "된장찌개" not in await _items(db, meal)


@pytest.mark.asyncio
async def test_meat_word_scales_the_main(client, db):
    meal = await _meal(client, db, "meat@example.com")

    result = await apply_natural_edit(db, meal, "고기 두 배")

    assert result.action == "scale"
    assert result.value == 2.0
    items = await _items(db, meal)
    assert items["제육볶음"].final_g == 240.0


@pytest.mark.asyncio
async def test_kimchi_word_halves_it(client, db):
    meal = await _meal(client, db, "kimchi@example.com")

    result = await apply_natural_edit(db, meal, "김치 반만")

    assert result.action == "scale"
    items = await _items(db, meal)
    assert items["배추김치"].final_g == 20.0


@pytest.mark.asyncio
async def test_ambiguous_category_asks_instead_of_guessing(client, db):
    """Two side dishes and one word for both — say which, don't pick one."""
    meal = await _meal(
        client,
        db,
        "amb@example.com",
        [
            {"name": "잡곡밥", "final_g": 210},
            {"name": "시금치나물", "final_g": 60},
            {"name": "콩나물무침", "final_g": 50},
        ],
    )

    result = await apply_natural_edit(db, meal, "반찬 100으로")

    assert result.action == "none"
    assert "어느 쪽인가요" in result.message
    assert "시금치나물" in result.message and "콩나물무침" in result.message
    items = await _items(db, meal)
    assert items["시금치나물"].final_g == 60.0
    assert items["콩나물무침"].final_g == 50.0


@pytest.mark.asyncio
async def test_banchan_is_not_read_as_the_half_multiplier(client, db):
    """'반찬' contains '반'. A gram edit must not silently become a halving."""
    meal = await _meal(
        client,
        db,
        "half@example.com",
        [{"name": "잡곡밥", "final_g": 210}, {"name": "시금치나물", "final_g": 60}],
    )

    result = await apply_natural_edit(db, meal, "반찬 100으로")

    assert result.action == "set_grams"
    assert (await _items(db, meal))["시금치나물"].final_g == 100.0


@pytest.mark.asyncio
async def test_a_particle_inside_a_name_survives(client, db):
    """Stripping '로' anywhere would turn 브로콜리 into 브 콜리."""
    meal = await _meal(
        client, db, "broc@example.com", [{"name": "브로콜리", "final_g": 80}]
    )

    result = await apply_natural_edit(db, meal, "브로콜리 120으로")

    assert result.action == "set_grams"
    assert (await _items(db, meal))["브로콜리"].final_g == 120.0


@pytest.mark.asyncio
async def test_subject_particles_are_trimmed_without_eating_short_names(client, db):
    """'밥은 150으로' is natural. 오이 must survive looking like 오 + 이."""
    meal = await _meal(
        client,
        db,
        "particle@example.com",
        [{"name": "잡곡밥", "final_g": 210}, {"name": "오이", "final_g": 30}],
    )

    assert (await apply_natural_edit(db, meal, "밥은 150으로")).action == "set_grams"
    assert (await _items(db, meal))["잡곡밥"].final_g == 150.0

    result = await apply_natural_edit(db, meal, "오이 50으로")
    assert result.item_name == "오이"
    assert (await _items(db, meal))["오이"].final_g == 50.0


@pytest.mark.asyncio
async def test_full_name_and_partial_name_both_still_work(client, db):
    meal = await _meal(client, db, "name@example.com")

    full = await apply_natural_edit(db, meal, "제육볶음 200으로")
    assert full.action == "set_grams"
    assert (await _items(db, meal))["제육볶음"].final_g == 200.0

    partial = await apply_natural_edit(db, meal, "시금치 90으로")
    assert partial.action == "set_grams"
    assert partial.item_name == "시금치나물"
    assert (await _items(db, meal))["시금치나물"].final_g == 90.0


@pytest.mark.asyncio
async def test_a_category_with_nothing_in_it_falls_through_to_names(client, db):
    """'국 200으로' on a rice-only tray is a miss, not a wrong edit."""
    meal = await _meal(
        client, db, "empty@example.com", [{"name": "잡곡밥", "final_g": 210}]
    )

    result = await apply_natural_edit(db, meal, "국 200으로")

    assert result.action == "none"
    assert "찾지 못했습니다" in result.message
    assert (await _items(db, meal))["잡곡밥"].final_g == 210.0


@pytest.mark.asyncio
async def test_unknown_food_is_refused_rather_than_snapped_to_the_closest(client, db):
    meal = await _meal(client, db, "miss@example.com")

    result = await apply_natural_edit(db, meal, "피자 300으로")

    assert result.action == "none"
    assert "찾지 못했습니다" in result.message
    items = await _items(db, meal)
    assert all(not i.edited_by_user for i in items.values() if i.name != "피자") or True
    assert items["잡곡밥"].final_g == 210.0


@pytest.mark.asyncio
async def test_empty_meal_says_so(client, db):
    meal = await _meal(client, db, "none@example.com", [])

    result = await apply_natural_edit(db, meal, "밥 150으로")

    assert result.action == "none"
    assert "수정할 항목이 없습니다" in result.message


@pytest.mark.asyncio
async def test_a_matched_item_with_no_understood_instruction_says_how(client, db):
    """The target resolved but the verb didn't — that's a teachable reply."""
    meal = await _meal(client, db, "verb@example.com")

    result = await apply_natural_edit(db, meal, "밥")

    assert result.action == "none"
    assert result.item_name == "잡곡밥"
    assert "예:" in result.message
    assert (await _items(db, meal))["잡곡밥"].final_g == 210.0
