import 'package:flutter/widgets.dart';

import 'api/client.dart';
import 'api/outbox.dart';
import 'api/session.dart';

/// 서버 데이터가 바뀌었다는 신호.
///
/// 이전에는 사진을 올린 뒤 오늘 화면이 스스로 갱신되기를 기대했지만, 폴링
/// 타이머는 "직전 로드 시점에 분석 중인 끼니가 있었을 때"만 걸렸습니다. 업로드
/// 직전에는 그 값이 항상 0이라 타이머가 아예 걸리지 않았고, 결과적으로 사진을
/// 찍어도 화면에서는 아무 일도 일어나지 않았습니다. 서버에는 멀쩡히 저장돼
/// 있는데도요.
///
/// 화면마다 "이럴 때 다시 불러라"를 따로 심으면 같은 종류의 구멍이 계속
/// 생깁니다. 대신 **바꾼 쪽이 알리고, 보는 쪽이 듣습니다.** 업로드·수정·삭제·
/// 큐 전송이 [bump]를 부르면, 살아 있는 화면 전부가 스스로 다시 불러옵니다.
class DataBus extends ChangeNotifier {
  int _revision = 0;
  int get revision => _revision;

  void bump() {
    _revision++;
    notifyListeners();
  }
}

/// 앱 전역 의존성. 상태관리 패키지를 안 쓴 이유는, 서버가 진실의 원천이고
/// 화면마다 필요한 것을 그때 불러오면 되기 때문입니다.
class AppScope extends InheritedNotifier<Session> {
  const AppScope({
    super.key,
    required this.api,
    required this.session,
    required this.outbox,
    required this.data,
    required super.child,
  }) : super(notifier: session);

  final ApiClient api;
  final Session session;
  final Outbox outbox;
  final DataBus data;

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
  DataBus get data => AppScope.of(this).data;
}

/// 데이터가 바뀌면 스스로 다시 불러오는 화면.
///
/// [reload]만 구현하면 됩니다. 탭이 뒤에 있어도 갱신되므로, 사용자가 돌아왔을
/// 때 이미 최신입니다 — "탭을 다시 눌러야 반영되는" 앱이 되지 않습니다.
mixin DataListener<T extends StatefulWidget> on State<T> {
  DataBus? _bus;

  Future<void> reload();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bus = AppScope.of(context).data;
    if (!identical(bus, _bus)) {
      _bus?.removeListener(_onChanged);
      _bus = bus..addListener(_onChanged);
    }
  }

  void _onChanged() {
    if (mounted) reload();
  }

  @override
  void dispose() {
    _bus?.removeListener(_onChanged);
    super.dispose();
  }
}
