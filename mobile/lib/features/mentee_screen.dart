import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../app_state.dart';
import '../theme/tokens.dart';
import '../ui/labels.dart';
import '../ui/widgets.dart';
import 'capture.dart';
import 'today_screen.dart' show MealRow;

/// 코치가 보는 멘티 화면.
///
/// 이 화면에서 코치가 가장 먼저 알아야 하는 것은 두 가지입니다. **멘티가 오늘
/// 어땠는가**, 그리고 **내가 어디까지 대신 할 수 있는가**. 예전에는 둘 다 화면
/// 어딘가에 흩어져 있었습니다. 권한은 맨 아래 한 줄("체중은 대신 입력할 수
/// 없습니다")로만 언급됐고, 열려 있는 항목이 무엇인지는 눌러 보기 전에는 알 수
/// 없었습니다.
///
/// 그래서 권한을 맨 위로 올렸습니다. 권한이 없는 항목은 숨기지 않고 "권한
/// 없음"이라고 말합니다 — 조용히 비어 보이면 코치는 멘티가 기록을 안 한 걸로
/// 오해합니다.
class MenteeScreen extends StatefulWidget {
  const MenteeScreen({super.key, required this.userId});
  final int userId;

  @override
  State<MenteeScreen> createState() => _MenteeScreenState();
}

