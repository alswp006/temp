"""The recognition pipeline.

    photo
      └ 촬영 시각 → 끼니 판정
      └ 식당 + 날짜 + 끼니 → 식단표 조회
           ├ 있음 → 메뉴 후보 N개를 프롬프트에 주입 (객관식 모드)
           └ 없음 → 열린 인식 모드 (정확도 낮음을 결과에 표시)
      └ 비전 모델 K회 병렬 호출
      └ 항목별 portion_ratio 중앙값 + 등장 빈도로 신뢰도 계산
      └ 메뉴 → food 매칭 → 100g당 영양소 × 실제 중량
      └ 개인 보정계수 적용
      └ 저장

K is not a constant. The first person to shoot a given (canteen, date, meal)
slot pays the full K=5 and leaves behind a baseline interpretation; everyone
after them pays K=1 and only escalates when their reading disagrees with it.
That is what makes per-user cost fall as a canteen fills up, and it is why the
architecture is here from day one rather than bolted on at launch.
"""

from __future__ import annotations

import asyncio
import logging
import statistics
from dataclasses import dataclass, field

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.core.timeutil import utcnow
from app.errors import UpstreamError
from app.models import (
    Calibration,
    Food,
    FoodCategory,
    Meal,
    MealItem,
    MealStatus,
    MenuItem,
    MenuPlan,
    RecognitionBaseline,
    User,
)
from app.services import nutrition
from app.services.korean import normalize
from app.services.photos import delete_photo, read_photo
from app.vision import get_provider
from app.vision.base import (
    ImagePayload,
    MenuCandidate,
    TrayAnalysis,
    TrayRequest,
)

log = logging.getLogger(__name__)


# --------------------------------------------------------------------------
# Aggregation
# --------------------------------------------------------------------------


@dataclass(slots=True)
class AggregatedItem:
    menu_id: int | None
    free_text: str | None
    portion_ratio: float
    estimated_g: float | None
    confidence: float
    detect_rate: float


@dataclass(slots=True)
class Aggregate:
    items: list[AggregatedItem] = field(default_factory=list)
    calls: int = 0
    tray_detected: bool = False

    def by_menu_id(self) -> dict[int, AggregatedItem]:
        return {i.menu_id: i for i in self.items if i.menu_id is not None}


def _median(values: list[float]) -> float:
    return float(statistics.median(values)) if values else 0.0


def aggregate_analyses(analyses: list[TrayAnalysis]) -> Aggregate:
    """Combine K independent readings of the same photo.

    Median rather than mean: one call mistaking a half scoop for a double
    scoop should not drag the answer, and with K=5 the median is immune to two
    such outliers.
    """
    k = len(analyses)
    if not k:
        return Aggregate()

    menu_ratios: dict[int, list[float]] = {}
    menu_conf: dict[int, list[float]] = {}
    free_grams: dict[str, list[float]] = {}
    free_conf: dict[str, list[float]] = {}
    free_label: dict[str, str] = {}

    for analysis in analyses:
        seen_menu: set[int] = set()
        seen_free: set[str] = set()
        for item in analysis.items:
            if item.menu_id is not None:
                if item.menu_id in seen_menu:
                    continue
                seen_menu.add(item.menu_id)
                menu_ratios.setdefault(item.menu_id, []).append(
                    item.portion_ratio if item.portion_ratio is not None else 1.0
                )
                menu_conf.setdefault(item.menu_id, []).append(item.confidence)
            elif item.free_text:
                key = normalize(item.free_text)
                if not key or key in seen_free:
                    continue
                seen_free.add(key)
                free_label.setdefault(key, item.free_text.strip())
                free_grams.setdefault(key, []).append(item.estimated_g or 0.0)
                free_conf.setdefault(key, []).append(item.confidence)

    # With a single call there is no consensus to measure, so keep everything.
    # With three or more, an item that only half the calls saw is noise.
    min_detect = 0.0 if k < 3 else 0.5

    items: list[AggregatedItem] = []
    for menu_id, ratios in menu_ratios.items():
        detect_rate = len(ratios) / k
        if detect_rate < min_detect:
            continue
        confs = menu_conf.get(menu_id, [0.5])
        items.append(
            AggregatedItem(
                menu_id=menu_id,
                free_text=None,
                portion_ratio=round(_median(ratios), 3),
                estimated_g=None,
                confidence=round(_median(confs) * detect_rate, 3),
                detect_rate=round(detect_rate, 3),
            )
        )

    for key, grams in free_grams.items():
        detect_rate = len(grams) / k
        if detect_rate < min_detect:
            continue
        confs = free_conf.get(key, [0.4])
        items.append(
            AggregatedItem(
                menu_id=None,
                free_text=free_label[key],
                portion_ratio=1.0,
                estimated_g=round(_median(grams), 1) or None,
                confidence=round(_median(confs) * detect_rate, 3),
                detect_rate=round(detect_rate, 3),
            )
        )

    return Aggregate(
        items=items,
        calls=k,
        tray_detected=any(a.tray_detected for a in analyses),
    )


