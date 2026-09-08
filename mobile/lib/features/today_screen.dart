import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../app_state.dart';
import '../theme/tokens.dart';
import '../ui/labels.dart';
import '../ui/meal_photo.dart';
import '../ui/widgets.dart';

class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key});

  @override
  State<TodayScreen> createState() => TodayScreenState();
}

class TodayScreenState extends State<TodayScreen>
    with DataListener<TodayScreen> {
  TodayView? _data;
  int _pendingUploads = 0;
  bool _loading = true;
  Timer? _poll;

  /// 보고 있는 날짜. 서버의 `/api/today`는 처음부터 `?date=`를 받고 있었는데
  /// 앱은 오늘에만 갇혀 있었습니다. 어제 저녁을 고치려면 앱을 열어도 방법이
  /// 없었다는 뜻입니다.
  late DateTime _date = _startOfToday();

  static DateTime _startOfToday() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  bool get _isToday => _sameDay(_date, _startOfToday());

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static String _key(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// [DataBus]가 부릅니다 — 업로드·수정·삭제·큐 전송 직후.
  @override
  Future<void> reload() => _load();

  void _selectDate(DateTime d) {
    if (_sameDay(d, _date)) return;
    setState(() {
      _date = d;
      _loading = true;
    });
    _load();
  }

  Future<void> _load() async {
    // 의존성은 첫 await 전에 잡아 둡니다. await 뒤의 context는 위젯이
    // 사라졌을 수 있어 InheritedWidget 조회가 안전하지 않습니다.
    final scope = AppScope.of(context);
    final wasPending = _data?.pending ?? 0;
    try {
      final json = await scope.api.get(
        '/today',
        query: _isToday ? null : {'date': _key(_date)},
      );
      final pending = await scope.outbox.count();
      if (!mounted) return;
      final next = TodayView.fromJson(json as Map<String, dynamic>);
      setState(() {
        _data = next;
        _pendingUploads = pending;
        _loading = false;
      });
      // 분석이 끝난 순간을 알려 줍니다. 폴링이 조용히 갱신만 하면, 사용자는
      // 자기가 올린 사진이 언제 결과가 됐는지 모릅니다.
      if (wasPending > 0 && next.pending == 0 && mounted) {
        showToast(context, '분석이 끝났습니다', tone: ToastTone.success);
      }
      _schedulePoll();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showToast(context, e.message, tone: ToastTone.error);
    } on OfflineException {
      if (!mounted) return;
      // 오프라인이어도 대기 장수는 갱신해 둡니다. 이게 없으면 방금 큐에 넣은
      // 사진이 화면 어디에도 나타나지 않습니다.
      final pending = await scope.outbox.count();
      if (!mounted) return;
      setState(() {
        _pendingUploads = pending;
        _loading = false;
      });
    }
  }

  /// 분석 중인 식사가 있으면 잠깐씩 다시 봅니다. 서버가 푸시를 보낼 방법이
  /// 아직 없어서, 사용자가 화면을 보고 있는 동안만 짧게 폴링합니다.
  void _schedulePoll() {
    _poll?.cancel();
    if ((_data?.pending ?? 0) == 0) return;
    _poll = Timer(const Duration(seconds: 3), () {
      if (mounted) _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;

    if (_loading && data == null) return const TodaySkeleton();
    if (data == null) {
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

    final s = data.summary;

    return ScreenBody(
      onRefresh: _load,
      children: [
        _DayStrip(
          selected: _date,
          onSelect: _selectDate,
        ),

        if (!_isToday)
          NoticeBanner(
            '${Fmt.date(_key(_date))} (${Fmt.weekday(_key(_date))})을 보고 있습니다',
            tone: BadgeTone.accent,
            icon: Icons.history_rounded,
            action: '오늘',
            onAction: () => _selectDate(_startOfToday()),
          ),

        if (_pendingUploads > 0)
          NoticeBanner(
            '사진 $_pendingUploads장이 전송을 기다립니다. 연결되면 자동으로 올라갑니다.',
            icon: Icons.cloud_upload_outlined,
          ),
        if (data.pending > 0)
          NoticeBanner(
            '식사 ${data.pending}건을 분석하고 있습니다',
            tone: BadgeTone.accent,
            busy: true,
          ),

        _Hero(summary: s, onSetGoal: () => context.go('/more')),

        if (data.quickSets.isNotEmpty) _QuickSets(sets: data.quickSets, onApply: _applySet),

        _MealList(
          meals: data.meals,
          onOpen: (id) => context.push('/meal/$id'),
        ),
      ],
    );
  }

  Future<void> _applySet(QuickSet set) async {
    try {
      await context.api.post('/meal-sets/${set.id}/apply');
      if (!mounted) return;
      showToast(context, '${set.name} 기록했습니다', tone: ToastTone.success);
      context.data.bump();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, tone: ToastTone.error);
    }
  }
}

// =============================================================================
// 날짜 선택
// =============================================================================

/// 최근 7일.
///
/// 앞으로 갈 수는 없습니다 — 아직 오지 않은 끼니를 기록할 일은 없고, 빈 미래
/// 날짜를 보여 주면 "왜 비어 있지"라는 질문만 만듭니다.
class _DayStrip extends StatelessWidget {
  const _DayStrip({required this.selected, required this.onSelect});

  final DateTime selected;
  final void Function(DateTime) onSelect;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = [for (var i = 6; i >= 0; i--) today.subtract(Duration(days: i))];

    return Row(
      children: [
        for (final d in days)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: _DayCell(
                day: d,
                isSelected: d == DateTime(selected.year, selected.month, selected.day),
                isToday: d == today,
                onTap: () => onSelect(d),
              ),
            ),
          ),
      ],
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.isSelected,
    required this.isToday,
    required this.onTap,
  });

  final DateTime day;
  final bool isSelected;
  final bool isToday;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    const wd = ['월', '화', '수', '목', '금', '토', '일'];

    return Pressable(
      onTap: onTap,
      scale: 0.92,
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.curve,
        padding: const EdgeInsets.symmetric(vertical: Dim.s8),
        decoration: BoxDecoration(
          color: isSelected ? c.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(Dim.radiusSm),
          boxShadow: isSelected && !c.isDark
              ? [
                  BoxShadow(
                    color: c.accent.withValues(alpha: 0.28),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  )
                ]
              : null,
        ),
        child: Column(
          children: [
            Text(
              wd[day.weekday - 1],
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: isSelected ? Colors.white70 : c.ink3,
              ),
            ),
            const SizedBox(height: Dim.s4),
            Text(
              '${day.day}',
              style: TextStyle(
                fontSize: 15,
                fontWeight: isToday ? FontWeight.w800 : FontWeight.w600,
                color: isSelected
                    ? Colors.white
                    : (isToday ? c.accent : c.ink2),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// 히어로
// =============================================================================

/// 하루를 한 장면으로.
///
/// 이전에는 큰 숫자 하나와 빈 회색 막대뿐이었습니다. "260"이 많은지 적은지 알
/// 수 없고, 목표가 없으면 막대는 영영 비어 있어 화면에서 가장 큰 면적이 아무
/// 말도 하지 않았습니다.
///
/// 링은 목표 대비 위치를 즉시 주고, 목표가 없을 때는 그 자리에서 목표를 정하러
/// 갈 수 있게 합니다 — 빈 상태가 안내가 되도록.
class _Hero extends StatelessWidget {
  const _Hero({required this.summary, required this.onSetGoal});

  final DaySummary summary;
  final VoidCallback onSetGoal;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final s = summary;
    final hasTarget = (s.targetKcal ?? 0) > 0;
    final remaining = s.remainingKcal;
    final over = remaining != null && remaining < 0;

    final big = TextStyle(
      fontSize: 44,
      fontWeight: FontWeight.w800,
      letterSpacing: -1.8,
      height: 1.0,
      color: over ? c.warn : c.ink,
    );

    return SikpanCard(
      hero: true,
      padding: const EdgeInsets.fromLTRB(Dim.s20, Dim.s24, Dim.s20, Dim.s20),
      child: Column(
        children: [
          CalorieRing(
            value: s.kcal,
            target: s.targetKcal,
            center: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedCount(
                  hasTarget ? (remaining ?? 0).abs() : s.kcal,
                  style: big,
                  format: (v) => Fmt.kcal(v),
                ),
                const SizedBox(height: Dim.s4),
                Text(
                  !hasTarget
                      ? 'kcal 섭취'
                      : over
                          ? 'kcal 초과'
                          : 'kcal 남음',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: over ? c.warn : c.ink2,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Dim.s20),

          if (hasTarget)
            Text(
              '섭취 ${Fmt.kcal(s.kcal)} · 목표 ${Fmt.kcal(s.targetKcal)}',
              style: TextStyle(fontSize: 13, color: c.ink2),
            )
          else
            Column(
              children: [
                Text('목표를 정하면 남은 양을 보여줍니다',
                    style: TextStyle(fontSize: 13, color: c.ink3)),
                const SizedBox(height: Dim.s12),
                OutlinedButton.icon(
                  onPressed: onSetGoal,
                  icon: const Icon(Icons.flag_outlined, size: 17),
                  label: const Text('목표 설정'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    padding:
                        const EdgeInsets.symmetric(horizontal: Dim.s16),
                  ),
                ),
              ],
            ),

          const SizedBox(height: Dim.s20),
          Divider(height: 1, color: c.lineSoft),
          const SizedBox(height: Dim.s20),

          MacroBar(
            proteinG: s.proteinG,
            carbG: s.carbG,
            fatG: s.fatG,
          ),

          if ((s.targetProteinG ?? 0) > 0) ...[
            const SizedBox(height: Dim.s20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('단백질 목표',
                    style: TextStyle(fontSize: 12, color: c.ink3)),
                Text('${Fmt.g(s.proteinG)} / ${Fmt.g(s.targetProteinG)}',
                    style: TextStyle(
                        fontSize: 12,
                        color: c.ink3,
                        fontFeatures: const [FontFeature.tabularFigures()])),
              ],
            ),
            const SizedBox(height: Dim.s8),
            Meter(
              value: s.proteinG,
              target: s.targetProteinG,
              warnOver: false,
              color: c.protein,
            ),
          ],
        ],
      ),
    );
  }
}

// =============================================================================
// 내 식사 세트
// =============================================================================

class _QuickSets extends StatelessWidget {
  const _QuickSets({required this.sets, required this.onApply});

  final List<QuickSet> sets;
  final void Function(QuickSet) onApply;

  @override
  Widget build(BuildContext context) {
    return SikpanCard(
      title: '내 식사 세트',
      subtitle: '두 번째부터는 한 번만 누르면 됩니다',
      icon: Icons.bolt_rounded,
      child: Wrap(
        spacing: Dim.s8,
        runSpacing: Dim.s8,
        children: [
          for (final set in sets)
            SikpanChip(
              label: '${set.name} · ${set.useCount}회',
              icon: Icons.add_rounded,
              selected: false,
              onTap: () => onApply(set),
            ),
        ],
      ),
    );
  }
}

// =============================================================================
// 오늘의 기록
// =============================================================================

class _MealList extends StatelessWidget {
  const _MealList({required this.meals, required this.onOpen});

  final List<Meal> meals;
  final void Function(int id) onOpen;

  @override
  Widget build(BuildContext context) {
    return SikpanCard(
      title: '오늘의 기록',
      subtitle: meals.isEmpty ? null : '${meals.length}끼',
      icon: Icons.receipt_long_rounded,
      child: meals.isEmpty
          ? const EmptyState(
              '아래 촬영 버튼을 누르면\n사진 한 장으로 시작합니다.',
              icon: Icons.photo_camera_outlined,
              title: '아직 기록이 없습니다',
            )
          : Column(
              children: [
                for (var i = 0; i < meals.length; i++)
                  MealRow(
                    meal: meals[i],
                    showDivider: i != meals.length - 1,
                    onTap: () => onOpen(meals[i].id),
                  ),
              ],
            ),
    );
  }
}

/// 식사 한 줄. 오늘 화면과 멘티 화면이 공유합니다.
///
/// 끼니 아이콘(달·해) 대신 **찍은 사진**을 보여줍니다. 앱이 이미 갖고 있던 가장
/// 좋은 정보였는데 상세 화면에만 있었습니다. 무엇을 먹었는지는 "흰쌀밥, 반찬
/// (미상)"이라는 글자보다 사진 한 장이 훨씬 빨리 알려줍니다.
class MealRow extends StatelessWidget {
  const MealRow({
    super.key,
    required this.meal,
    this.onTap,
    this.showDivider = true,
  });

  final Meal meal;
  final VoidCallback? onTap;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final badges = <Widget>[
      if (meal.isPending)
        const SikpanBadge('분석 중', spinner: true)
      else if (meal.isFailed)
        const SikpanBadge('실패', tone: BadgeTone.danger),
      if (meal.openMode)
        const SikpanBadge('식단표 없음 · 오차 큼', tone: BadgeTone.warn),
      if (meal.loggedByName != null)
        SikpanBadge('${meal.loggedByName}가 기록', tone: BadgeTone.accent),
      if (meal.cacheHit) const SikpanBadge('캐시'),
    ];

    return ListRow(
      onTap: onTap,
      showDivider: showDivider,
      chevron: onTap != null,
      leading: MealThumb(
        path: meal.photoPath,
        fallback: mealIcon[meal.mealType] ?? Icons.restaurant,
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(mealLabel[meal.mealType] ?? meal.mealType,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15)),
              ),
              if (meal.isReady)
                Text('${Fmt.kcal(meal.kcal)}kcal',
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: c.ink2,
                        fontFeatures: const [FontFeature.tabularFigures()])),
            ],
          ),
          const SizedBox(height: Dim.s2),
          Text(
            meal.items.isNotEmpty
                ? meal.items.map((i) => i.name).join(', ')
                : (meal.error ?? '—'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: c.ink2),
          ),
          if (badges.isNotEmpty) ...[
            const SizedBox(height: Dim.s6),
            Wrap(spacing: 5, runSpacing: 5, children: badges),
          ],
        ],
      ),
    );
  }
}
