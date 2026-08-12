# API 레퍼런스

전체 스키마는 서버를 띄우고 `/docs` (Swagger) 또는 `/redoc`에서 볼 수 있습니다.
이 문서는 흐름과 의도를 설명합니다.

베이스 경로: `/api`

## 인증

두 종류의 자격 증명이 있습니다.

| 종류 | 형태 | 용도 |
|---|---|---|
| 액세스 토큰 | JWT, 기본 14일 | PWA |
| 인제스트 토큰 | `sk_<prefix>_<secret>` | iOS 단축어, 텔레그램 브리지 |

둘 다 `Authorization: Bearer <token>`으로 보냅니다. 인제스트 토큰은 발급 시 **한 번만**
표시되고 argon2 해시로만 저장됩니다.

```http
POST /api/auth/request-code   { "email": "...", "nickname": "..." }
POST /api/auth/verify         { "email": "...", "code": "123456" }  → { access_token, user }
GET  /api/auth/me
PATCH /api/auth/me            { height_cm, birth_year, sex, goal_type, activity_factor, timezone }
POST /api/auth/tokens         { "name": "iphone" }  → { token, info }   ← 한 번만 보임
GET  /api/auth/tokens
DELETE /api/auth/tokens/{id}
```

`request-code`는 계정 존재 여부와 무관하게 동일한 응답을 돌려줍니다 (이메일 열거 방지).
`dev_code` 필드는 `EXPOSE_LOGIN_CODE=true`일 때만 채워집니다.

---

## 식당과 식단표

```http
POST /api/canteens                      { name, is_public?, timezone? }
GET  /api/canteens
POST /api/canteens/join                 { join_code }

POST /api/canteens/{id}/menu-board      multipart: file, week_of?   → 초안 (저장 안 함)
POST /api/canteens/{id}/menu-plans      { slots: [...], source }     → 초안 승인 저장
PUT  /api/canteens/{id}/menu-plans      { date, meal_type, items }   → 한 슬롯 직접 입력
GET  /api/canteens/{id}/menu-plans?week_of=YYYY-MM-DD
GET  /api/canteens/{id}/menu-plans/today
POST /api/canteens/{id}/menu-plans/{plan_id}/report   { note? }
```

`menu-board`는 **동기**이고 아무것도 저장하지 않습니다. 주 1회 30초짜리 작업이고
유저가 결과를 보며 서 있으므로, 큐를 태우면 왕복만 늘어납니다. 반환된 초안의 각
항목에는 영양 DB 사전 매칭 결과(`matched_food_id`, `match_score`)가 붙습니다.

`report`는 2명 이상 신고 시 `verified`를 내립니다.

---

## 식사

```http
POST   /api/meals/photo     multipart: file, canteen_id?, meal_type?, shot_at?,
                                       for_user_id?, note?        → 202 (pending)
POST   /api/meals/manual    { items: [{name, final_g}], meal_type?, ... } → 201 (ready)
GET    /api/meals?date=YYYY-MM-DD | ?start=&end= | ?user_id=
GET    /api/meals/{id}
PATCH  /api/meals/{id}      { meal_type?, canteen_id?, note?, reanalyze? }
POST   /api/meals/{id}/retry
POST   /api/meals/{id}/edit { "text": "밥 150으로" }
PATCH  /api/meals/{id}/items/{item_id}   { final_g?, name?, food_id?, category? }
DELETE /api/meals/{id}/items/{item_id}
DELETE /api/meals/{id}
```

**사진 업로드는 202를 즉시 반환합니다.** 셔터가 모델 호출을 기다리면 안 됩니다.
클라이언트는 `pending` 식사를 바로 그릴 수 있고, 잡이 끝나면 갱신합니다.

**`PATCH /api/meals/{id}`로 끼니를 고치면 재분석합니다.** 23:30에 찍은 늦은 저녁은
간식으로 추론되고, 그러면 식단표 매칭을 놓쳐 정확도 이점이 사라집니다. 촬영 시점의
마찰은 0으로 두고 사후에 고치게 하는 쪽이 옳은 트레이드입니다.

