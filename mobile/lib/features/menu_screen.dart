import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../app_state.dart';
import '../theme/tokens.dart';
import '../ui/labels.dart';
import '../ui/meal_photo.dart';
import '../ui/widgets.dart';
import 'capture.dart';

/// 끼니를 먹는 순서로 세웁니다. 서버가 주는 문자열을 그대로 정렬하면
/// breakfast·dinner·lunch — 조식·석식·중식이 되어 하루가 거꾸로 읽힙니다.
const _mealOrder = <String, int>{
  'breakfast': 0,
  'lunch': 1,
  'dinner': 2,
  'snack': 3,
};

/// 날짜만 남깁니다. 서버는 '2026-08-14'를 주지만 타임스탬프가 섞여 와도
/// 오늘 판정이 어긋나지 않도록 앞 열 글자로 자릅니다.
String _dayKey(String iso) => iso.length >= 10 ? iso.substring(0, 10) : iso;

String _todayKey() {
  final n = DateTime.now();
  return '${n.year}-${n.month.toString().padLeft(2, '0')}'
      '-${n.day.toString().padLeft(2, '0')}';
}

/// 오늘을 기준으로 한 그 날의 위치. 카드의 아이콘과 강조를 정합니다.
enum _When { past, today, upcoming }

class _DayGroup {
  const _DayGroup({required this.date, required this.plans});
  final String date;
  final List<MenuPlan> plans;
}

