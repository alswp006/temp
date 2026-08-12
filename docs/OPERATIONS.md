# 운영

## 배포 형태

| 단계 | 형태 |
|---|---|
| Phase 1 (1인) | SQLite + 인프로세스 워커. 자택 서버 + Cloudflare Tunnel |
| Phase 2 (지인 10~30명) | PostgreSQL + API/워커 분리. 같은 자택 서버로 충분 |
| Phase 3 (출시) | 클라우드, 오브젝트 스토리지, 백업, 모니터링 |

### Phase 1

```bash
pip install -e ".[anthropic]"
cp .env.example .env      # SECRET_KEY 를 반드시 채우십시오
make dev
```

`SECRET_KEY`를 비워두면 재시작마다 새로 생성되어 **모든 로그인 세션이 무효화**됩니다.

Cloudflare Tunnel로 공인 IP·포트 개방 없이 노출:

```bash
cloudflared tunnel --url http://localhost:8000
```

### Phase 2+

```bash
export SECRET_KEY=$(python3 -c "import secrets;print(secrets.token_urlsafe(48))")
export ANTHROPIC_API_KEY=sk-ant-...
export VISION_PROVIDER=anthropic
export EXPOSE_LOGIN_CODE=false        # 프로덕션에서 반드시 false
make docker-up
```

`docker-compose.yml`은 워커를 **별도 프로세스**로 띄웁니다 (`RUN_WORKER_IN_PROCESS=false`).
느린 모델 호출이 요청 처리를 굶기지 않게 하려는 것이고, 프로덕션에서는 항상 이렇게
두십시오. 워커는 여러 개 띄워도 안전합니다 — 잡 클레임이 원자적입니다.

---

## 마이그레이션

스키마의 소유자는 Alembic입니다. `create_all()`은 `ENV != prod`에서만 돕니다.

```bash
make migrate                      # alembic upgrade head
make revision M="설명"             # 모델 변경 후 생성
alembic check                     # 모델과 마이그레이션이 어긋나면 실패
```

CI가 세 가지를 검증합니다: 빈 SQLite에 적용, `alembic check`, 그리고 Postgres에
실제로 적용. 모델만 바꾸고 마이그레이션을 빼먹는 것이 배포를 깨는 가장 쉬운
방법이라 빌드에서 잡습니다.

SQLite는 대부분의 `ALTER`를 못 하므로 `render_as_batch`가 켜져 있습니다 —
같은 마이그레이션이 양쪽에서 돕니다.

---

## 영양 DB 교체

번들된 `app/data/foods.csv`는 급식·한식 중심 약 150건의 **시작용 근사값**입니다.
프로덕션에서는 식약처 통합 DB로 교체하십시오.

```bash
# 공공데이터포털 → "식품의약품안전처 식품영양성분DB" → CSV 다운로드
make import-mfds FILE=~/Downloads/음식DB.csv
# 인코딩이 깨지면:
python scripts/import_mfds.py ~/Downloads/음식DB.csv --encoding cp949 --replace
```

임포터는 컬럼명을 위치가 아니라 별칭 집합으로 매핑합니다 (그 CSV의 컬럼명이 몇
차례 바뀌었습니다). 형식 오류 비율이 높으면 경고하고, 열량이 없는 행은 조용히
넣지 않고 버립니다.

---

## 관측

```bash
curl -s localhost:8000/api/healthz
# {"status":"ok","vision_provider":"anthropic","jobs":{"queued":0,"failed":0}}
```

`jobs.failed`가 늘면 `jobs` 테이블의 `last_error`를 보십시오.

```sql
select kind, count(*), max(last_error)
from jobs where status = 'failed' group by kind;
```

**주간 리포트가 운영 지표를 겸합니다.** `/api/reports/weekly`:

| 지표 | 의미 | 나빠지면 |
|---|---|---|
| `total_entries` | 북극성 지표 | 나머지 지표가 전부 무의미 |
| `edit_rate` | AI 결과를 손으로 고친 비율 | 30% 초과면 인식 품질 문제 |
| `menu_coverage` | 식단표가 있던 끼니 비율 | 낮으면 열린 인식이 많다는 뜻 |
| `avg_calls_per_meal` | 끼니당 AI 호출 | 비용 |
| `cache_hit_rate` | 기준 해석 재사용률 | 낮으면 캐시가 안 먹고 있음 |
| `delegated_ratio` | 멘토가 대신 쓴 비율 | 대리 기록 UX가 작동하는지 |