**`/edit`의 문법**은 작습니다 (한 손으로 칠 수 있어야 하므로).

| 입력 | 동작 |
|---|---|
| `밥 150으로`, `국 200g` | 중량 설정 |
| `고기 두 배`, `밥 반` | 배율 |
| `국 안 먹음`, `김치 빼` | 항목 제거 |

**대상은 메뉴 이름이 아니라 식판 칸 이름으로 지목합니다.** 식판을 보면서
"잡곡밥 150으로"라고 말하는 사람은 없습니다. `밥`/`국`/`고기`/`반찬`/`김치`/`후식`은
카테고리로 해석되어 해당 칸의 항목을 찾습니다. 이름으로도 지목할 수 있고
(`시금치 90으로`처럼 부분 일치도 됩니다), 카테고리에 항목이 없으면 이름 매칭으로
떨어집니다.

한 칸에 항목이 둘 이상이면 **고르지 않고 되묻습니다** — `어느 쪽인가요? 시금치나물,
콩나물무침`. 틀린 항목을 조용히 고치는 것보다 한 번 더 묻는 쪽이 낫습니다.

모델 호출이 아니라 규칙 기반입니다. 문법이 작고, 지연 예산이 밀리초 단위이며,
잘못된 파싱은 그럴듯하기보다 명백해야 하기 때문입니다. 매칭은 공백을 제거한
문장에서 이뤄지므로 `두 배`와 `두배`가 같고, 한 글자 명령어(`반`, `빼`)는 독립
토큰일 때만 명령으로 읽습니다 — 그렇지 않으면 `반찬 100으로`가 반찬을 절반으로
만듭니다.

`for_user_id`를 쓰면 대리 기록이며 `diet:write` 스코프가 필요합니다.

---

## 내 식사 세트

```http
GET    /api/meal-sets
POST   /api/meal-sets/from-meal   { meal_id, name }
POST   /api/meal-sets             { name, items }
POST   /api/meal-sets/{id}/apply  { at?, meal_type?, scale? }   → 201, AI 호출 0
DELETE /api/meal-sets/{id}
```

세트는 항목 목록을 `payload`에 비정규화해 들고 있습니다. 원본 식사를 지워도
세트가 깨지지 않아야 하기 때문입니다.

---

## 운동

```http
POST /api/workouts/photo   multipart: file, for_user_id?, performed_at?, session_note?
POST /api/workouts/text    { text, user_id?, performed_at? }
POST /api/workouts         { sets: [...], user_id?, performed_at? }
GET  /api/workouts?date= | ?start=&end= | ?user_id=
GET  /api/workouts/{id}
POST /api/workouts/{id}/sets/{set_id}/confirm   { exercise_id }
DELETE /api/workouts/{id}
```

세 경로의 우선순위는 현장 순서입니다. **사진이 1순위** — PT 중에 폰을 붙잡고 세트를
입력할 트레이너는 없습니다. 세션이 끝나고 수첩을 찍으면 3초입니다.

`/text`는 먼저 로컬 규칙 파서를 시도합니다. 트레이너 속기는 충분히 규칙적이라
대부분 성공하고, 하지 않아도 되는 모델 호출이 가장 싼 호출입니다.

`confirm`은 미매칭 운동명을 확정하고 그 이름을 별칭으로 학습합니다.

---

## 체중·목표·보정

```http
POST /api/weights          { raw_kg, date? }        ← user_id 파라미터가 없습니다
GET  /api/weights?start=&end=&user_id=

GET  /api/targets/current
GET  /api/targets/tdee
GET  /api/targets/history
POST /api/targets/refresh
PUT  /api/targets/current  { target_kcal, target_protein_g?, pinned?, confirm_aggressive? }
POST /api/targets/propose  { user_id, target_kcal, target_protein_g, note? }   ← 코치
POST /api/targets/{id}/accept?confirm_aggressive=false                          ← 멘티

GET    /api/calibration
POST   /api/calibration/samples   { category, estimated_g, actual_g, meal_item_id? }
DELETE /api/calibration/{category}
```