/// 주간 식단표.
///
/// 이 앱의 정확도가 나오는 곳입니다. 한 주에 한 명만 올리면 같은 식당 사람
/// 전부가 객관식 인식의 혜택을 받습니다.
///
/// 이전에는 날짜 카드가 전부 같은 모양으로 일곱 장 쌓여 있어서, 정작 지금 필요한
/// **오늘**을 눈으로 찾아야 했습니다. 오늘을 맨 위로 끌어올려 히어로로 두고,
/// 나머지 날은 그 아래에 접어 둡니다.
class MenuScreen extends StatefulWidget {
  const MenuScreen({super.key, required this.canteenId});
  final int canteenId;

  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> with DataListener<MenuScreen> {
  List<MenuPlan> _plans = const [];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// [DataBus]가 부릅니다 — 식단표를 저장했거나 신고한 직후.
  @override
  Future<void> reload() => _load();

  Future<void> _load() async {
    // 의존성은 첫 await 전에 잡아 둡니다. await 뒤의 context는 위젯이 사라졌을
    // 수 있어 InheritedWidget 조회가 안전하지 않습니다.
    final scope = AppScope.of(context);
    try {
      final list = (await scope.api
              .get('/canteens/${widget.canteenId}/menu-plans') as List)
          .map((e) => MenuPlan.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() {
        _plans = list;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showToast(context, e.message, tone: ToastTone.error);
    } on OfflineException {
      // 오프라인은 오류가 아닙니다. 마지막으로 받아 둔 표를 그대로 둡니다.
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _uploadBoard() async {
    final source = await askImageSource(
      context,
      title: '주간 식단표',
      subtitle: '벽에 붙은 표 한 장이면 이번 주가 채워집니다',
    );
    if (source == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final bytes = await MealCapture.pickBytes(source: source, maxEdge: 2000);
      if (bytes == null || !mounted) return;
      showToast(context, '식단표를 읽는 중…');

      final draft = await context.api.upload(
          '/canteens/${widget.canteenId}/menu-board', bytes,
          filename: 'board.jpg') as Map<String, dynamic>;
      final slots = ((draft['slots'] as List?) ?? const [])
          .map((e) => MenuDraftSlot.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;

      if (slots.isEmpty) {
        showToast(context, '읽어낸 메뉴가 없습니다. 사진을 다시 찍어 주세요.',
            tone: ToastTone.error);
        return;
      }

      // 저장 전에 사람이 확인합니다. 잘못 읽은 식단표는 그 식당 전원의
      // 인식을 망가뜨리므로 자동 저장하지 않습니다.
      final confirmed = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        backgroundColor: context.c.surface,
        shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(Dim.radiusXl)),
        ),
        builder: (context) => _DraftSheet(
          slots: slots,
          photoPath: draft['photo_path'] as String?,
        ),
      );
      if (confirmed != true || !mounted) return;

      await context.api.post(
        '/canteens/${widget.canteenId}/menu-plans',
        body: {
          'slots': slots.map((s) => s.toApplyJson()).toList(),
          'source': 'photo',
          'photo_path': draft['photo_path'],
        },
      );
      if (!mounted) return;
      showToast(context, '식단표를 저장했습니다. 이제 같은 식당 사람 모두가 씁니다.',
          tone: ToastTone.success);
      // 식단표가 생기면 오늘 화면의 인식 방식이 달라집니다. 알려야 합니다.
      context.data.bump();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, tone: ToastTone.error);
    } on OfflineException {
      if (mounted) {
        showToast(context, '오프라인입니다. 연결된 뒤 다시 올려 주세요.',
            tone: ToastTone.error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 신고는 남의 화면까지 바꿉니다. 무엇이 일어나는지 먼저 말해 줍니다.
  Future<void> _confirmReport(MenuPlan plan) async {
    final label = mealLabel[plan.mealType] ?? plan.mealType;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('메뉴가 다른가요?'),
        content: Text(
          '${Fmt.date(plan.date)} $label이(가) 실제와 다르다고 알립니다. '
          '두 명 이상이 신고하면 재확인 대상으로 내려갑니다.',
          style: const TextStyle(height: 1.45),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('신고')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _report(plan);
  }

  Future<void> _report(MenuPlan plan) async {
    try {
      final res = await context.api.post(
          '/canteens/${widget.canteenId}/menu-plans/${plan.id}/report',
          body: {'note': null}) as Map<String, dynamic>;
      if (!mounted) return;
      final reached = res['threshold_reached'] == true;
      showToast(
        context,
        reached ? '재확인 대상으로 표시했습니다' : '신고 ${res['reports']}건 접수했습니다',
        tone: reached ? ToastTone.success : ToastTone.neutral,
      );
      context.data.bump();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, tone: ToastTone.error);
    }
  }

  List<_DayGroup> _grouped() {
    final byDate = <String, List<MenuPlan>>{};
    for (final p in _plans) {
      byDate.putIfAbsent(_dayKey(p.date), () => <MenuPlan>[]).add(p);
    }
    final dates = byDate.keys.toList()..sort();
    return [
      for (final d in dates)
        _DayGroup(
          date: d,
          plans: byDate[d]!
            ..sort((a, b) => (_mealOrder[a.mealType] ?? 9)
                .compareTo(_mealOrder[b.mealType] ?? 9)),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final groups = _grouped();
    final today = _todayKey();

    _DayGroup? todayGroup;
    for (final g in groups) {
      if (g.date == today) todayGroup = g;
    }
    final others = [for (final g in groups) if (g.date != today) g];
    final unverified = _plans.where((p) => !p.verified).length;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('식단표',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
            Text(
              groups.isEmpty
                  ? '이번 주'
                  : '${Fmt.date(groups.first.date)} – ${Fmt.date(groups.last.date)}',
              style: TextStyle(fontSize: 12, color: c.ink3),
            ),
          ],
        ),
        toolbarHeight: 64,
        actions: [
          // 목록을 아래까지 훑지 않아도 언제나 올릴 수 있게.
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: Dim.s20),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              onPressed: _uploadBoard,
              tooltip: '식단표 올리기',
              icon: const Icon(Icons.add_a_photo_outlined, size: 21),
            ),
          const SizedBox(width: Dim.s4),
        ],
      ),
      body: _loading && _plans.isEmpty
          ? const _MenuSkeleton()
          : ScreenBody(
              onRefresh: _load,
              children: [
                if (unverified > 0)
                  NoticeBanner(
                    '신고가 쌓인 끼니 $unverified개가 있습니다. 표를 다시 찍어 올리면 바로잡힙니다.',
                    icon: Icons.report_gmailerrorred_rounded,
                    action: '다시 올리기',
                    onAction: _busy ? null : _uploadBoard,
                  ),

                // --- 오늘 (히어로) ------------------------------------------
                //
                // 화면에 들어온 사람의 질문은 거의 항상 "오늘 뭐 나와?"입니다.
                // 그 답이 맨 위에, 유일하게 초록으로 서 있습니다.
                if (groups.isEmpty)
                  _PromptCard(
                    title: '이번 주 식단표가 없습니다',
                    text: '표 사진 한 장이면 이번 주 전체가 채워집니다.\n'
                        '한 명만 올리면 같은 식당 사람 전부가 씁니다.',
                    busy: _busy,
                    onUpload: _uploadBoard,
                  )
                else if (todayGroup == null)
                  _PromptCard(
                    title: '오늘 식단표가 없습니다',
                    text: '다른 날은 등록돼 있습니다.\n오늘 칸만 사진으로 채워 주세요.',
                    busy: _busy,
                    onUpload: _uploadBoard,
                  )
                else
                  _DayCard(
                    group: todayGroup,
                    when: _When.today,
                    onReport: _confirmReport,
                  ),

                // --- 나머지 요일 --------------------------------------------
                if (others.isNotEmpty) ...[
                  const SectionHeader('이번 주 다른 날'),
                  for (final g in others)
                    _DayCard(
                      group: g,
                      when: g.date.compareTo(today) < 0
                          ? _When.past
                          : _When.upcoming,
                      onReport: _confirmReport,
                    ),
                ],

                if (groups.isNotEmpty)
                  _UploadCard(busy: _busy, onUpload: _uploadBoard),
              ],
            ),
    );
  }
}

// =============================================================================
// 날짜 카드
// =============================================================================

/// 하루치 식단표.
///
/// 오늘만 히어로 곡률 + 초록 톤을 씁니다. 나머지는 지난 날인지 앞으로 올 날인지
/// 아이콘으로만 구분합니다 — 색을 더 쓰면 오늘의 초록이 묻힙니다.
class _DayCard extends StatelessWidget {
  const _DayCard({
    required this.group,
    required this.when,
    required this.onReport,
  });

  final _DayGroup group;
  final _When when;
  final void Function(MenuPlan) onReport;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final isToday = when == _When.today;
    final plans = group.plans;

    return SikpanCard(
      hero: isToday,
      tone: isToday ? c.accent : null,
      icon: switch (when) {
        _When.today => Icons.today_rounded,
        _When.past => Icons.history_rounded,
        _When.upcoming => Icons.event_note_outlined,
      },
      title: '${Fmt.date(group.date)} (${Fmt.weekday(group.date)})',
      subtitle: isToday ? '오늘 나오는 메뉴' : null,
      trailing: isToday
          ? const SikpanBadge('오늘', tone: BadgeTone.accent)
          : Text('${plans.length}끼',
              style: TextStyle(fontSize: 12, color: c.ink3)),
      child: Column(
        children: [
          for (var i = 0; i < plans.length; i++)
            _MealRow(
              plan: plans[i],
              accent: isToday,
              showDivider: i != plans.length - 1,
              onReport: onReport,
            ),
        ],
      ),
    );
  }
}

class _MealRow extends StatelessWidget {
  const _MealRow({
    required this.plan,
    required this.accent,
    required this.showDivider,
    required this.onReport,
  });

  final MenuPlan plan;
  final bool accent;
  final bool showDivider;
  final void Function(MenuPlan) onReport;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final kcal =
        plan.items.fold<double>(0, (sum, i) => sum + (i.kcalPerServing ?? 0));

    return ListRow(
      showDivider: showDivider,
      leading: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: accent ? c.accentSoft : c.surface2,
          borderRadius: BorderRadius.circular(Dim.radiusSm),
        ),
        child: Icon(mealIcon[plan.mealType] ?? Icons.restaurant,
            size: 19, color: accent ? c.accent : c.ink3),
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 좁은 화면에서 배지가 밀려도 잘리지 않도록 Wrap으로 둡니다.
          Wrap(
            spacing: Dim.s6,
            runSpacing: Dim.s4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(mealLabel[plan.mealType] ?? plan.mealType,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700)),
              if (kcal > 0)
                Text('약 ${Fmt.kcal(kcal)}kcal',
                    style: TextStyle(
                        fontSize: 12,
                        color: c.ink3,
                        fontFeatures: const [FontFeature.tabularFigures()])),
              if (!plan.verified)
                const SikpanBadge('재확인 대상', tone: BadgeTone.warn),
            ],
          ),
          const SizedBox(height: Dim.s4),
          Text(
            plan.items.isEmpty
                ? '등록된 메뉴가 없습니다'
                : plan.items
                    .map((i) => '${i.name}(${i.standardG.round()}g)')
                    .join(' · '),
            style: TextStyle(fontSize: 13, height: 1.45, color: c.ink2),
          ),
        ],
      ),
      trailing: _ReportButton(onTap: () => onReport(plan)),
    );
  }
}

