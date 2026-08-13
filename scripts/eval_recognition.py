#!/usr/bin/env python3
"""인식 정확도 측정.

이 제품의 핵심 가설은 하나입니다 — **급식 식단표를 정답지로 주면, "무엇을
먹었나"라는 열린 문제가 "이 후보 중 무엇인가"라는 객관식이 되어 정확해진다.**
이 스크립트는 그 가설을 숫자로 만듭니다.

같은 사진을 두 번 돌립니다.

* ``menu``  — 식단표를 candidates로 준 객관식 모드
* ``open``  — 식단표 없이 연 인식 모드

둘의 차이가 이 앱이 존재할 이유입니다. 차이가 없으면 급식 엔진은 그냥 복잡한
장식이고, 로드맵을 다시 써야 합니다.

## 샘플 만들기

```
eval/samples/
  2026-08-13-lunch.jpg
  2026-08-13-lunch.json
```

JSON 형식:

```json
{
  "meal_type": "lunch",
  "menu": [
    {"name": "잡곡밥",   "category": "rice",   "standard_g": 210},
    {"name": "된장찌개", "category": "soup",   "standard_g": 250},
    {"name": "제육볶음", "category": "main",   "standard_g": 120}
  ],
  "truth": [
    {"name": "잡곡밥",   "grams": 180},
    {"name": "된장찌개", "grams": 200},
    {"name": "제육볶음", "grams": 140}
  ]
}
```

`truth`의 그램은 저울로 잰 값입니다. **눈대중으로 적으면 이 스크립트가 재는
것은 모델의 정확도가 아니라 여러분의 눈대중입니다.** 최소 30끼, 가능하면
서로 다른 식당 3곳 이상을 권합니다.

## 실행

```bash
export VISION_PROVIDER=anthropic ANTHROPIC_API_KEY=sk-ant-...
python scripts/eval_recognition.py                 # eval/samples 전체
python scripts/eval_recognition.py --mode menu     # 객관식만
python scripts/eval_recognition.py --repeat 3      # 같은 사진 3번 (분산 측정)
python scripts/eval_recognition.py --json out.json # 기계가 읽을 형식으로
```

프로바이더가 `stub`이면 결정적 더미 응답으로 도는데, 이건 정확도 측정이
아니라 **이 스크립트 자체가 맞게 도는지 확인하는 용도**입니다.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import statistics
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.config import settings  # noqa: E402
from app.models import FoodCategory  # noqa: E402
from app.services.korean import similarity  # noqa: E402
from app.services.nutrition import STANDARD_PORTION_G, guess_category  # noqa: E402
from app.services.recognition import aggregate_analyses  # noqa: E402
from app.vision import get_provider  # noqa: E402
from app.vision.base import ImagePayload, MenuCandidate, TrayRequest  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
DEFAULT_SAMPLES = REPO / "eval" / "samples"

# 이름이 이만큼 닮았으면 같은 음식으로 칩니다. 한글 메뉴명은 표기가 흔들리므로
# ("돼지고기김치찌개" vs "김치찌개") 완전 일치를 요구하면 재는 게 정확도가
# 아니라 표기 통일도가 됩니다.
NAME_MATCH = 0.62


# --------------------------------------------------------------------------
# 샘플
# --------------------------------------------------------------------------


@dataclass(slots=True)
class TruthItem:
    name: str
    grams: float


@dataclass(slots=True)
class Sample:
    id: str
    photo: Path
    meal_type: str
    menu: list[dict]
    truth: list[TruthItem]

    @classmethod
    def load(cls, photo: Path) -> Sample:
        meta_path = photo.with_suffix(".json")
        if not meta_path.exists():
            raise SystemExit(f"{photo.name}에 짝이 되는 {meta_path.name}이 없습니다.")
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        truth = [
            TruthItem(name=t["name"], grams=float(t["grams"]))
            for t in meta.get("truth", [])
        ]
        if not truth:
            raise SystemExit(f"{meta_path.name}에 truth가 비어 있습니다.")
        return cls(
            id=photo.stem,
            photo=photo,
            meal_type=meta.get("meal_type", "lunch"),
            menu=meta.get("menu", []),
            truth=truth,
        )


def load_samples(root: Path) -> list[Sample]:
    photos = sorted(
        p for p in root.glob("*") if p.suffix.lower() in {".jpg", ".jpeg", ".png"}
    )
    if not photos:
        raise SystemExit(
            f"{root}에 사진이 없습니다.\n"
            "사진과 같은 이름의 .json에 정답을 적어 두세요 "
            "(형식은 이 파일 맨 위 주석 참고)."
        )
    return [Sample.load(p) for p in photos]


# --------------------------------------------------------------------------
# 매칭과 지표
# --------------------------------------------------------------------------


@dataclass(slots=True)
class Matched:
    truth: TruthItem
    pred_name: str
    pred_grams: float
    category: str


@dataclass(slots=True)
class SampleResult:
    sample_id: str
    mode: str
    matched: list[Matched] = field(default_factory=list)
    missed: list[str] = field(default_factory=list)      # 정답에 있는데 못 찾음
    spurious: list[str] = field(default_factory=list)    # 없는데 찾아냄
    calls: int = 0
    error: str | None = None

    @property
    def recall(self) -> float:
        total = len(self.matched) + len(self.missed)
        return len(self.matched) / total if total else 0.0

    @property
    def precision(self) -> float:
        total = len(self.matched) + len(self.spurious)
        return len(self.matched) / total if total else 0.0


def match_items(
    truth: list[TruthItem], predicted: list[tuple[str, float, str]]
) -> tuple[list[Matched], list[str], list[str]]:
    """정답과 예측을 1:1로 붙입니다.

    유사도가 높은 쌍부터 욕심껏 붙입니다. 헝가리안까지 갈 만큼 항목이 많지
    않고(한 끼 3~6개), 이 문제에서는 결과가 사실상 같습니다.
    """
    pairs = sorted(
        (
            (similarity(t.name, p[0]), ti, pi)
            for ti, t in enumerate(truth)
            for pi, p in enumerate(predicted)
        ),
        key=lambda x: x[0],
        reverse=True,
    )

    used_t: set[int] = set()
    used_p: set[int] = set()
    matched: list[Matched] = []
    for score, ti, pi in pairs:
        if score < NAME_MATCH or ti in used_t or pi in used_p:
            continue
        used_t.add(ti)
        used_p.add(pi)
        name, grams, category = predicted[pi]
        matched.append(
            Matched(
                truth=truth[ti],
                pred_name=name,
                pred_grams=grams,
                category=category,
            )
        )

    missed = [t.name for i, t in enumerate(truth) if i not in used_t]
    spurious = [p[0] for i, p in enumerate(predicted) if i not in used_p]
    return matched, missed, spurious


@dataclass(slots=True)
class Report:
    mode: str
    results: list[SampleResult]

    def _all_matched(self) -> list[Matched]:
        return [m for r in self.results for m in r.matched]

    def summary(self) -> dict:
        ok = [r for r in self.results if r.error is None]
        matched = self._all_matched()

        gram_errors = [abs(m.pred_grams - m.truth.grams) for m in matched]
        gram_pcts = [
            abs(m.pred_grams - m.truth.grams) / m.truth.grams
            for m in matched
            if m.truth.grams > 0
        ]

        by_cat: dict[str, list[float]] = {}
        for m in matched:
            if m.truth.grams > 0:
                by_cat.setdefault(m.category, []).append(
                    (m.pred_grams - m.truth.grams) / m.truth.grams
                )

        return {
            "mode": self.mode,
            "samples": len(self.results),
            "failed": sum(1 for r in self.results if r.error),
            "recall": _mean([r.recall for r in ok]),
            "precision": _mean([r.precision for r in ok]),
            "f1": _f1(_mean([r.precision for r in ok]), _mean([r.recall for r in ok])),
            "matched_items": len(matched),
            "gram_mae": _mean(gram_errors) if gram_errors else None,
            "gram_mape": _mean(gram_pcts) if gram_pcts else None,
            "gram_within_20pct": (
                sum(1 for p in gram_pcts if p <= 0.20) / len(gram_pcts)
                if gram_pcts
                else 0.0
            ),
            "avg_calls": _mean([float(r.calls) for r in ok]),
            # 카테고리별 *부호 있는* 편향. 기름 흡수량을 과소추정하면 main이
            # 음수로 몰립니다 — 그때 보정계수를 손볼 근거가 됩니다.
            "bias_by_category": {
                cat: round(_mean(vals), 4) for cat, vals in sorted(by_cat.items())
            },
        }


def _mean(values: list[float]) -> float:
    return round(statistics.fmean(values), 4) if values else 0.0


def _f1(p: float, r: float) -> float:
    return round(2 * p * r / (p + r), 4) if (p + r) else 0.0


# --------------------------------------------------------------------------
# 실행
# --------------------------------------------------------------------------


async def run_sample(sample: Sample, mode: str, repeat: int) -> SampleResult:
    """한 샘플을 한 모드로 돌립니다. 서버 파이프라인과 같은 K회 + 중앙값."""
    result = SampleResult(sample_id=sample.id, mode=mode)

    candidates: list[MenuCandidate] = []
    if mode == "menu":
        if not sample.menu:
            result.error = "menu 모드인데 식단표가 비어 있습니다"
            return result
        for i, item in enumerate(sample.menu):
            category = FoodCategory(item.get("category", "main"))
            candidates.append(
                MenuCandidate(
                    menu_id=i + 1,
                    name=item["name"],
                    category=category,
                    standard_g=float(
                        item.get("standard_g")
                        or STANDARD_PORTION_G.get(category, 100.0)
                    ),
                )
            )

    image = ImagePayload(data=sample.photo.read_bytes(), media_type="image/jpeg")
    provider = get_provider()

    try:
        analyses = []
        for nonce in range(repeat):
            analyses.append(
                await provider.analyze_tray(
                    TrayRequest(
                        image=image,
                        candidates=candidates,
                        meal_type=sample.meal_type,
                        nonce=nonce,
                    )
                )
            )
    except Exception as exc:  # noqa: BLE001 - 한 장이 실패해도 나머지는 돈다
        result.error = f"{type(exc).__name__}: {exc}"
        return result

    result.calls = len(analyses)
    agg = aggregate_analyses(analyses)

    # 서버의 `_materialise_items`와 같은 식으로 그램을 만듭니다. 여기서 식이
    # 갈라지면 재는 값이 실제 앱이 보여주는 값과 달라집니다.
    #
    # 보정계수(calibration)는 곱하지 않습니다. 그건 사용자별로 학습되는 사후
    # 보정이라, 여기서 재려는 것은 보정 이전의 모델 자체입니다 —
    # 카테고리별 편향 출력이 곧 보정계수를 정할 근거가 됩니다.
    by_menu = {c.menu_id: c for c in candidates}
    predicted: list[tuple[str, float, str]] = []
    for item in agg.items:
        if item.menu_id is not None:
            candidate = by_menu.get(item.menu_id)
            if candidate is None:
                # 후보에 없는 id를 모델이 지어낸 경우. 서버도 버립니다.
                continue
            name = candidate.name
            category = candidate.category
            grams = candidate.standard_g * item.portion_ratio
        else:
            name = item.free_text or "미상"
            category = guess_category(name)
            grams = item.estimated_g or STANDARD_PORTION_G.get(category, 100.0)

        predicted.append((name, grams, category.value))

    matched, missed, spurious = match_items(sample.truth, predicted)
    result.matched = matched
    result.missed = missed
    result.spurious = spurious
    return result


async def main() -> int:
    parser = argparse.ArgumentParser(description="인식 정확도 측정")
    parser.add_argument("--samples", type=Path, default=DEFAULT_SAMPLES)
    parser.add_argument(
        "--mode",
        choices=["both", "menu", "open"],
        default="both",
        help="both면 같은 사진을 객관식/열린 인식 양쪽으로 돌려 비교합니다",
    )
    parser.add_argument(
        "--repeat",
        type=int,
        default=settings.recognition_k_cold,
        help="사진 한 장당 모델 호출 횟수 (서버 기본값과 같게 두세요)",
    )
    parser.add_argument("--json", type=Path, help="결과를 JSON으로 저장")
    args = parser.parse_args()

    samples = load_samples(args.samples)
    provider = get_provider()

    print(f"프로바이더: {provider.name}")
    if provider.name == "stub":
        print(
            "  ⚠ stub은 결정적 더미입니다. 이 숫자는 정확도가 아니라 "
            "스크립트가 도는지 확인하는 값입니다."
        )
    print(f"샘플 {len(samples)}개 · 사진당 {args.repeat}회 호출\n")

    modes = ["menu", "open"] if args.mode == "both" else [args.mode]
    reports: list[Report] = []

    for mode in modes:
        results = []
        for sample in samples:
            r = await run_sample(sample, mode, args.repeat)
            results.append(r)
            flag = "✗" if r.error else " "
            print(
                f"  {flag} [{mode:4}] {sample.id:28} "
                f"재현율 {r.recall:5.1%}  정밀도 {r.precision:5.1%}"
                + (f"  ({r.error})" if r.error else "")
            )
        reports.append(Report(mode=mode, results=results))
        print()

    print("=" * 72)
    summaries = [r.summary() for r in reports]
    for s in summaries:
        print(f"\n[{s['mode']}] 샘플 {s['samples']}개 (실패 {s['failed']})")
        print(f"  항목 재현율    {s['recall']:.1%}   (정답 중 찾아낸 비율)")
        print(f"  항목 정밀도    {s['precision']:.1%}   (찾아낸 것 중 맞은 비율)")
        print(f"  F1            {s['f1']:.3f}")
        if s["gram_mape"] is None:
            print("  중량          매칭된 항목이 없어 재지 못했습니다")
        else:
            print(f"  중량 MAE      {s['gram_mae']:.1f}g")
            print(f"  중량 MAPE     {s['gram_mape']:.1%}")
            print(f"  ±20% 이내     {s['gram_within_20pct']:.1%}")
        print(f"  평균 호출     {s['avg_calls']:.1f}회")
        if s["bias_by_category"]:
            print("  카테고리 편향 (+면 과대추정):")
            for cat, bias in s["bias_by_category"].items():
                print(f"    {cat:8} {bias:+.1%}")

    # 이 제품이 존재할 이유를 한 줄로.
    if len(summaries) == 2 and not any(s["failed"] for s in summaries):
        menu, open_ = summaries[0], summaries[1]
        print("\n" + "=" * 72)
        print("식단표가 실제로 도움이 되는가")
        print(f"  F1        {open_['f1']:.3f} → {menu['f1']:.3f} "
              f"({menu['f1'] - open_['f1']:+.3f})")
        if open_["gram_mape"] is not None and menu["gram_mape"] is not None:
            print(f"  중량 MAPE {open_['gram_mape']:.1%} → {menu['gram_mape']:.1%} "
                  f"({menu['gram_mape'] - open_['gram_mape']:+.1%})")
        else:
            print("  중량 MAPE 한쪽에서 매칭된 항목이 없어 비교하지 않습니다")
        if menu["f1"] <= open_["f1"]:
            print("\n  ⚠ 식단표가 F1을 올리지 못했습니다. 이 제품의 전제가")
            print("    흔들리는 결과이므로, 다듬기 전에 원인부터 보세요.")

    failed_total = sum(s["failed"] for s in summaries)
    if failed_total:
        print("\n" + "=" * 72)
        print(f"⚠ {failed_total}건이 실패했습니다. 위 숫자는 성립하지 않습니다 —")
        print("  0%는 '못 맞혔다'가 아니라 '재지 못했다'입니다.")

    if args.json:
        args.json.write_text(
            json.dumps(
                {
                    "provider": provider.name,
                    "repeat": args.repeat,
                    "summaries": summaries,
                    "per_sample": [
                        {
                            "id": r.sample_id,
                            "mode": r.mode,
                            "recall": r.recall,
                            "precision": r.precision,
                            "missed": r.missed,
                            "spurious": r.spurious,
                            "error": r.error,
                        }
                        for rep in reports
                        for r in rep.results
                    ],
                },
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )
        print(f"\n{args.json}에 저장했습니다.")

    return 0


if __name__ == "__main__":
    os.environ.setdefault("SECRET_KEY", "eval-only")
    raise SystemExit(asyncio.run(main()))