# --------------------------------------------------------------------------
# Call policy
# --------------------------------------------------------------------------


@dataclass(slots=True)
class CallPolicy:
    k_cold: int = settings.recognition_k_cold
    k_warm: int = settings.recognition_k_warm
    k_escalate: int = settings.recognition_k_escalate
    tolerance: float = settings.recognition_agreement_tolerance

    def initial_k(self, *, has_baseline: bool) -> int:
        return self.k_warm if has_baseline else self.k_cold

    def disagrees(
        self, agg: Aggregate, baseline: dict[int, RecognitionBaseline]
    ) -> bool:
        """Does this warm reading contradict the slot's established one?

        Two ways to disagree: a portion that is off by more than the tolerance,
        or an item the baseline says is reliably present that this call missed
        entirely (and vice versa).
        """
        if not baseline:
            return False
        detected = agg.by_menu_id()

        for menu_id, item in detected.items():
            base = baseline.get(menu_id)
            if base is None:
                # Something the baseline has never seen in this slot.
                return True
            if abs(item.portion_ratio - base.portion_ratio) > self.tolerance:
                return True

        for menu_id, base in baseline.items():
            if base.detect_rate >= 0.8 and menu_id not in detected:
                return True

        return False


# --------------------------------------------------------------------------
# Pipeline
# --------------------------------------------------------------------------


async def _load_candidates(
    db: AsyncSession, meal: Meal
) -> tuple[MenuPlan | None, list[MenuItem]]:
    if meal.canteen_id is None:
        return None, []
    plan = (
        await db.execute(
            select(MenuPlan).where(
                MenuPlan.canteen_id == meal.canteen_id,
                MenuPlan.date == meal.local_date,
                MenuPlan.meal_type == meal.meal_type,
            )
        )
    ).scalar_one_or_none()
    if plan is None:
        return None, []
    items = (
        await db.execute(
            select(MenuItem)
            .where(MenuItem.menu_plan_id == plan.id)
            .order_by(MenuItem.position)
        )
    ).scalars().all()
    return plan, list(items)


async def _load_baseline(
    db: AsyncSession, meal: Meal
) -> dict[int, RecognitionBaseline]:
    if meal.canteen_id is None:
        return {}
    rows = (
        await db.execute(
            select(RecognitionBaseline).where(
                RecognitionBaseline.canteen_id == meal.canteen_id,
                RecognitionBaseline.date == meal.local_date,
                RecognitionBaseline.meal_type == meal.meal_type,
            )
        )
    ).scalars().all()
    return {r.menu_item_id: r for r in rows}