/// 메뉴 틀림 신고.
///
/// 예전에는 카드마다 "메뉴 틀림 신고" 한 줄이 통째로 붙어 있어, 하루에 세 끼면
/// 같은 문장이 세 번 반복됐습니다. 끼니 줄 오른쪽의 작은 알약으로 옮기면 필요할
/// 때만 눈에 들어옵니다.
class _ReportButton extends StatelessWidget {
  const _ReportButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Tooltip(
      message: '메뉴 틀림 신고',
      child: Pressable(
        onTap: onTap,
        scale: 0.92,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: Dim.s8 + 2, vertical: Dim.s6),
          decoration: BoxDecoration(
            color: c.surface2,
            borderRadius: BorderRadius.circular(99),
            border: Border.all(color: c.lineSoft),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.flag_outlined, size: 13, color: c.ink3),
              const SizedBox(width: Dim.s4),
              Text('신고',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: c.ink3)),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// 업로드
// =============================================================================

/// 표가 아예 없을 때의 히어로. 빈 화면을 "고장"이 아니라 "다음에 할 일"로.
class _PromptCard extends StatelessWidget {
  const _PromptCard({
    required this.title,
    required this.text,
    required this.busy,
    required this.onUpload,
  });

  final String title;
  final String text;
  final bool busy;
  final VoidCallback onUpload;

