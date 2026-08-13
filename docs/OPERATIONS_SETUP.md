# 출시 전 설정 4가지

코드는 전부 들어가 있고, **자격증명만 넣으면 켜집니다.** 넷 다 없어도 앱은
돌지만, 없으면 각각 아래가 안 됩니다.

| | 없으면 | 설정 |
|---|---|---|
| ① 비전 API 키 | 사진 인식이 stub 더미 | `VISION_PROVIDER` + 키 |
| ② SMTP | **실제 사용자가 로그인 불가** | `SMTP_*` |
| ③ FCM | 푸시 없음 (앱 열면 알림은 보임) | `FCM_*` + Firebase 설정 파일 |
| ④ Sentry | 실기기에서 뭐가 깨지는지 모름 | `SENTRY_DSN` |

우선순위는 **② → ① → ④ → ③** 입니다. ②가 없으면 사용자가 존재할 수 없고,
①이 없으면 제품의 전제가 검증되지 않습니다.

---

## ① 비전 API — 인식 정확도 검증

```bash
export VISION_PROVIDER=anthropic
export ANTHROPIC_API_KEY=sk-ant-...
```

키를 넣은 다음 **가장 먼저 할 일은 정확도를 재는 것입니다.**
`eval/README.md`를 보고 저울로 잰 식판 사진 30장을 모은 뒤:

```bash
python scripts/eval_recognition.py
```

식단표 모드와 열린 인식 모드의 F1 차이가 이 제품이 존재할 이유입니다.
차이가 없으면 다듬기 전에 원인부터 보세요.

## ② SMTP — 로그인

```bash
export SMTP_HOST=smtp.gmail.com
export SMTP_PORT=587
export SMTP_USER=you@gmail.com
export SMTP_PASSWORD=앱비밀번호            # 계정 비밀번호가 아닙니다
export MAIL_FROM='식판 <you@gmail.com>'
export EXPOSE_LOGIN_CODE=false            # 프로덕션에서는 반드시 false
```

`EXPOSE_LOGIN_CODE=true`면 API 응답에 로그인 코드가 그대로 실립니다. 개발
편의용이고, **프로덕션에서 켜 두면 누구나 남의 계정으로 들어갈 수 있습니다.**

메일이 안 나가도 `/api/auth/request-code`는 200을 돌려줍니다 — 코드는 이미
저장되었고 사용자가 재시도할 수 있어야 하기 때문입니다. 대신 로그에
`로그인 코드를 보내지 못했습니다`가 ERROR로 찍히니 그걸 감시하세요.

## ③ FCM — 푸시

1. Firebase 콘솔에서 프로젝트를 만듭니다.
2. iOS/Android 앱을 등록하고 설정 파일을 받습니다.
   - `mobile/android/app/google-services.json`
   - `mobile/ios/Runner/GoogleService-Info.plist`
   - **둘 다 저장소에 커밋하지 마세요.**
3. iOS는 APNs 인증 키(.p8)를 Firebase에 올려야 합니다. 이걸 빼먹으면
   안드로이드만 알림이 오고 iOS는 조용합니다.
4. 서버용 서비스 계정 JSON을 받아:

```bash
export PUSH_PROVIDER=fcm
export FCM_CREDENTIALS_FILE=/secrets/fcm.json
export FCM_PROJECT_ID=your-project-id
```

설정이 없으면 `noop`으로 조용히 돕니다 — 알림은 DB에 쌓이고 앱을 열면
보입니다. **기능이 사라지지 않습니다.**

### 하루 2회 상한

`app/services/push.py`의 `MAX_PUSH_PER_DAY = 2`가 강제합니다. 로드맵의
"만들지 않을 것"에 적힌 제품 결정이고, 독촉으로 기록을 왜곡시키지 않겠다는
뜻입니다. 상한에 걸린 알림도 행은 남으므로 앱에서는 보입니다.

## ④ Sentry — 크래시 리포팅

```bash
pip install -e ".[sentry]"
export SENTRY_DSN=https://...@o0.ingest.sentry.io/0
export ENV=prod
```

앱 쪽은 빌드할 때 넣습니다:

```bash
flutter build ipa --dart-define=SENTRY_DSN=https://...
```

**건강 데이터를 다루므로 기본이 "안 보낸다"입니다.** 이메일은 마스킹하고,
Authorization·쿠키·API 키는 값을 통째로 지우고, 사용자는 아이디로만
식별합니다. 앱에서는 화면 캡처를 끕니다 — 식판 사진과 체중이 그대로 담기기
때문입니다. 스크러빙이 실패하면 이벤트를 **버립니다**. 새는 것보다 잃는 게
낫습니다.

---

## 아직 안 된 것

- **페이지네이션** — 식사 목록·변경 이력·배틀이 통째로 옵니다. 6개월 쓴
  사용자에게서 처음 느려집니다.
- **결제** — 멘티 한도는 강제되지만 플랜을 사고파는 경로가 없습니다.
- **무료 플랜 하루 2회 촬영 제한** — 지금은 전원 무제한이라 AI 원가가
  그대로 나갑니다.
- **iOS 빌드 검증** — 이 저장소의 CI는 리눅스라 컴파일할 수 없습니다.
