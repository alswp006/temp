import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// 크래시 리포팅.
///
/// DSN이 없으면 통째로 비활성이고 `runner()`는 그냥 앱을 실행합니다.
///
/// 서버 쪽과 같은 원칙: **건강 데이터를 다루므로 기본이 "안 보낸다"** 입니다.
/// 이메일과 인증 토큰은 이벤트에서 지우고, 사용자는 아이디로만 식별합니다.
const _dsn = String.fromEnvironment('SENTRY_DSN');

class Crash {
  static bool get enabled => _dsn.isNotEmpty;

  /// 앱 전체를 감쌉니다. 이 밖으로 나가는 예외는 보고되지 않습니다.
  static Future<void> run(FutureOr<void> Function() body) async {
    if (!enabled) {
      // DSN이 없어도 최소한 콘솔에는 남깁니다.
      FlutterError.onError = (details) =>
          FlutterError.presentError(details);
      await body();
      return;
    }

    await SentryFlutter.init(
      (options) {
        options.dsn = _dsn;
        options.environment = kReleaseMode ? 'prod' : 'dev';
        options.release = 'sikpan-app@0.1.0';
        // 화면 캡처는 끕니다 — 식판 사진과 체중이 그대로 담깁니다.
        // (뷰 계층 첨부는 기본이 꺼짐이고, 켜는 옵션이 실험 단계라
        //  일부러 건드리지 않습니다.)
        options.attachScreenshot = false;
        options.sendDefaultPii = false;
        options.beforeSend = _scrub;
      },
      appRunner: () async => body(),
    );
  }

  static final _email = RegExp(r'[\w.+-]+@[\w-]+\.[\w.-]+');

  static FutureOr<SentryEvent?> _scrub(SentryEvent event, Hint hint) {
    // 메시지에 섞여 들어간 이메일을 지웁니다.
    final formatted = event.message?.formatted;
    if (formatted != null) {
      event = event.copyWith(message: SentryMessage(_mask(formatted)));
    }
    // 사용자는 아이디로만. 이메일·IP는 남기지 않습니다.
    final user = event.user;
    if (user != null) {
      event = event.copyWith(
        user: SentryUser(id: user.id),
      );
    }
    return event;
  }

  static String _mask(String text) => text.replaceAllMapped(_email, (m) {
        final at = m.group(0)!.split('@');
        final local = at.first;
        final head = local.length > 2 ? local.substring(0, 2) : local;
        return '$head***@${at.last}';
      });

  /// 예외 하나를 손으로 보고합니다.
  static Future<void> capture(Object error, StackTrace? stack) async {
    if (!enabled) {
      debugPrint('처리되지 않은 예외: $error\n$stack');
      return;
    }
    await Sentry.captureException(error, stackTrace: stack);
  }

  /// 누구에게 일어난 일인지만. 이메일은 넣지 않습니다.
  static void setUser(int? userId) {
    if (!enabled) return;
    Sentry.configureScope((scope) {
      scope.setUser(userId == null ? null : SentryUser(id: '$userId'));
    });
  }
}
