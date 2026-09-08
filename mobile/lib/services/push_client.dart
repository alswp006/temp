import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../api/client.dart';

/// 푸시 등록.
///
/// **Firebase 설정 파일이 없으면 통째로 건너뜁니다.** `google-services.json`
/// (안드로이드)과 `GoogleService-Info.plist`(iOS)는 저장소에 없습니다 —
/// 프로젝트마다 다르고 커밋할 물건도 아닙니다. 없는 상태로 초기화를 시도하면
/// 앱이 부팅에서 죽으므로, 실패를 정상 경로로 취급합니다.
///
/// 알림 권한도 사용자가 거절할 수 있고, 그건 오류가 아닙니다. 거절하면 알림은
/// 여전히 서버에 쌓이고 앱을 열면 보입니다.
class PushClient {
  PushClient(this.api);

  final ApiClient api;
  bool _ready = false;
  String? _token;

  /// 서버가 준 기기 행 id. 로그아웃할 때 이 값으로 해제합니다.
  /// 예전에는 등록 응답을 버려서, 해제하고 싶어도 무엇을 지울지 몰랐습니다.
  int? _deviceId;

  String? get token => _token;
  bool get isReady => _ready;

  /// 앱이 뜰 때 한 번. 실패해도 예외를 던지지 않습니다.
  Future<void> start() async {
    if (kIsWeb) return; // 웹 푸시는 아직 지원하지 않습니다.
    try {
      await Firebase.initializeApp();
    } on Exception catch (e) {
      // 설정 파일이 없는 개발 환경의 정상 상태입니다.
      debugPrint('Firebase 미설정 — 푸시를 건너뜁니다: $e');
      return;
    }

    final messaging = FirebaseMessaging.instance;
    try {
      final settings = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        debugPrint('알림 권한 거부됨 — 앱 안에서만 알림을 봅니다.');
        return;
      }

      final token = await messaging.getToken();
      if (token != null) await _register(token);

      // 토큰은 앱 재설치·OS 업데이트에 말없이 바뀝니다. 갱신될 때마다
      // 다시 등록하지 않으면 어느 날부터 알림이 조용히 끊깁니다.
      messaging.onTokenRefresh.listen(_register);
      _ready = true;
    } on Exception catch (e) {
      debugPrint('푸시 등록 실패: $e');
    }
  }

  Future<void> _register(String token) async {
    _token = token;
    try {
      final json = await api.post('/devices', body: {
        'token': token,
        'platform': defaultTargetPlatform == TargetPlatform.iOS
            ? 'ios'
            : 'android',
      });
      if (json is Map && json['id'] is int) _deviceId = json['id'] as int;
    } on ApiException catch (e) {
      debugPrint('기기 등록 실패: ${e.message}');
    } on OfflineException {
      // 다음 실행에 다시 시도합니다.
    }
  }

  /// 로그아웃하기 **전에** 부릅니다.
  ///
  /// 안 부르면 기기를 넘겨받은 사람에게 이전 사용자의 식사·체중 알림이 갑니다.
  /// 토큰이 아직 살아 있을 때만 서버가 받아 주므로 signOut 앞에 와야 합니다.
  Future<void> unregister() async {
    final id = _deviceId;
    if (id != null) {
      try {
        await api.delete('/devices/$id');
      } on Exception catch (e) {
        debugPrint('기기 해제 실패: $e');
      }
    }
    // 서버 호출이 실패해도 이 기기의 상태는 반드시 비웁니다. 안 그러면 다음
    // 사용자가 로그인해도 start()가 다시 돌지 않아 푸시를 하나도 못 받습니다.
    _deviceId = null;
    _token = null;
    _ready = false;
  }
}