class _MenteeScreenState extends State<MenteeScreen>
    with DataListener<MenteeScreen> {
  final _note = TextEditingController();

  /// null은 **권한 없음**입니다. 빈 목록(기록 없음)과 반드시 구분합니다.
  List<Meal>? _meals;
  List<Workout>? _workouts;

  /// 이 멘티와의 연결. 권한 맵이 여기서 옵니다.
  Mentorship? _link;

  /// 코치 대시보드가 주는 요약 (닉네임·미기록 일수·주간 달성).
  MenteeCard? _card;

  bool _loading = true;
  bool _busy = false; // 운동 수첩 업로드 중
  bool _sending = false; // 코멘트 전송 중

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  /// [DataBus]가 부릅니다 — 대리 기록·코멘트 직후.
  @override
  Future<void> reload() => _load();

  Future<T?> _try<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on ApiException {
      return null;
    } on OfflineException {
      return null;
    }
  }

  Future<void> _load() async {
    // 의존성은 첫 await 전에 잡아 둡니다.
    final api = context.api;
    final id = widget.userId;

    // 네 개를 한꺼번에 던집니다. 순차로 기다리면 왕복 네 번이 그대로 더해져
    // 화면이 몇 초씩 비어 있게 됩니다. 서로 의존하지 않으므로 기다릴 이유가
    // 없습니다.
    final results = await Future.wait([
      _try(() async =>
          ((await api.get('/meals', query: {'user_id': id})) as List)
              .map((e) => Meal.fromJson(e as Map<String, dynamic>))
              .toList()),
      _try(() async =>
          ((await api.get('/workouts', query: {'user_id': id})) as List)
              .map((e) => Workout.fromJson(e as Map<String, dynamic>))
              .toList()),
      _try(() async =>
          ((await api.get('/mentorships', query: {'role': 'mentor'})) as List)
              .map((e) => Mentorship.fromJson(e as Map<String, dynamic>))
              .toList()),
      _try(() async => ((await api.get('/mentorships/dashboard')) as List)
          .map((e) => MenteeCard.fromJson(e as Map<String, dynamic>))
          .toList()),
    ]);
    if (!mounted) return;

    Mentorship? link;
    for (final m in (results[2] as List<Mentorship>?) ?? const <Mentorship>[]) {
      if (m.menteeId == id) {
        link = m;
        break;
      }
    }
    MenteeCard? card;
    for (final k in (results[3] as List<MenteeCard>?) ?? const <MenteeCard>[]) {
      if (k.userId == id) {
        card = k;
        break;
      }
    }

    setState(() {
      _meals = results[0] as List<Meal>?;
      _workouts = results[1] as List<Workout>?;
      _link = link;
      _card = card;
      _loading = false;
    });
  }

  /// 이 스코프가 열려 있는가. 연결 정보를 못 불러왔으면 null(모름)입니다 —
  /// 모르는 것을 "닫힘"으로 그리면 멀쩡한 권한을 없다고 말하게 됩니다.
  bool? _open(String scope) {
    final granted = _link?.permissions;
    if (granted == null) return null;
    return granted[scope] ?? false;
  }

  String get _name => _card?.nickname ?? _link?.menteeName ?? '멘티';

  // --- 동작 ----------------------------------------------------------------

  Future<void> _logWorkoutFor() async {
    final source = await askImageSource(
      context,
      title: '운동 수첩',
      subtitle: '$_name 대신 기록합니다. 변경 이력에 내 이름이 남습니다.',
    );
    if (source == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final bytes = await MealCapture.pickBytes(source: source);
      if (bytes == null || !mounted) return;
      showToast(context, '읽는 중…');
      final json = await context.api.upload(
        '/workouts/photo',
        bytes,
        filename: 'note.jpg',
        fields: {'for_user_id': '${widget.userId}'},
      );
      final workout = Workout.fromJson(json as Map<String, dynamic>);
      if (!mounted) return;
      showToast(context, '${workout.sets.length}세트 기록했습니다',
          tone: ToastTone.success);
      // 대리 기록도 서버 데이터를 바꿉니다. 알리면 이 화면과 다른 화면이
      // 함께 스스로 다시 불러옵니다.
      context.data.bump();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, tone: ToastTone.error);
    } on OfflineException {
      if (mounted) {
        showToast(context, '네트워크에 연결할 수 없습니다', tone: ToastTone.error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _comment() async {
    final body = _note.text.trim();
    if (body.isEmpty) return;
    setState(() => _sending = true);
    try {
      await context.api.post('/mentorships/comments', body: {
        'target_user_id': widget.userId,
        'entity': 'day',
        'body': body,
      });
      if (!mounted) return;
      _note.clear();
      showToast(context, '코멘트를 남겼습니다', tone: ToastTone.success);
      context.data.bump();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, tone: ToastTone.error);
    } on OfflineException {
      if (mounted) {
        showToast(context, '네트워크에 연결할 수 없습니다', tone: ToastTone.error);
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // --- 화면 ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_loading ? '멘티' : _name,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
        actions: [
          if (!_loading && _link != null)
            Padding(
              padding: const EdgeInsets.only(right: Dim.s16),
              child: Center(
                child: SikpanBadge(
                    _link!.type == 'coach' ? '코치 연결' : '친구 연결'),
              ),
            ),
        ],
      ),
      body: _loading ? const _MenteeSkeleton() : _body(),
    );
  }

  Widget _body() {
    // 넷 다 비었으면 권한 문제가 아니라 연결 문제입니다.
    if (_meals == null && _workouts == null && _link == null && _card == null) {
      return ScreenBody(children: [
        EmptyState(
          '연결을 확인하고 다시 시도해 주세요.',
          icon: Icons.cloud_off_rounded,
          title: '불러오지 못했습니다',
          action: '다시 시도',
          onAction: _load,
        ),
      ]);
    }

    return ScreenBody(
      onRefresh: _load,
      children: [
        _accessBanner(),
        _MenteeHero(
          name: _name,
          card: _card,
          meals: _meals,
          workouts: _workouts,
        ),
        _PermissionCard(link: _link, onRetry: _load),
        _mealCard(),
        _workoutCard(),
        _delegateCard(),
        _commentCard(),
      ],
    );
  }

  /// 대리 기록으로 무엇이 열려 있는지 한 줄로. 화면에서 가장 먼저 읽히는
  /// 자리에 둡니다 — 코치가 "해도 되나?"를 묻지 않아도 되도록.
  Widget _accessBanner() {
    if (_link == null) {
      return NoticeBanner(
        '연결 정보를 불러오지 못해 권한을 확인할 수 없습니다.',
        icon: Icons.help_outline_rounded,
        action: '다시 시도',
        onAction: _load,
      );
    }

    final writes = [
      for (final scope in const ['diet:write', 'workout:write'])
        if (_open(scope) == true) scopeLabel[scope]!,
    ];

    if (writes.isEmpty) {
      return const NoticeBanner(
        '대리 기록 권한이 없습니다 — 보기만 할 수 있습니다.',
        icon: Icons.lock_outline_rounded,
      );
    }
    return NoticeBanner(
      '${writes.join(' · ')}까지 대신 할 수 있습니다. 체중은 어떤 경우에도 대신 입력할 수 없습니다.',
      tone: BadgeTone.accent,
      icon: Icons.edit_note_rounded,
    );
  }

  // --- 오늘 식단 -----------------------------------------------------------

  Widget _mealCard() {
    final meals = _meals;
    return SikpanCard(
      title: '오늘 식단',
      subtitle: meals == null || meals.isEmpty ? null : '${meals.length}끼',
      icon: Icons.restaurant_rounded,
      child: meals == null
          ? const EmptyState(
              '멘티가 식단 조회를 켜야 보입니다.\n권한은 멘티만 바꿀 수 있습니다.',
              icon: Icons.lock_outline_rounded,
              title: '식단 조회 권한 없음',
            )
          : meals.isEmpty
              ? const EmptyState(
                  '아직 오늘 올라온 사진이 없습니다.',
                  icon: Icons.no_photography_outlined,
                  title: '기록 없음',
                )
              : Column(
                  children: [
                    for (var i = 0; i < meals.length; i++)
                      MealRow(
                        meal: meals[i],
                        showDivider: i != meals.length - 1,
                      ),
                  ],
                ),
    );
  }

  // --- 오늘 운동 -----------------------------------------------------------

  Widget _workoutCard() {
    final workouts = _workouts;
    final sets =
        workouts?.fold<int>(0, (sum, w) => sum + w.sets.length) ?? 0;

    return SikpanCard(
      title: '오늘 운동',
      subtitle:
          workouts == null || workouts.isEmpty ? null : '$sets세트',
      icon: Icons.fitness_center_rounded,
      child: workouts == null
          ? const EmptyState(
              '멘티가 운동 조회를 켜야 보입니다.\n권한은 멘티만 바꿀 수 있습니다.',
              icon: Icons.lock_outline_rounded,
              title: '운동 조회 권한 없음',
            )
          : workouts.isEmpty
              ? const EmptyState(
                  '아직 오늘 기록이 없습니다.',
                  icon: Icons.fitness_center_rounded,
                  title: '기록 없음',
                )
              : Column(
                  children: [
                    for (var i = 0; i < workouts.length; i++)
                      _WorkoutRow(
                        workout: workouts[i],
                        showDivider: i != workouts.length - 1,
                      ),
                  ],
                ),
    );
  }

  // --- 대신 기록하기 -------------------------------------------------------

  Widget _delegateCard() {
    final c = context.c;
    final canWrite = _open('workout:write');
    final blocked = canWrite == false;

    return SikpanCard(
      title: '대신 기록하기',
      subtitle: '기록은 멘티의 것이고, 대리 기록에는 내 이름이 남습니다',
      icon: Icons.assignment_ind_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: _busy || blocked ? null : _logWorkoutFor,
            icon: _busy
                ? const SizedBox(
                    width: 17,
                    height: 17,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.photo_camera_rounded, size: 19),
            label: Text(_busy ? '읽는 중…' : '수첩 찍어서 운동 기록'),
          ),
          const SizedBox(height: Dim.s12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(blocked ? Icons.lock_outline_rounded : Icons.info_outline,
                  size: 15, color: blocked ? c.warn : c.ink3),
              const SizedBox(width: Dim.s8),
              Expanded(
                child: Text(
                  blocked
                      ? '운동 대리 기록이 닫혀 있습니다. 멘티가 켜야 열립니다.'
                      : '수첩 사진에서 세트를 읽어 그대로 넣습니다. 애매한 줄은 미확인으로 남습니다.',
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.4,
                    color: blocked ? c.warn : c.ink3,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Dim.s8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.monitor_weight_outlined, size: 15, color: c.ink3),
              const SizedBox(width: Dim.s8),
              Expanded(
                child: Text('체중은 대신 입력할 수 없습니다.',
                    style: TextStyle(
                        fontSize: 12.5, height: 1.4, color: c.ink3)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // --- 한 줄 남기기 --------------------------------------------------------

  Widget _commentCard() {
    final c = context.c;
    return SikpanCard(
      title: '한 줄 남기기',
      subtitle: '지적보다 인정이 기본이 되도록',
      icon: Icons.chat_bubble_outline_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _note,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _comment(),
                  decoration: const InputDecoration(
                      hintText: '한 줄 남기기 (예: 오늘 단백질 좋았어요)'),
                ),
              ),
              const SizedBox(width: Dim.s8),
              OutlinedButton(
                onPressed: _sending ? null : _comment,
                child: Text(_sending ? '보내는 중' : '남기기'),
              ),
            ],
          ),
          const SizedBox(height: Dim.s12),
          Text('코멘트는 권한과 상관없이 남길 수 있습니다. 알림은 하루 한 번으로 묶입니다.',
              style: TextStyle(fontSize: 12.5, height: 1.4, color: c.ink3)),
        ],
      ),
    );
  }
}