  @override
  Widget build(BuildContext context) {
    return SikpanCard(
      hero: true,
      padding: const EdgeInsets.fromLTRB(Dim.s20, Dim.s16, Dim.s20, Dim.s16),
      child: busy
          ? const EmptyState('식단표를 읽고 있습니다…', busy: true)
          : EmptyState(
              text,
              icon: Icons.event_note_rounded,
              title: title,
              action: '식단표 올리기',
              onAction: onUpload,
            ),
    );
  }
}

/// 표가 이미 있을 때의 보조 카드. 갱신 경로를 계속 열어 둡니다.
class _UploadCard extends StatelessWidget {
  const _UploadCard({required this.busy, required this.onUpload});

  final bool busy;
  final VoidCallback onUpload;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SikpanCard(
      title: '식단표 다시 올리기',
      subtitle: '표가 바뀌었거나 잘못 읽혔을 때',
      icon: Icons.upload_file_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: busy ? null : onUpload,
            icon: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.photo_camera_rounded, size: 19),
            label: Text(busy ? '읽는 중…' : '주간 식단표 올리기'),
          ),
          const SizedBox(height: Dim.s12),
          Text('한 주에 한 번, 한 명만 올리면 같은 식당 사람 전부가 씁니다.',
              style: TextStyle(fontSize: 12, height: 1.4, color: c.ink3)),
        ],
      ),
    );
  }
}

