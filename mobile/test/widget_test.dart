import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sikpan_app/api/client.dart';
import 'package:sikpan_app/api/models.dart';
import 'package:sikpan_app/api/outbox.dart';
import 'package:sikpan_app/api/session.dart';
import 'package:sikpan_app/app_state.dart';
import 'package:sikpan_app/features/today_screen.dart';
import 'package:sikpan_app/theme/app_theme.dart';
import 'package:sikpan_app/ui/labels.dart';

/// 테스트용 세션 — 시크릿 저장소는 플러그인이라 위젯 테스트에서 못 씁니다.
class _FakeSession extends Session {
  _FakeSession() : super(storage: null);

  @override
  String? get token => 'test-token';

  @override
  bool get isLoggedIn => true;
}

/// 요청 경로별로 정해진 JSON을 돌려주는 가짜 서버.
http.Client _stubClient(Map<String, Object> routes) {
  return _StubClient(routes);
}

class _StubClient extends http.BaseClient {
  _StubClient(this.routes);
  final Map<String, Object> routes;
  final sent = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    sent.add('${request.method} $path');
    final body = routes[path];
    final status = body == null ? 404 : 200;
    final payload = utf8.encode(jsonEncode(body ?? {'message': 'not found'}));
    return http.StreamedResponse(Stream.value(payload), status);
  }
}

