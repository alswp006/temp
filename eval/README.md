# 인식 정확도 측정

이 폴더는 **이 제품의 핵심 가설을 숫자로 만드는 곳**입니다.

> 급식 식단표를 정답지로 주면, "무엇을 먹었나"라는 열린 문제가 "이 후보 중
> 무엇인가"라는 객관식이 되어 정확해진다.

이 가설이 참이 아니면 급식 엔진은 복잡한 장식이고, 로드맵을 다시 써야 합니다.
**아직 실제 모델로 한 번도 검증되지 않았습니다.**

## 필요한 것

1. **API 키** — `ANTHROPIC_API_KEY` 또는 `GEMINI_API_KEY`
2. **정답이 붙은 식판 사진** — 아래 형식

## 샘플 만들기

사진과 같은 이름의 `.json`을 나란히 둡니다.

```
eval/samples/
  2026-08-13-lunch.jpg
  2026-08-13-lunch.json
```

```json
{
  "meal_type": "lunch",
  "menu": [
    {"name": "잡곡밥",   "category": "rice", "standard_g": 210},
    {"name": "된장찌개", "category": "soup", "standard_g": 250},
    {"name": "제육볶음", "category": "main", "standard_g": 120}
  ],
  "truth": [
    {"name": "잡곡밥",   "grams": 180},
    {"name": "된장찌개", "grams": 200},
    {"name": "제육볶음", "grams": 140}
  ]
}
```

`category`는 `rice / soup / main / side / kimchi / dessert` 중 하나입니다.

### 정답을 어떻게 만드나

**`truth`의 그램은 저울로 잰 값이어야 합니다.** 눈대중으로 적으면 이 스크립트가
재는 것은 모델의 정확도가 아니라 여러분의 눈대중입니다. 주방용 저울 하나면
됩니다 — 담기 전 빈 그릇을 영점으로 두고 담은 뒤 무게를 적습니다.

표본은 **최소 30끼**, 가능하면 **식당 3곳 이상**을 권합니다. 한 식당만 찍으면
그 식당의 조명과 식판 모양에만 맞는 숫자가 나옵니다.

## 돌리기

```bash
export VISION_PROVIDER=anthropic
export ANTHROPIC_API_KEY=sk-ant-...

python scripts/eval_recognition.py                  # 객관식 vs 열린 인식 비교
python scripts/eval_recognition.py --mode menu      # 객관식만
python scripts/eval_recognition.py --repeat 1       # 호출 1회 (비용 절감)
python scripts/eval_recognition.py --json out.json  # 기계가 읽을 형식
```

기본 `--repeat`은 서버의 콜드 K와 같은 5회입니다. 사진 30장 x 5회 x 2모드 =
300회 호출이니, 비용이 걱정되면 `--repeat 1`로 먼저 감을 잡으세요.

## 읽는 법

| 지표 | 뜻 | 이게 나쁘면 |
|---|---|---|
| 항목 재현율 | 실제로 먹은 것 중 찾아낸 비율 | 모델이 반찬을 놓칩니다 — 후보 목록이나 프롬프트 문제 |
| 항목 정밀도 | 찾아낸 것 중 실제로 있던 비율 | 없는 걸 지어냅니다 — detect-rate 게이팅을 조이세요 |
| 중량 MAPE | 그램 오차율 | 표준량(`standard_g`)이 실제 배식량과 다릅니다 |
| ±20% 이내 | 실용적으로 쓸 만한 비율 | 사용자가 매번 손으로 고치게 됩니다 |
| 카테고리 편향 | +면 과대추정 | **보정계수(calibration)를 정할 근거입니다** |

카테고리 편향이 `main -15%`처럼 한쪽으로 몰리면, 그게 기름 흡수량 과소추정
같은 계통 오차입니다. 로드맵의 리스크 표에 있는 항목이고, 보정계수로 잡습니다.

## 자체 확인

`_selftest-lunch.*`는 stub 프로바이더로 **스크립트 자체가 맞게 도는지** 보는
샘플입니다. 정확도 측정이 아닙니다.

```bash
VISION_PROVIDER=stub python scripts/eval_recognition.py
```

정답을 표준량의 90%로 넣어 두었으므로 카테고리 편향이 `+10%` 근처로 나와야
합니다. 그렇지 않으면 지표 계산이 깨진 것입니다.