// =============================================================================
// 파싱 확인 시트
// =============================================================================

/// 읽어낸 식단표 초안. 저장 전 확인용.
///
/// 여기서 누르는 "저장"은 내 화면만 바꾸는 게 아니라 같은 식당 사람 전부의 인식
/// 기준을 바꿉니다. 그래서 (1) 몇 개를 읽었는지 숫자로 먼저 보이고, (2) 올린
/// 사진을 옆에 두어 눈으로 대조하게 하고, (3) 틀렸을 때 어떻게 되돌리는지를
/// 저장 전에 미리 알려 줍니다. 확신 없이 누르는 버튼이 되지 않도록.
class _DraftSheet extends StatelessWidget {
  const _DraftSheet({required this.slots, this.photoPath});

  final List<MenuDraftSlot> slots;
  final String? photoPath;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final today = _todayKey();

    final byDate = <String, List<MenuDraftSlot>>{};
    for (final s in slots) {
      byDate.putIfAbsent(_dayKey(s.date), () => <MenuDraftSlot>[]).add(s);
    }
    final dates = byDate.keys.toList()..sort();
    for (final d in dates) {
      byDate[d]!.sort((a, b) =>
          (_mealOrder[a.mealType] ?? 9).compareTo(_mealOrder[b.mealType] ?? 9));
    }
    final itemCount = slots.fold<int>(0, (n, s) => n + s.items.length);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      minChildSize: 0.5,
      maxChildSize: 0.94,
      builder: (context, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Dim.s20, 0, Dim.s20, Dim.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('이렇게 읽었습니다',
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: Dim.s4),
                Text('저장하기 전에 한 번만 봐 주세요. 여기서 맞으면 이번 주 내내 정확합니다.',
                    style:
                        TextStyle(fontSize: 13, height: 1.4, color: c.ink2)),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(Dim.s20, 0, Dim.s20, Dim.s24),
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(vertical: Dim.s16),
                  decoration: BoxDecoration(
                    color: c.surface2,
                    borderRadius: BorderRadius.circular(Dim.radius),
                  ),
                  child: StatRow(children: [
                    StatBlock(value: '${dates.length}', label: '날짜'),
                    StatBlock(value: '${slots.length}', label: '끼니'),
                    StatBlock(value: '$itemCount', label: '메뉴'),
                  ]),
                ),
                const SizedBox(height: Dim.s12),
                const NoticeBanner(
                  '틀린 게 있어도 되돌릴 수 있습니다. 저장한 뒤 그 끼니의 "신고"를 누르면 되고, '
                  '두 명이 신고하면 재확인 대상으로 내려갑니다.',
                  tone: BadgeTone.accent,
                  icon: Icons.verified_user_outlined,
                ),
                if (photoPath != null) ...[
                  const SizedBox(height: Dim.s20),
                  const SectionHeader('올린 사진'),
                  // 글자만 보여 주면 무엇과 비교해야 할지 알 수 없습니다.
                  MealPhoto(path: photoPath!, height: 170),
                ],
                const SizedBox(height: Dim.s20),
                const SectionHeader('읽어낸 끼니'),
                for (final d in dates) ...[
                  _DraftDay(
                    date: d,
                    slots: byDate[d]!,
                    isToday: d == today,
                  ),
                  const SizedBox(height: Dim.s12),
                ],
              ],
            ),
          ),
          _SheetActions(count: slots.length),
        ],
      ),
    );
  }
}

class _DraftDay extends StatelessWidget {
  const _DraftDay({
    required this.date,
    required this.slots,
    required this.isToday,
  });

