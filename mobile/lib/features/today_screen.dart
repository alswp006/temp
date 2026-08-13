import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../app_state.dart';
import '../theme/tokens.dart';
import '../ui/labels.dart';
import '../ui/widgets.dart';

class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key});

  @override
  State<TodayScreen> createState() => TodayScreenState();
}

class TodayScreenState extends State<TodayScreen> {
  TodayView? _data;
  int _pendingUploads = 0;
  bool _loading = true;
  Timer? _poll;

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

  Future<void> _load() async {
    // 의존성은 첫 await 전에 잡아 둡니다. await 뒤의 context는 위젯이
    // 사라졌을 수 있어 InheritedWidget 조회가 안전하지 않습니다.
    final scope = AppScope.of(context);
    try {
      final json = await scope.api.get('/today');
      final pending = await scope.outbox.count();
      if (!mounted) return;
      setState(() {
        _data = TodayView.fromJson(json as Map<String, dynamic>);
        _pendingUploads = pending;
        _loading = false;
      });
      _schedulePoll();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showToast(context, e.message);
    } on OfflineException {
      if (!mounted) return;
      setState(() => _loading = false);
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
    final c = context.c;
    final data = _data;

    if (_loading && data == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (data == null) {
      return ScreenBody(children: [
        const EmptyState('불러오지 못했습니다.'),
        OutlinedButton(onPressed: _load, child: const Text('다시 시도')),
      ]);
    }

    final s = data.summary;
    final remaining = s.remainingKcal;
    final over = remaining != null && remaining < 0;

    return ScreenBody(
      onRefresh: _load,
      children: [
        if (_pendingUploads > 0)
          NoticeBanner('전송 대기 중인 사진 $_pendingUploads장 (연결되면 자동 전송)'),
        if (data.pending > 0)
          NoticeBanner('분석 중인 식사 ${data.pending}건',
              tone: BadgeTone.accent, busy: true),

        // --- 히어로: 남은 kcal --------------------------------------------
        SikpanCard(
          child: Column(
            children: [
              Text(
                remaining == null
                    ? Fmt.kcal(s.kcal)
                    : Fmt.kcal(remaining.abs()),
                style: TextStyle(
                  fontSize: 46,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1.5,
                  height: 1.05,
                  color: over ? c.warn : c.ink,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                remaining == null
                    ? '오늘 섭취 kcal · 목표 미설정'
                    : over
                        ? '목표보다 ${Fmt.kcal(remaining.abs())}kcal 초과'
                        : '남은 kcal · 목표 ${Fmt.kcal(s.targetKcal)}',
                style: TextStyle(fontSize: 13, color: c.ink2),
              ),
              const SizedBox(height: 16),
              Meter(value: s.kcal, target: s.targetKcal),
              const SizedBox(height: 18),
              StatRow(children: [
                StatBlock(value: Fmt.g(s.proteinG), label: '단백질'),
                StatBlock(value: Fmt.g(s.carbG), label: '탄수화물'),
                StatBlock(value: Fmt.g(s.fatG), label: '지방'),
              ]),
              if (s.targetProteinG != null && s.targetProteinG! > 0) ...[
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('단백질 목표',
                        style: TextStyle(fontSize: 12, color: c.ink3)),
                    Text('${Fmt.g(s.proteinG)} / ${Fmt.g(s.targetProteinG)}',
                        style: TextStyle(fontSize: 12, color: c.ink3)),
                  ],
                ),
                const SizedBox(height: 6),
                Meter(
                    value: s.proteinG,
                    target: s.targetProteinG,
                    warnOver: false),
              ],
            ],
          ),
        ),

        // --- 내 식사 세트 --------------------------------------------------
        if (data.quickSets.isNotEmpty)
          SikpanCard(
            title: '내 식사 세트',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final set in data.quickSets)
                      SikpanChip(
                        label: '${set.name} · ${set.useCount}회',
                        selected: false,
                        onTap: () => _applySet(set),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Text('두 번째부터는 한 번만 누르면 됩니다.',
                    style: TextStyle(fontSize: 12, color: c.ink3)),
              ],
            ),
          ),

        // --- 오늘의 기록 ---------------------------------------------------
        SikpanCard(
          title: '오늘의 기록 · ${data.meals.length}끼',
          child: data.meals.isEmpty
              ? const EmptyState('아직 기록이 없습니다.\n아래 촬영 버튼을 눌러 시작하세요.')
              : Column(
                  children: [
                    for (var i = 0; i < data.meals.length; i++)
                      MealRow(
                        meal: data.meals[i],
                        showDivider: i != data.meals.length - 1,
                        onTap: () => context.push('/meal/${data.meals[i].id}'),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Future<void> _applySet(QuickSet set) async {
    try {
      await context.api.post('/meal-sets/${set.id}/apply');
      if (!mounted) return;
      showToast(context, '${set.name} 기록했습니다');
      _load();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message);
    }
  }
}

/// 식사 한 줄. 오늘 화면과 멘티 화면이 공유합니다.
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
      leading: Container(
        width: 42,
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: BorderRadius.circular(Dim.radiusSm),
        ),
        child: Icon(mealIcon[meal.mealType] ?? Icons.restaurant,
            size: 21, color: c.ink2),
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
                        fontSize: 13,
                        color: c.ink2,
                        fontFeatures: const [FontFeature.tabularFigures()])),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            meal.items.isNotEmpty
                ? meal.items.map((i) => i.name).join(', ')
                : (meal.error ?? '—'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: c.ink2),
          ),
          if (badges.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(spacing: 5, runSpacing: 5, children: badges),
          ],
        ],
      ),
    );
  }
}