// =============================================================================
// 히어로
// =============================================================================

/// 멘티의 오늘을 한 장면으로.
///
/// 코치가 이 화면을 여는 이유는 "이 사람 오늘 어땠나"입니다. 예전에는 그걸 알려면
/// 목록 두 개를 눈으로 세어야 했습니다. 큰 숫자 하나와 상태 배지가 그 일을 대신
/// 합니다. 공유되지 않은 칸은 비워 두지 않고 "권한 없음"이라고 적습니다.
class _MenteeHero extends StatelessWidget {
  const _MenteeHero({
    required this.name,
    required this.card,
    required this.meals,
    required this.workouts,
  });

  final String name;
  final MenteeCard? card;
  final List<Meal>? meals;
  final List<Workout>? workouts;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final meals = this.meals;
    final workouts = this.workouts;

    final kcal = meals?.fold<double>(0, (sum, m) => sum + m.kcal);
    final sets = workouts?.fold<int>(0, (sum, w) => sum + w.sets.length);
    final stale = card?.staleDays;

    return SikpanCard(
      hero: true,
      padding: const EdgeInsets.fromLTRB(Dim.s20, Dim.s20, Dim.s20, Dim.s20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.accentSoft,
                  borderRadius: BorderRadius.circular(Dim.radiusSm),
                ),
                child: Text(
                  name.isEmpty ? '?' : name.substring(0, 1),
                  style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      color: c.accent),
                ),
              ),
              const SizedBox(width: Dim.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.4)),
                    const SizedBox(height: Dim.s2),
                    Text(_lastEntryLine(stale),
                        style: TextStyle(fontSize: 12.5, color: c.ink3)),
                  ],
                ),
              ),
              if (stale != null) _staleBadge(stale),
            ],
          ),

          if (meals != null) ...[
            const SizedBox(height: Dim.s20),
            Center(
              child: Column(
                children: [
                  AnimatedCount(
                    kcal ?? 0,
                    style: TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1.6,
                      height: 1.0,
                      color: c.ink,
                    ),
                    format: Fmt.kcal,
                  ),
                  const SizedBox(height: Dim.s4),
                  Text('오늘 섭취 kcal',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: c.ink2)),
                ],
              ),
            ),
            if (meals.isNotEmpty) ...[
              const SizedBox(height: Dim.s20),
              MacroBar(
                proteinG: meals.fold<double>(0, (s, m) => s + m.proteinG),
                carbG: meals.fold<double>(0, (s, m) => s + m.carbG),
                fatG: meals.fold<double>(0, (s, m) => s + m.fatG),
                showLegend: false,
              ),
            ],
          ],

          const SizedBox(height: Dim.s20),
          Divider(height: 1, color: c.lineSoft),
          const SizedBox(height: Dim.s20),

          StatRow(children: [
            StatBlock(
              value: meals == null ? '–' : '${meals.length}',
              label: '끼니',
              hint: meals == null ? '권한 없음' : null,
            ),
            StatBlock(
              value: sets == null ? '–' : '$sets',
              label: '운동 세트',
              hint: sets == null ? '권한 없음' : null,
            ),
            StatBlock(
              value: card == null ? '–' : Fmt.pct(card!.weekCompletion),
              label: '이번 주 기록',
              hint: card == null ? '요약 없음' : null,
            ),
          ]),

          if (card != null) ...[
            const SizedBox(height: Dim.s16),
            Meter(
              value: card!.weekCompletion,
              target: 1,
              warnOver: false,
              height: 6,
            ),
          ],
        ],
      ),
    );
  }

  String _lastEntryLine(int? stale) {
    if (stale == null) return '요약을 불러오지 못했습니다';
    if (stale == 0) return '오늘도 기록했습니다';
    if (stale >= 999) return '아직 기록이 하나도 없습니다';
    return '마지막 기록 $stale일 전';
  }

  Widget _staleBadge(int stale) {
    if (stale == 0) return const SikpanBadge('오늘 기록', tone: BadgeTone.accent);
    if (stale >= 999) return const SikpanBadge('기록 없음', tone: BadgeTone.warn);
    return SikpanBadge('$stale일째 미기록',
        tone: stale >= 3 ? BadgeTone.warn : BadgeTone.neutral);
  }
}

