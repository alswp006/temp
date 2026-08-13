import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'api/client.dart';
import 'api/outbox.dart';
import 'api/session.dart';
import 'app_state.dart';
import 'features/audit_screen.dart';
import 'features/battle_screen.dart';
import 'features/invite_screen.dart';
import 'features/log_screen.dart';
import 'features/login_screen.dart';
import 'features/meal_detail_screen.dart';
import 'features/mentee_screen.dart';
import 'features/menu_screen.dart';
import 'features/more_screen.dart';
import 'features/permissions_screen.dart';
import 'features/today_screen.dart';
import 'features/week_screen.dart';
import 'shell.dart';
import 'theme/app_theme.dart';
import 'web_fonts.dart';

/// 서버 주소. 시뮬레이터는 맥의 localhost를 그대로 보지만, 실기기는 LAN
/// 주소가 필요합니다:
///   flutter run --dart-define=SIKPAN_API=http://192.168.0.10:8000
const _apiBase = String.fromEnvironment(
  'SIKPAN_API',
  defaultValue: 'http://localhost:8000',
);

/// 브라우저에서 자동 검증할 때만 켭니다.
///
/// Flutter는 캔버스에 그리므로 화면에 CSS 셀렉터가 없습니다. 시맨틱스를 켜면
/// 접근성 트리가 DOM으로 나와 버튼을 이름으로 찾을 수 있습니다. 좌표로 누르는
/// 것보다 훨씬 덜 깨집니다.
///
/// 컴파일 타임 상수라 릴리스 빌드에서는 통째로 사라집니다.
const _e2e = bool.fromEnvironment('SIKPAN_E2E');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (_e2e) SemanticsBinding.instance.ensureSemantics();
  await initializeDateFormatting('ko_KR');
  await loadKoreanFontsIfWeb();

  final session = Session();
  await session.restore();
  final api = ApiClient(baseUrl: _apiBase, session: session);
  final outbox = Outbox(api);

  runApp(SikpanApp(session: session, api: api, outbox: outbox));
}

class SikpanApp extends StatefulWidget {
  const SikpanApp({
    super.key,
    required this.session,
    required this.api,
    required this.outbox,
  });

  final Session session;
  final ApiClient api;
  final Outbox outbox;

  @override
  State<SikpanApp> createState() => _SikpanAppState();
}

class _SikpanAppState extends State<SikpanApp> {
  late final GoRouter _router;
  StreamSubscription<List<ConnectivityResult>>? _connectivity;

  @override
  void initState() {
    super.initState();
    _router = buildRouter(widget.session);

    // 연결이 돌아오면 밀린 사진을 올립니다. 사용자가 아무것도 안 해도
    // 지하에서 찍은 식판이 지상에서 저절로 기록됩니다.
    _connectivity = Connectivity().onConnectivityChanged.listen((results) {
      final online =
          results.any((r) => r != ConnectivityResult.none);
      if (online && widget.session.isLoggedIn) {
        widget.outbox.drain();
      }
    });
  }

  @override
  void dispose() {
    _connectivity?.cancel();
    widget.api.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      api: widget.api,
      session: widget.session,
      outbox: widget.outbox,
      child: MaterialApp.router(
        title: '식판',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        routerConfig: _router,
      ),
    );
  }
}

GoRouter buildRouter(Session session) {
  final rootKey = GlobalKey<NavigatorState>();

  return GoRouter(
    navigatorKey: rootKey,
    initialLocation: '/today',
    refreshListenable: session,
    redirect: (context, state) {
      final path = state.uri.path;
      // 초대 화면은 로그아웃 상태에서도 열립니다. 무엇을 요구받는지 보기도
      // 전에 로그인부터 시키면 동의의 순서가 거꾸로입니다.
      final isPublic = path == '/login' || path.startsWith('/invite/');
      if (!session.isLoggedIn && !isPublic) return '/login';
      if (session.isLoggedIn && path == '/login') return '/today';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(
        path: '/invite/:code',
        builder: (_, s) => InviteScreen(code: s.pathParameters['code']!),
      ),
      GoRoute(
        path: '/meal/:id',
        builder: (_, s) =>
            MealDetailScreen(mealId: int.parse(s.pathParameters['id']!)),
      ),
      GoRoute(
        path: '/mentee/:id',
        builder: (_, s) =>
            MenteeScreen(userId: int.parse(s.pathParameters['id']!)),
      ),
      GoRoute(
        path: '/permissions/:id',
        builder: (_, s) => PermissionsScreen(
            mentorshipId: int.parse(s.pathParameters['id']!)),
      ),
      GoRoute(
        path: '/menu/:id',
        builder: (_, s) =>
            MenuScreen(canteenId: int.parse(s.pathParameters['id']!)),
      ),
      GoRoute(path: '/audit', builder: (_, __) => const AuditScreen()),
      StatefulShellRoute.indexedStack(
        builder: (_, __, shell) => HomeShell(navigationShell: shell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(path: '/today', builder: (_, __) => const TodayScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/log', builder: (_, __) => const LogScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/week', builder: (_, __) => const WeekScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/battle', builder: (_, __) => const BattleScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/more', builder: (_, __) => const MoreScreen()),
          ]),
        ],
      ),
    ],
  );
}