### 비용 감각

`avg_calls_per_meal × 끼니수 × 모델 단가`가 전부입니다. 줄이는 순서:

1. `cache_hit_rate`를 올린다 — 같은 식당 유저를 늘리는 게 가장 큽니다.
2. `RECOGNITION_K_COLD`를 낮춘다 (5 → 3). 정확도와 직접 교환됩니다.
3. `ANTHROPIC_EFFORT`를 확인한다. 기본 `low`이고, 후보 목록이 주어진 판독에는
   그걸로 충분합니다.
4. 유저가 세트·수동 입력을 쓰게 만든다 — 호출이 0입니다.

---

## 프라이버시

식판 사진에는 타인의 얼굴·명찰·장소 맥락이 찍힙니다.

**지금 하고 있는 것**

* 업로드 시 EXIF를 제거하고 (GPS 포함) 긴 변 1568px로 축소해 재인코딩합니다.
  촬영 시각은 제거 **전에** 읽습니다.
* `DISCARD_PHOTO_AFTER_ANALYSIS=true`면 분석 직후 원본을 지웁니다.
* `/api/media/{path}`는 `photo:read` 스코프를 검사합니다. `diet:read`로는 사진을
  볼 수 없습니다.
* 미디어 경로는 미디어 루트 밖으로 나가는 접근을 거부합니다.

**아직 안 하는 것**

* 얼굴 자동 블러 (모델 의존성이 필요합니다). 지금은 원본 파기 옵션으로 대신합니다.
* 사진의 서버측 암호화. 오브젝트 스토리지로 옮길 때 함께 하십시오.

**출시 전 체크리스트**

- [ ] 건강정보 **별도 동의** 화면 분리
- [ ] "의료기기 아님 / 참고용" 문구 상시 노출
- [ ] 탈퇴 시 사진·기록 완전 삭제 경로
- [ ] 구독 해지 경로 2탭 이내
- [ ] 이용약관·개인정보처리방침

---

## 백업

| 대상 | 방법 |
|---|---|
| PostgreSQL | `pg_dump`를 일 1회, 오프사이트로 |
| SQLite | WAL 모드이므로 `sqlite3 sikpan.db ".backup out.db"` |
| 미디어 | `var/media` 디렉터리. 오브젝트 스토리지면 버저닝 |

식사 사진은 재생성이 불가능합니다. DB만 백업하고 미디어를 빼먹지 마십시오.

---

## 텔레그램 브리지

```bash
export TELEGRAM_BOT_TOKEN=123456:ABC...
export TELEGRAM_WEBHOOK_SECRET=$(python3 -c "import secrets;print(secrets.token_urlsafe(32))")

curl -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/setWebhook" \
  -d "url=https://<your-host>/api/integrations/telegram/webhook" \
  -d "secret_token=$TELEGRAM_WEBHOOK_SECRET"
```

사용자는 봇에게 `/link sk_…` (앱에서 발급한 인제스트 토큰)를 보내 계정을 연결합니다.
이후 사진·숫자·문장이 각각 식사·체중·운동으로 들어갑니다.

`TELEGRAM_BOT_TOKEN`이 없으면 전송이 로그로만 나갑니다 (dry-run). 웹훅 시크릿이
설정돼 있으면 헤더가 맞지 않는 요청은 401입니다.

---

## 흔한 문제

| 증상 | 원인 / 조치 |
|---|---|
| 식사가 계속 `pending` | 워커가 안 돎. `RUN_WORKER_IN_PROCESS` 또는 워커 컨테이너 확인 |
| `upstream_error` | API 키·쿼터. `/healthz`의 `vision_provider`가 `stub`이면 키 초기화 실패 |
| 모든 식사가 `open_mode` | 그 식당·날짜·끼니에 식단표가 없음 |
| 로그인이 자꾸 풀림 | `SECRET_KEY`가 비어 있어 재시작마다 재생성됨 |
| SQLite `database is locked` | 워커 동시성. Phase 2 이상이면 Postgres로 옮기십시오 |
| 마이그레이션 충돌 | `alembic check`로 모델·마이그레이션 어긋남 확인 |