`POST /weights`에 `user_id`가 없는 것이 설계입니다. 체중은 본인만 입력합니다.

목표가 기초대사량 아래면 `422 safety_guard`. 주간 감량이 체중의 1%를 넘으면
`422` + `detail.requires_confirmation: true`가 오고, `confirm_aggressive: true`로
다시 보내야 저장됩니다.

코치 제안은 `accepted_at`이 null인 채로 저장되며 멘티가 수락하기 전까지 효력이
없습니다.

---

## 멘토-멘티

```http
POST   /api/mentorships/invite            { type: "peer" | "coach" }  → { invite_code, invite_url }
GET    /api/mentorships/invite/{code}                                  ← 인증 불필요
POST   /api/mentorships/accept            { invite_code, permissions } ← 멘티만
GET    /api/mentorships?role=mentor|mentee
PUT    /api/mentorships/{id}/permissions  { permissions }              ← 멘티만
DELETE /api/mentorships/{id}
GET    /api/mentorships/dashboard
POST   /api/mentorships/comments          { target_user_id, body, entity, on_date? }
GET    /api/mentorships/comments?user_id=
```

`GET /invite/{code}`에 인증이 필요 없는 것이 의도입니다. 무엇을 요구받는지 보려고
먼저 로그인해야 한다면 동의의 순서가 거꾸로입니다. 응답에는 요청될 스코프 전체와
`weight_write_available: false`가 포함됩니다.

대시보드는 **부여받지 않은 항목을 null로 가립니다.** `diet:read`가 없으면
`meals_today`가 null입니다. 자동 독촉 알림은 보내지 않습니다 — `stale_days`만
돌려주고 카드 색만 바뀝니다.

---

## 배틀

```http
POST   /api/battles              { name, mode?, weeks?, canteen_id? }
GET    /api/battles
POST   /api/battles/join         { join_code, team? }
GET    /api/battles/{id}/leaderboard?through=
GET    /api/battles/{id}/me
DELETE /api/battles/{id}/leave
```

리더보드는 `user_id, nickname, team, points, logged_days, streak`만 돌려줍니다.
칼로리·단백질·체중은 어떤 필드로도 새지 않습니다. 일별 점수 내역은 `/me`에서
본인만 봅니다.

점수 규칙: 끼니 2점(하루 최대 6) · 운동 3점 · 체중 1점 · 목표 ±10% 3점 ·
단백질 목표 2점 · 그 주 첫 식단표 등록 5점.

---

## 조회·리포트·기타

```http
GET  /api/today?date=
GET  /api/reports/weekly?start=&end=&user_id=
GET  /api/foods/search?q=
GET  /api/foods/{id}
GET  /api/exercises/search?q=
GET  /api/notifications?unread_only=
POST /api/notifications/read
GET  /api/audit-log
GET  /api/media/{path}
GET  /api/healthz
POST /api/integrations/telegram/webhook
```

`/reports/weekly`가 북극성 지표(`total_entries`)와 보조 지표를 전부 돌려줍니다:
`edit_rate`, `menu_coverage`, `delegated_ratio`, `avg_calls_per_meal`,
`cache_hit_rate`.

`/media/{path}`는 `photo:read` 스코프를 검사합니다.

---

## 오류 형식

```json
{ "error": "safety_guard", "message": "목표 칼로리가 …", "detail": { ... } }
```

| 코드 | HTTP |
|---|---|
| `unauthorized` | 401 |
| `forbidden`, `weight_write_forbidden` | 403 |
| `not_found` | 404 |
| `conflict` | 409 |
| `validation_error`, `safety_guard` | 422 |
| `rate_limited` | 429 |
| `upstream_error` | 502 |
