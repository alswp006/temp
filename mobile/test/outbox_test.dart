import 'package:flutter_test/flutter_test.dart';
import 'package:sikpan_app/api/outbox.dart';

void main() {
  // 예전에는 drain()이 `on ApiException`을 잡아 무조건 파일을 지웠습니다.
  // ApiException은 400 이상 전부라, 서버가 잠깐 500을 뱉거나 토큰이 만료돼
  // 401이 나면 사용자가 찍어 둔 사진이 영구히 사라졌습니다. 사진을 지키는 것이
  // 이 큐의 존재 이유인데 정반대로 동작했습니다.
  group('오프라인 큐 · 무엇을 버리고 무엇을 지킬 것인가', () {
    test('서버 사정(5xx)은 버리지 않는다', () {
      for (final status in [500, 502, 503, 504]) {
        expect(Outbox.isPermanentReject(status), isFalse, reason: '$status');
      }
    });

    test('토큰 문제(401)는 버리지 않는다 — 다시 로그인하면 올라간다', () {
      expect(Outbox.isPermanentReject(401), isFalse);
    });

    test('일시적 실패(408·429)는 버리지 않는다', () {
      expect(Outbox.isPermanentReject(408), isFalse);
      expect(Outbox.isPermanentReject(429), isFalse);
    });

    test('서버가 확정적으로 거절한 것만 버린다', () {
      // 이것들을 계속 재시도하면 큐에서 영원히 빠지지 않습니다.
      for (final status in [400, 403, 404, 413, 415, 422]) {
        expect(Outbox.isPermanentReject(status), isTrue, reason: '$status');
      }
    });
  });
}