// =============================================================================
// 권한
// =============================================================================

/// 열려 있는 권한을 스코프 하나하나로.
///
/// 요약 한 줄만으로는 "사진은 볼 수 있나?" 같은 물음에 답하지 못합니다. 읽기와
/// 쓰기를 아이콘으로 구분해 두면 위험한 쪽(대리 기록)이 형태로도 드러납니다.
class _PermissionCard extends StatelessWidget {
  const _PermissionCard({required this.link, required this.onRetry});

  final Mentorship? link;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final link = this.link;

    return SikpanCard(
      title: '열려 있는 권한',
      subtitle: '멘티가 켠 것만 열립니다. 끄는 것도 멘티만 할 수 있습니다',
      icon: Icons.shield_outlined,
      child: link == null
          ? EmptyState(
              '연결 정보를 불러오지 못했습니다.',
              icon: Icons.help_outline_rounded,
              title: '권한을 확인할 수 없음',
              action: '다시 시도',
              onAction: onRetry,
            )
          : Column(
              children: [
                for (var i = 0; i < scopeLabel.length; i++)
                  _ScopeRow(
                    scope: scopeLabel.keys.elementAt(i),
                    open: link.permissions[scopeLabel.keys.elementAt(i)] ?? false,
                    showDivider: i != scopeLabel.length - 1,
                  ),
                const SizedBox(height: Dim.s12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.block_rounded, size: 15, color: c.ink3),
                    const SizedBox(width: Dim.s8),
                    Expanded(
                      child: Text(
                        '체중 대리 입력은 목록에 아예 없습니다 — 어떤 경우에도 열 수 없습니다.',
                        style: TextStyle(
                            fontSize: 12.5, height: 1.4, color: c.ink3),
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}

class _ScopeRow extends StatelessWidget {
  const _ScopeRow({
    required this.scope,
    required this.open,
    required this.showDivider,
  });

  final String scope;
  final bool open;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final isWrite = scope.endsWith(':write');
    final color = open ? (isWrite ? c.accentDeep : c.accent) : c.ink3;

    return ListRow(
      showDivider: showDivider,
      leading: Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: open ? c.accentSoft : c.surface2,
          borderRadius: BorderRadius.circular(Dim.radiusXs),
        ),
        child: Icon(
          isWrite ? Icons.edit_rounded : Icons.visibility_outlined,
          size: 15,
          color: color,
        ),
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(scopeLabel[scope] ?? scope,
              style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: open ? c.ink : c.ink3)),
          const SizedBox(height: Dim.s2),
          Text(isWrite ? '내가 대신 기록할 수 있습니다' : '보기만 합니다',
              style: TextStyle(fontSize: 11.5, color: c.ink3)),
        ],
      ),
      trailing: SikpanBadge(
        open ? (isWrite ? '대리 가능' : '열림') : '닫힘',
        tone: open ? BadgeTone.accent : BadgeTone.neutral,
      ),
    );
  }
}