async def _update_baseline(
    db: AsyncSession,
    meal: Meal,
    agg: Aggregate,
    existing: dict[int, RecognitionBaseline],
) -> None:
    """Running mean, weighted by how many samples each side represents."""
    if meal.canteen_id is None:
        return
    for item in agg.items:
        if item.menu_id is None:
            continue
        row = existing.get(item.menu_id)
        if row is None:
            db.add(
                RecognitionBaseline(
                    canteen_id=meal.canteen_id,
                    date=meal.local_date,
                    meal_type=meal.meal_type,
                    menu_item_id=item.menu_id,
                    portion_ratio=item.portion_ratio,
                    detect_rate=item.detect_rate,
                    sample_n=1,
                )
            )
        else:
            n = row.sample_n
            row.portion_ratio = round(
                (row.portion_ratio * n + item.portion_ratio) / (n + 1), 3
            )
            row.detect_rate = round((row.detect_rate * n + item.detect_rate) / (n + 1), 3)
            row.sample_n = n + 1


async def _calibration_map(db: AsyncSession, user_id: int) -> dict[FoodCategory, float]:
    rows = (
        await db.execute(select(Calibration).where(Calibration.user_id == user_id))
    ).scalars().all()
    return {r.category: r.multiplier for r in rows}


async def _run_calls(req_factory, k: int, offset: int = 0) -> list[TrayAnalysis]:
    """Fire K calls concurrently; tolerate partial failure.

    One provider hiccup out of five should degrade the estimate, not lose the
    meal. Only a total wipe-out raises.
    """
    provider = get_provider()
    tasks = [provider.analyze_tray(req_factory(offset + i)) for i in range(k)]
    settled = await asyncio.gather(*tasks, return_exceptions=True)

    analyses: list[TrayAnalysis] = []
    errors: list[BaseException] = []
    for outcome in settled:
        if isinstance(outcome, BaseException):
            errors.append(outcome)
        else:
            analyses.append(outcome)

    if not analyses:
        raise UpstreamError(
            f"비전 모델 호출이 모두 실패했습니다: {errors[0] if errors else 'unknown'}"
        )
    if errors:
        log.warning("K회 호출 중 %d회 실패 (성공 %d회)", len(errors), len(analyses))
    return analyses


async def analyze_meal(db: AsyncSession, meal: Meal) -> Meal:
    """Run the full pipeline for one pending meal and persist the result."""
    user = await db.get(User, meal.user_id)
    if user is None:  # pragma: no cover - FK guarantees this
        raise UpstreamError("사용자를 찾을 수 없습니다.")

    if not meal.photo_path:
        raise UpstreamError("사진이 없는 식사입니다.")
    photo_bytes = read_photo(meal.photo_path)
    if photo_bytes is None:
        raise UpstreamError("사진 파일을 찾을 수 없습니다.")

    meal.status = MealStatus.ANALYZING
    await db.flush()

    plan, menu_items = await _load_candidates(db, meal)
    meal.open_mode = not menu_items

    candidates = [
        MenuCandidate(
            menu_id=mi.id,
            name=mi.name,
            category=mi.category,
            standard_g=mi.standard_g
            or nutrition.STANDARD_PORTION_G.get(mi.category, 100.0),
        )
        for mi in menu_items
    ]
    image = ImagePayload(data=photo_bytes, media_type="image/jpeg")

    def make_request(nonce: int) -> TrayRequest:
        return TrayRequest(
            image=image,
            candidates=candidates,
            meal_type=meal.meal_type,
            nonce=nonce,
        )

    baseline = await _load_baseline(db, meal)
    policy = CallPolicy()
    k = policy.initial_k(has_baseline=bool(baseline))

    analyses = await _run_calls(make_request, k)
    agg = aggregate_analyses(analyses)
    escalated = False

    if baseline and policy.disagrees(agg, baseline):
        escalated = True
        extra = await _run_calls(make_request, policy.k_escalate, offset=k)
        analyses.extend(extra)
        agg = aggregate_analyses(analyses)

    meal.calls_used = len(analyses)
    meal.cache_hit = bool(baseline) and not escalated

    await _update_baseline(db, meal, agg, baseline)
    await _materialise_items(db, meal, agg, menu_items, user)

    meal.status = MealStatus.READY
    meal.error = None
    meal.updated_at = utcnow()

    if settings.discard_photo_after_analysis:
        delete_photo(meal.photo_path)
        meal.photo_path = None

    log.info(
        "meal %s analysed: %d items, %d calls, cache_hit=%s, open_mode=%s",
        meal.id,
        len(agg.items),
        meal.calls_used,
        meal.cache_hit,
        meal.open_mode,
    )
    return meal


