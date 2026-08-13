import 'package:flutter/widgets.dart';

import 'api/client.dart';
import 'api/outbox.dart';
import 'api/session.dart';

/// 앱 전역 의존성. 상태관리 패키지를 안 쓴 이유는, 서버가 진실의 원천이고
/// 화면마다 필요한 것을 그때 불러오면 되기 때문입니다. 공유해야 하는 건
/// 로그인 상태와 클라이언트 두 개뿐입니다.
class AppScope extends InheritedNotifier<Session> {
  const AppScope({
    super.key,
    required this.api,
    required this.session,
    required this.outbox,
    required super.child,
  }) : super(notifier: session);

  final ApiClient api;
  final Session session;
  final Outbox outbox;

  /// [listen]이 false면 의존성을 등록하지 않습니다 — 이게 기본입니다.
  ///
  /// `api`와 `outbox`는 앱이 사는 동안 바뀌지 않으므로 이들 때문에 다시
  /// 그릴 이유가 없고, 무엇보다 `dependOnInheritedWidgetOfExactType`는
  /// initState 안에서 부르면 단언에 걸립니다. 화면들이 initState에서 첫
  /// 로드를 시작하므로 그쪽이 기본 경로입니다.
  static AppScope of(BuildContext context, {bool listen = false}) {
    final scope = listen
        ? context.dependOnInheritedWidgetOfExactType<AppScope>()
        : context.getInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope가 위젯 트리에 없습니다');
    return scope!;
  }

  @override
  bool updateShouldNotify(covariant InheritedNotifier<Session> oldWidget) => true;
}

extension AppScopeX on BuildContext {
  ApiClient get api => AppScope.of(this).api;
  Session get session => AppScope.of(this).session;
  Outbox get outbox => AppScope.of(this).outbox;
}
