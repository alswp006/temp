# 식판 모바일 앱 (Flutter)

PWA에서 옮겨 온 네이티브 클라이언트입니다. **서버는 그대로 쓰고 화면만 다시
그렸습니다** — 인식 파이프라인, 권한·감사 로그, 적응형 목표, 안전장치는 전부
`../app` 의 FastAPI 서버에 있고, 이 앱은 REST 76개에 붙는 얇은 클라이언트입니다.

## 왜 Flutter인가

PWA는 기능이 모자라서가 아니라 **"웹 티"** 때문에 교체했습니다. 화면 전환이
없고, iOS 뒤로가기 스와이프가 없고, 스크롤 관성이 어긋나고, 햅틱이 없었습니다.

Flutter는 WebView를 쓰지 않고 자체 렌더러로 직접 그리므로, iOS에서는 Cupertino
전환·뒤로가기 제스처·고무줄 스크롤이, 안드로이드에서는 Material 동작이 그대로
나옵니다. 테마에서는 색과 타이포만 얹고 **플랫폼 고유 동작은 건드리지
않습니다** — 그게 이 앱이 Flutter로 온 이유이기 때문입니다.

폰트도 같은 이유로 시스템 폰트를 씁니다. iOS의 Apple SD Gothic Neo,
안드로이드의 Noto Sans CJK가 각 플랫폼에서 가장 잘 읽히고, 무엇보다 다른 앱들과
같아 보입니다.

## 실행

```bash
flutter pub get

# 시뮬레이터/에뮬레이터 — 맥의 localhost를 그대로 봅니다
flutter run

# 실기기 — LAN 주소가 필요합니다
flutter run --dart-define=SIKPAN_API=http://192.168.0.10:8000
```

서버를 먼저 띄워 두세요 (저장소 루트에서 `make dev`). API 키 없이 `stub` 비전
프로바이더로 전체 흐름이 돕니다.

## 검증

```bash
flutter analyze          # 경고 0
flutter test             # 13개
```

브라우저에서 실제로 돌려 보려면:

```bash
flutter build web --no-web-resources-cdn \
  --dart-define=SIKPAN_API=http://127.0.0.1:8000
(cd build/web && python3 -m http.server 8300)
```

`--no-web-resources-cdn`은 CanvasKit을 CDN 대신 번들에 넣습니다. 사내망이나
CI처럼 망이 막힌 곳에서는 이게 없으면 흰 화면만 뜹니다.

### 웹 빌드의 한글 폰트

`web/fonts/`에 나눔고딕이 들어 있고 `lib/web_fonts.dart`가 **웹에서만** 싣습니다.
CanvasKit은 시스템 폰트를 쓰지 않고 없는 글자를 구글 폰트 CDN에서 받아오는데,
망이 막히면 한글이 전부 두부(□)로 나옵니다. `web/` 아래 파일은 모바일 빌드
산출물에 들어가지 않으므로 **앱 용량에는 영향이 없습니다.**

`--dart-define=SIKPAN_E2E=true`로 빌드하면 접근성 트리가 켜집니다. Flutter는
캔버스에 그려서 CSS 셀렉터가 없으므로, 브라우저 자동화가 버튼을 이름으로 찾을
수 있게 하는 용도입니다. 컴파일 타임 상수라 릴리스 빌드에서는 사라집니다.

## 구조

```
lib/
  main.dart              라우터(go_router) + 부팅
  app_state.dart         AppScope — api / session / outbox 주입
  api/
    client.dart          HTTP, 오류 타입, 멀티파트 업로드
    models.dart          서버 스키마와 1:1로 맞춘 모델
    session.dart         토큰은 Keychain/Keystore, 나머지는 prefs
    outbox.dart          오프라인 업로드 큐
  features/              화면 13개
  ui/                    공통 위젯, 라벨·포맷터
  theme/                 웹 CSS 토큰을 그대로 옮긴 색
```

상태관리 패키지를 쓰지 않았습니다. 서버가 진실의 원천이고 화면마다 필요한 것을
그때 부르면 되므로, 공유해야 하는 건 로그인 상태와 클라이언트뿐입니다.

## 아직 안 된 것

- **푸시 알림.** 클라이언트만의 문제가 아니라 서버에도 APNs/FCM이 없습니다.
  지금 알림은 DB 행이라 앱을 열어야 보입니다.
- **iOS 빌드 검증.** 이 저장소의 CI는 리눅스라 iOS를 컴파일할 수 없습니다.
  맥에서 `flutter build ios`를 한 번 돌려 확인해 주세요.
- **실제 카메라·백그라운드 업로드.** 시뮬레이터에 카메라가 없어 실기기에서만
  확인됩니다. 촬영 시트에 항상 "앨범에서 선택"을 함께 둔 것도 그래서입니다.