async def _materialise_items(
    db: AsyncSession,
    meal: Meal,
    agg: Aggregate,
    menu_items: list[MenuItem],
    user: User,
) -> None:
    """Aggregated ratios → grams → macros → MealItem rows.

    User edits are sacred: an item the user has already corrected is left
    alone, so re-running analysis never overwrites a manual fix.
    """
    calibration = await _calibration_map(db, user.id)
    by_id = {mi.id: mi for mi in menu_items}

    existing = (
        await db.execute(select(MealItem).where(MealItem.meal_id == meal.id))
    ).scalars().all()
    edited = {i.id for i in existing if i.edited_by_user}
    for item in existing:
        if item.id not in edited:
            await db.delete(item)
    await db.flush()

    for agg_item in agg.items:
        if agg_item.menu_id is not None:
            menu_item = by_id.get(agg_item.menu_id)
            if menu_item is None:
                continue  # model hallucinated an id outside the candidate list
            category = menu_item.category
            standard_g = menu_item.standard_g or nutrition.STANDARD_PORTION_G.get(
                category, 100.0
            )
            grams = standard_g * agg_item.portion_ratio
            food = (
                await db.get(Food, menu_item.food_id)
                if menu_item.food_id
                else await nutrition.resolve_food(db, menu_item.name)
            )
            name = menu_item.name
            menu_item_id = menu_item.id
            fallback_kcal = (
                menu_item.kcal_per_serving * agg_item.portion_ratio
                if menu_item.kcal_per_serving
                else None
            )
        else:
            name = agg_item.free_text or "미상"
            category = nutrition.guess_category(name)
            food = await nutrition.resolve_food(db, name)
            grams = agg_item.estimated_g or (
                food.default_serving_g
                if food
                else nutrition.STANDARD_PORTION_G.get(category, 100.0)
            )
            menu_item_id = None
            fallback_kcal = None

        multiplier = calibration.get(category, 1.0)
        final_g = round(grams * multiplier, 1)

        macros = nutrition.macros_for(food, final_g)
        if food is None and fallback_kcal is not None:
            # 식단표에 열량이 적혀 있으면 매칭 실패해도 그 값을 쓴다.
            macros["kcal"] = round(fallback_kcal, 1)

        db.add(
            MealItem(
                meal_id=meal.id,
                menu_item_id=menu_item_id,
                food_id=food.id if food else None,
                name=name,
                category=category,
                portion_ratio=agg_item.portion_ratio,
                final_g=final_g,
                kcal=macros["kcal"],
                carb_g=macros["carb_g"],
                protein_g=macros["protein_g"],
                fat_g=macros["fat_g"],
                confidence=agg_item.confidence,
                edited_by_user=False,
            )
        )
    await db.flush()


async def recompute_meal_item(
    db: AsyncSession, item: MealItem, *, grams: float | None = None
) -> MealItem:
    """Recalculate macros after a manual edit."""
    if grams is not None:
        item.final_g = round(grams, 1)
    food = await db.get(Food, item.food_id) if item.food_id else None
    if food is None:
        food = await nutrition.resolve_food(db, item.name)
        if food:
            item.food_id = food.id
    macros = nutrition.macros_for(food, item.final_g)
    item.kcal = macros["kcal"]
    item.carb_g = macros["carb_g"]
    item.protein_g = macros["protein_g"]
    item.fat_g = macros["fat_g"]
    item.edited_by_user = True
    item.confidence = 1.0
    return item