// =============================================================================
// 운동 한 줄
// =============================================================================

class _WorkoutRow extends StatelessWidget {
  const _WorkoutRow({required this.workout, required this.showDivider});

  final Workout workout;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final w = workout;
    final detail = w.sets
        .map((s) =>
            '${s.exerciseName} ${s.weightKg?.round() ?? ""}×${s.reps ?? ""}')
        .join(', ');

    return ListRow(
      showDivider: showDivider,
      leading: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: BorderRadius.circular(Dim.radiusXs),
        ),
        child: Icon(Icons.fitness_center_rounded, size: 18, color: c.ink3),
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${w.sets.length}세트',
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          const SizedBox(height: Dim.s2),
          Text(
            detail.isEmpty ? '읽어낸 세트가 없습니다' : detail,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: c.ink2),
          ),
          if (w.unmatched.isNotEmpty) ...[
            const SizedBox(height: Dim.s6),
            SikpanBadge('미확인 ${w.unmatched.length}줄', tone: BadgeTone.warn),
          ],
        ],
      ),
    );
  }
}

// =============================================================================
// 로딩
// =============================================================================

/// 올 자리를 미리 그립니다. 가운데 스피너는 도착하는 순간 화면을 통째로
/// 튀게 만듭니다.
class _MenteeSkeleton extends StatelessWidget {
  const _MenteeSkeleton();

  @override
  Widget build(BuildContext context) {
    return const ScreenBody(animate: false, children: [
      SikpanCard(
        hero: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Skeleton(width: 44, height: 44, radius: Dim.radiusSm),
                SizedBox(width: Dim.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Skeleton(width: 110),
                      SizedBox(height: Dim.s8),
                      Skeleton(width: 80, height: 10),
                    ],
                  ),
                ),
              ],
            ),
            SizedBox(height: Dim.s24),
            Skeleton(height: 44, radius: Dim.radiusSm),
            SizedBox(height: Dim.s16),
            Skeleton(height: 10, radius: 99),
          ],
        ),
      ),
      SikpanCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Skeleton(width: 120),
            SizedBox(height: Dim.s20),
            Skeleton(height: 44, radius: Dim.radiusSm),
            SizedBox(height: Dim.s12),
            Skeleton(height: 44, radius: Dim.radiusSm),
          ],
        ),
      ),
      SikpanCard(child: Skeleton(height: 90, radius: Dim.radiusSm)),
    ]);
  }
}