Widget _wrap(Widget child, http.Client client) {
  final session = _FakeSession();
  final api =
      ApiClient(baseUrl: 'http://test', session: session, inner: client);
  return AppScope(
    api: api,
    session: session,
    outbox: Outbox(api),
    child: MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Fmt', () {
    test('날짜만 온 문자열을 로컬 자정으로 읽는다', () {
      // UTC로 읽으면 한국에서 하루가 밀려 표시됩니다.
      expect(Fmt.date('2026-08-13'), '8월 13일');
    });

    test('요일이 맞다', () {
      expect(Fmt.weekday('2026-08-13'), '목');
    });

    test('kcal은 천 단위로 끊는다', () {
      expect(Fmt.kcal(1234.6), '1,235');
    });

    test('퍼센트는 반올림한다', () {
      expect(Fmt.pct(0.436), '44%');
    });

    test('시각은 한국어 오전/오후로 나온다', () async {
      // 브라우저에서 'PM 12:02'로 나오는 걸 보고 넣은 테스트입니다.
      // 로케일 데이터가 안 실리면 조용히 영어로 떨어집니다.
      await initializeDateFormatting('ko_KR');
      expect(Fmt.time(DateTime(2026, 8, 13, 12, 2)), '오후 12:02');
      expect(Fmt.time(DateTime(2026, 8, 13, 8, 5)), '오전 8:05');
    });
  });

  group('모델 파싱', () {
    test('서버 필드 이름을 그대로 읽는다', () {
      final meal = Meal.fromJson({
        'id': 1,
        'meal_type': 'lunch',
        'status': 'ready',
        'local_date': '2026-08-13',
        'shot_at': '2026-08-13T03:00:00Z',
        'kcal': 513.0,
        'protein_g': 27.0,
        'open_mode': true,
        'calls_used': 5,
        'items': [
          {
            'id': 9,
            'name': '잡곡밥',
            'category': 'rice',
            'final_g': 150.0,
            'portion_ratio': 1.0,
            'kcal': 210.0,
            'edited_by_user': true,
            'confidence': 1.0,
          }
        ],
      });

      expect(meal.mealType, 'lunch');
      expect(meal.isReady, isTrue);
      expect(meal.openMode, isTrue);
      expect(meal.items.single.name, '잡곡밥');
      expect(meal.items.single.editedByUser, isTrue);
    });

    test('없는 필드는 죽지 않고 기본값이 된다', () {
      // 서버가 필드를 하나 빼먹었다고 앱이 죽으면 안 됩니다.
      final meal = Meal.fromJson({'id': 2});
      expect(meal.kcal, 0);
      expect(meal.items, isEmpty);
      expect(meal.isPending, isTrue);
    });
  });

  group('오늘 화면', () {
    testWidgets('남은 kcal과 식사 목록을 그린다', (tester) async {
      final client = _stubClient({
        '/api/today': {
          'summary': {
            'date': '2026-08-13',
            'kcal': 1200.0,
            'protein_g': 60.0,
            'carb_g': 150.0,
            'fat_g': 40.0,
            'target_kcal': 2000.0,
            'remaining_kcal': 800.0,
            'meals': 1,
          },
          'meals': [
            {
              'id': 1,
              'meal_type': 'lunch',
              'status': 'ready',
              'kcal': 513.0,
              'local_date': '2026-08-13',
              'shot_at': '2026-08-13T03:00:00Z',
              'items': [
                {'id': 1, 'name': '잡곡밥', 'category': 'rice'},
              ],
            }
          ],
          'quick_sets': [],
          'pending': 0,
        },
      });

      await tester.pumpWidget(_wrap(const TodayScreen(), client));
      await tester.pumpAndSettle();

      expect(find.text('800'), findsOneWidget); // 남은 kcal
      expect(find.textContaining('목표 2,000'), findsOneWidget);
      expect(find.text('중식'), findsOneWidget);
      expect(find.text('잡곡밥'), findsOneWidget);
    });

    testWidgets('목표를 넘으면 초과라고 말한다', (tester) async {
      final client = _stubClient({
        '/api/today': {
          'summary': {
            'date': '2026-08-13',
            'kcal': 2400.0,
            'target_kcal': 2000.0,
            'remaining_kcal': -400.0,
            'meals': 3,
          },
          'meals': [],
          'quick_sets': [],
          'pending': 0,
        },
      });

      await tester.pumpWidget(_wrap(const TodayScreen(), client));
      await tester.pumpAndSettle();

      expect(find.textContaining('초과'), findsOneWidget);
      expect(find.text('400'), findsOneWidget);
    });

    testWidgets('목표가 없으면 섭취량을 보여주고 초과를 말하지 않는다', (tester) async {
      final client = _stubClient({
        '/api/today': {
          'summary': {'date': '2026-08-13', 'kcal': 900.0, 'meals': 1},
          'meals': [],
          'quick_sets': [],
          'pending': 0,
        },
      });

      await tester.pumpWidget(_wrap(const TodayScreen(), client));
      await tester.pumpAndSettle();

      expect(find.text('900'), findsOneWidget);
      expect(find.textContaining('목표 미설정'), findsOneWidget);
      expect(find.textContaining('초과'), findsNothing);
    });

    testWidgets('분석 중이면 배너가 뜬다', (tester) async {
      final client = _stubClient({
        '/api/today': {
          'summary': {'date': '2026-08-13', 'meals': 0},
          'meals': [],
          'quick_sets': [],
          'pending': 2,
        },
      });

      await tester.pumpWidget(_wrap(const TodayScreen(), client));
      await tester.pump(); // 폴링 타이머가 걸려 있어 settle하지 않습니다.

      expect(find.textContaining('분석 중인 식사 2건'), findsOneWidget);
    });
  });

  group('API 클라이언트', () {
    test('한글이 깨지지 않는다', () async {
      // res.body는 latin1로 읽는 경우가 있어 바이트에서 직접 디코드합니다.
      final client = _stubClient({
        '/api/today': {'summary': {'date': '2026-08-13'}, 'note': '된장찌개'},
      });
      final session = _FakeSession();
      final api =
          ApiClient(baseUrl: 'http://test', session: session, inner: client);
      final json = await api.get('/today') as Map<String, dynamic>;
      expect(json['note'], '된장찌개');
    });

    test('오류 응답을 ApiException으로 바꾼다', () async {
      final session = _FakeSession();
      final api = ApiClient(
        baseUrl: 'http://test',
        session: session,
        inner: _stubClient(const {}),
      );
      expect(
        () => api.get('/nope'),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 404)),
      );
    });
  });
}
