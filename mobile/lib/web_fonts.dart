import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// 웹 빌드에서만 한글 폰트를 실어 옵니다.
///
/// **모바일에서는 아무것도 하지 않습니다.** iOS는 Apple SD Gothic Neo,
/// 안드로이드는 Noto Sans CJK를 시스템 폰트로 이미 갖고 있고, 그걸 쓰는 쪽이
/// 다른 앱들과 같아 보입니다 — 이 앱이 PWA를 떠난 이유가 "웹 티"였으므로
/// 폰트를 억지로 통일해 오히려 낯설게 만들 이유가 없습니다.
///
/// 반면 웹의 CanvasKit은 시스템 폰트를 쓰지 않고, 없는 글자는 구글 폰트
/// CDN에서 받아옵니다. 망이 막힌 곳(사내망, CI, 이 저장소의 검증 환경)에서는
/// 한글이 전부 두부(□)로 나옵니다. 그래서 웹에서만 폰트를 직접 싣습니다.
///
/// 파일은 `web/fonts/`에 있으므로 모바일 빌드 산출물에는 들어가지 않습니다.
Future<void> loadKoreanFontsIfWeb() async {
  if (!kIsWeb) return;

  Future<void> load(String family, List<String> urls) async {
    final loader = FontLoader(family);
    var any = false;
    for (final url in urls) {
      try {
        final res = await http.get(Uri.parse(url));
        if (res.statusCode == 200) {
          loader.addFont(Future.value(ByteData.sublistView(res.bodyBytes)));
          any = true;
        }
      } on Exception catch (e) {
        debugPrint('폰트를 못 받았습니다 ($url): $e');
      }
    }
    if (any) await loader.load();
  }

  // 실패해도 앱은 떠야 합니다. 두부로 보일지언정 동작은 합니다.
  await load('NanumGothic', const [
    'fonts/NanumGothic.ttf',
    'fonts/NanumGothicBold.ttf',
  ]);
}