  final String date;
  final List<MenuDraftSlot> slots;
  final bool isToday;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.all(Dim.s16),
      decoration: BoxDecoration(
        color: isToday
            ? c.accent.withValues(alpha: c.isDark ? 0.10 : 0.06)
            : c.surface2,
        borderRadius: BorderRadius.circular(Dim.radius),
        border: isToday
            ? Border.all(color: c.accent.withValues(alpha: 0.30))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${Fmt.date(date)} (${Fmt.weekday(date)})',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: isToday ? c.accent : c.ink,
                  ),
                ),
              ),
              if (isToday) const SikpanBadge('오늘', tone: BadgeTone.accent),
            ],
          ),
          for (final s in slots) ...[
            const SizedBox(height: Dim.s12),
            _DraftSlot(slot: s),
          ],
        ],
      ),
    );
  }
}

class _DraftSlot extends StatelessWidget {
  const _DraftSlot({required this.slot});
  final MenuDraftSlot slot;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 38,
          child: Padding(
            padding: const EdgeInsets.only(top: Dim.s4),
            child: Text(
              mealLabel[slot.mealType] ?? slot.mealType,
              style: TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w700, color: c.ink2),
            ),
          ),
        ),
        const SizedBox(width: Dim.s8),
        Expanded(
          child: slot.items.isEmpty
              ? Padding(
                  padding: const EdgeInsets.only(top: Dim.s4),
                  child: Text('읽어내지 못했습니다',
                      style: TextStyle(fontSize: 12.5, color: c.ink3)),
                )
              : Wrap(
                  spacing: Dim.s6,
                  runSpacing: Dim.s6,
                  children: [
                    for (final item in slot.items) _ItemPill(item: item),
                  ],
                ),
        ),
      ],
    );
  }
}

/// 메뉴 한 개. 쉼표로 이어 붙인 한 줄보다 알약이 세기 쉽습니다 — 확인 시트에서
/// 사용자가 실제로 하는 일이 사진과 개수를 맞춰 보는 것이기 때문입니다.
class _ItemPill extends StatelessWidget {
  const _ItemPill({required this.item});
  final MenuItem item;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: Dim.s8 + 2, vertical: Dim.s4),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: c.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(item.name,
              style: TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w600, color: c.ink)),
          const SizedBox(width: Dim.s4),
          Text('${item.standardG.round()}g',
              style: TextStyle(
                  fontSize: 11.5,
                  color: c.ink3,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }
}

class _SheetActions extends StatelessWidget {
  const _SheetActions({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.lineSoft)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding:
              const EdgeInsets.fromLTRB(Dim.s20, Dim.s12, Dim.s20, Dim.s8),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('취소'),
                ),
              ),
              const SizedBox(width: Dim.s12),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  onPressed: () => Navigator.pop(context, true),
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: Text('$count개 끼니 저장'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// 로딩
// =============================================================================

/// 가운데 스피너는 표가 도착하는 순간 화면을 통째로 튀게 만듭니다. 올 자리를
/// 미리 그려 두면 카드가 제자리에 내려앉습니다.
class _MenuSkeleton extends StatelessWidget {
  const _MenuSkeleton();

  @override
  Widget build(BuildContext context) {
    return const ScreenBody(animate: false, children: [
      SikpanCard(
        hero: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Skeleton(width: 150, height: 16),
            SizedBox(height: Dim.s20),
            Skeleton(height: 44, radius: Dim.radiusSm),
            SizedBox(height: Dim.s12),
            Skeleton(height: 44, radius: Dim.radiusSm),
          ],
        ),
      ),
      SikpanCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Skeleton(width: 110, height: 14),
            SizedBox(height: Dim.s16),
            Skeleton(height: 44, radius: Dim.radiusSm),
          ],
        ),
      ),
      SikpanCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Skeleton(width: 110, height: 14),
            SizedBox(height: Dim.s16),
            Skeleton(height: 44, radius: Dim.radiusSm),
          ],
        ),
      ),
    ]);
  }
}
