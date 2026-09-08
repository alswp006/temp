import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../app_state.dart';
import '../theme/tokens.dart';
import '../ui/labels.dart';
import '../ui/meal_photo.dart';
import '../ui/widgets.dart';

/// 식사 상세.
///
/// 이 앱에서 사진이 가장 크게 나오는 화면입니다. 이전에는 200px짜리 사진이
/// 카드들 맨 위에 그냥 박혀 있고, 그 아래로 똑같이 생긴 흰 카드 네 장이
/// 이어졌습니다. 무엇이 주인공인지 알 수 없었습니다.
///
/// 이제 **사진이 히어로**입니다. 사진 위에 끼니와 시각을 얹고, 바로 아래에
/// 칼로리와 영양소 비율을 붙여 "이 한 끼가 무엇이었나"를 한 장면으로 냅니다.
/// 나머지(고치기·항목·끼니·작업)는 그 아래 보조로 내려갑니다.
class MealDetailScreen extends StatefulWidget {
  const MealDetailScreen({super.key, required this.mealId});
  final int mealId;

  @override
  State<MealDetailScreen> createState() => _MealDetailScreenState();
}

class _MealDetailScreenState extends State<MealDetailScreen>
    with DataListener<MealDetailScreen> {
  final _edit = TextEditingController();
  final _editFocus = FocusNode();

  Meal? _meal;
  bool _loading = true;
  bool _applying = false;

  /// 끼니를 바꾸거나 다시 분석하는 동안. 결과가 붙기까지 몇 초 걸리므로,
  /// 그 사이가 "아무 일도 안 일어난 것"으로 보이면 사용자는 다시 누릅니다.
  bool _reanalyzing = false;

  /// 삭제한 뒤에는 다시 불러오지 않습니다. 삭제도 [DataBus.bump]를 부르는데,
  /// 화면이 사라지기 전에 그 신호를 받으면 방금 지운 식사를 다시 요청해
  /// "찾을 수 없습니다" 토스트가 오늘 화면 위로 따라 올라옵니다.
  bool _deleted = false;

  /// 자연어 수정 예시. 이 앱의 자랑인데, 힌트 한 줄로는 무엇까지 되는지
  /// 알 수 없어 대부분 쓰이지 않았습니다. 눌러서 넣고 고쳐 쓸 수 있게 둡니다.
  static const _examples = ['국 안 먹음', '밥 150으로', '고기 두 배', '김치 빼줘'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _edit.dispose();
    _editFocus.dispose();
    super.dispose();
  }

  /// [DataBus]가 부릅니다 — 다른 화면에서 이 식사가 바뀌었을 때.
  @override
  Future<void> reload() async {
    if (!_deleted) await _load();
  }

  Future<void> _load() async {
    // 의존성은 첫 await 전에 잡아 둡니다. await 뒤의 context는 위젯이
    // 사라졌을 수 있어 InheritedWidget 조회가 안전하지 않습니다.
    final api = context.api;
    try {
      final json = await api.get('/meals/${widget.mealId}');
      if (!mounted) return;
      setState(() {
        _meal = Meal.fromJson(json as Map<String, dynamic>);
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showToast(context, e.message, tone: ToastTone.error);
    } on OfflineException {
      if (!mounted) return;
      setState(() => _loading = false);
      showToast(context, '네트워크에 연결할 수 없습니다', tone: ToastTone.error);
    }
  }

  // ---------------------------------------------------------------------------
  // 자연어 수정
  // ---------------------------------------------------------------------------

  void _useExample(String text) {
    _edit.text = text;
    _edit.selection = TextSelection.collapsed(offset: text.length);
    _editFocus.requestFocus();
  }

  Future<void> _applyEdit() async {
    final text = _edit.text.trim();
    if (text.isEmpty) {
      _editFocus.requestFocus();
      return;
    }
    setState(() => _applying = true);
    try {
      final json = await context.api
          .post('/meals/${widget.mealId}/edit', body: {'text': text});
      final result = EditResult.fromJson(json as Map<String, dynamic>);
      if (!mounted) return;
      // 알아듣지 못한 문장과 반영된 문장이 같은 토스트로 뜨면, 고쳐졌는지
      // 아닌지를 항목을 뒤져 확인해야 합니다.
      showToast(context, result.message,
          tone: result.changed ? ToastTone.success : ToastTone.neutral);
      if (result.changed) {
        _edit.clear();
        _editFocus.unfocus();
        // 서버가 갱신된 식사를 함께 돌려주므로 한 번 더 부르지 않습니다.
        final mealJson = json['meal'] as Map<String, dynamic>?;
        if (mealJson != null) {
          setState(() => _meal = Meal.fromJson(mealJson));
        } else {
          await _load();
        }
        if (mounted) context.data.bump();
      }
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, tone: ToastTone.error);
    } on OfflineException {
      if (mounted) {
        showToast(context, '네트워크에 연결할 수 없습니다', tone: ToastTone.error);
      }
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  // ---------------------------------------------------------------------------
  // 끼니 · 재분석
  // ---------------------------------------------------------------------------

  Future<void> _changeSlot(String type) async {
    if (_meal?.mealType == type || _reanalyzing) return;
    setState(() => _reanalyzing = true);
    try {
      await context.api
          .patch('/meals/${widget.mealId}', body: {'meal_type': type});
      if (!mounted) return;
      showToast(context, '끼니를 바꾸고 다시 분석합니다', tone: ToastTone.success);
      // 재분석은 백그라운드 잡이라 잠시 뒤에 결과가 붙습니다.
      await Future<void>.delayed(const Duration(milliseconds: 1800));
      if (!mounted) return;
      await _load();
      if (mounted) context.data.bump();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, tone: ToastTone.error);
    } on OfflineException {
      if (mounted) {
        showToast(context, '네트워크에 연결할 수 없습니다', tone: ToastTone.error);
      }
    } finally {
      if (mounted) setState(() => _reanalyzing = false);
    }
  }

  Future<void> _retry() async {
    if (_reanalyzing) return;
    setState(() => _reanalyzing = true);
    final api = context.api;
    try {
      await api.post('/meals/${widget.mealId}/retry');
      if (!mounted) return;
      showToast(context, '다시 분석합니다', tone: ToastTone.success);
      // 재분석은 백그라운드 잡이라 결과가 붙기까지 잠깐 걸립니다.
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      await _load();
      if (mounted) context.data.bump();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, tone: ToastTone.error);
    } on OfflineException {
      if (mounted) {
        showToast(context, '네트워크에 연결할 수 없습니다', tone: ToastTone.error);
      }
    } finally {
      if (mounted) setState(() => _reanalyzing = false);
    }
  }

  // ---------------------------------------------------------------------------
  // 항목
  // ---------------------------------------------------------------------------

  Future<void> _editGrams(MealItem item) async {
    final controller =
        TextEditingController(text: item.finalG.round().toString());
    try {
      final grams = await showDialog<double>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(item.name),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(suffixText: 'g'),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(ctx, double.tryParse(controller.text)),
              child: const Text('저장'),
            ),
          ],
        ),
      );
      if (grams == null || grams <= 0 || !mounted) return;
      try {
        await context.api.patch('/meals/${widget.mealId}/items/${item.id}',
            body: {'final_g': grams});
        if (!mounted) return;
        await _load();
        if (!mounted) return;
        showToast(context, '${item.name} ${Fmt.g(grams)}으로 고쳤습니다',
            tone: ToastTone.success);
        context.data.bump();
      } on ApiException catch (e) {
        if (mounted) showToast(context, e.message, tone: ToastTone.error);
      } on OfflineException {
        if (mounted) {
          showToast(context, '네트워크에 연결할 수 없습니다', tone: ToastTone.error);
        }
      }
    } finally {
      controller.dispose();
    }
  }

  Future<void> _deleteItem(MealItem item) async {
    final ok = await _confirm(
      title: '${item.name}을(를) 뺄까요?',
      message: '이 항목의 칼로리와 영양소가 오늘 합계에서 빠집니다.',
      confirmLabel: '빼기',
    );
    if (!ok || !mounted) return;
    try {
      await context.api.delete('/meals/${widget.mealId}/items/${item.id}');
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      showToast(context, '${item.name}을(를) 뺐습니다', tone: ToastTone.success);
      context.data.bump();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, tone: ToastTone.error);
    } on OfflineException {
      if (mounted) {
        showToast(context, '네트워크에 연결할 수 없습니다', tone: ToastTone.error);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 작업
  // ---------------------------------------------------------------------------

  Future<void> _saveAsSet() async {
    final meal = _meal!;
    final controller =
        TextEditingController(text: '${mealLabel[meal.mealType] ?? ''} 기본');
    try {
      final name = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('세트 이름'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: '예: 아침 기본'),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('저장'),
            ),
          ],
        ),
      );
      if (name == null || name.isEmpty || !mounted) return;
      try {
        await context.api.post('/meal-sets/from-meal',
            body: {'meal_id': meal.id, 'name': name});
        if (!mounted) return;
        showToast(context, '$name 세트로 저장했습니다', tone: ToastTone.success);
        // 오늘 화면의 세트 목록이 바로 늘어나야 합니다.
        context.data.bump();
      } on ApiException catch (e) {
        if (mounted) showToast(context, e.message, tone: ToastTone.error);
      } on OfflineException {
        if (mounted) {
          showToast(context, '네트워크에 연결할 수 없습니다', tone: ToastTone.error);
        }
      }
    } finally {
      controller.dispose();
    }
  }

  Future<void> _deleteMeal() async {
    final ok = await _confirm(
      title: '이 식사를 삭제할까요?',
      message: '사진과 분석 결과가 함께 지워집니다. 되돌릴 수 없습니다.',
    );
    if (!ok || !mounted) return;
    try {
      await context.api.delete('/meals/${widget.mealId}');
      if (!mounted) return;
      _deleted = true;
      showToast(context, '식사를 삭제했습니다', tone: ToastTone.success);
      context.data.bump();
      context.go('/today');
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, tone: ToastTone.error);
    } on OfflineException {
      if (mounted) {
        showToast(context, '네트워크에 연결할 수 없습니다', tone: ToastTone.error);
      }
    }
  }

  /// 지우는 동작은 한 번 되묻습니다. 손가락이 스쳐서 사라지는 기록이 하나라도
  /// 있으면, 사용자는 그다음부터 이 화면을 조심스럽게 씁니다.
  Future<bool> _confirm({
    required String title,
    required String message,
    String confirmLabel = '삭제',
  }) async {
    final danger = context.c.danger;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        content: Text(message, style: const TextStyle(height: 1.45)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return ok == true;
  }

  // ---------------------------------------------------------------------------
  // 화면
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final meal = _meal;

    return Scaffold(
      appBar: AppBar(
        title: const Text('식사 상세',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
      ),
      body: _loading && meal == null
          ? const _DetailSkeleton()
          : meal == null
              ? ScreenBody(children: [
                  EmptyState(
                    '지워졌거나, 연결이 끊겼을 수 있습니다.',
                    icon: Icons.no_meals_rounded,
                    title: '식사를 찾을 수 없습니다',
                    action: '다시 시도',
                    onAction: _load,
                  ),
                ])
              : ScreenBody(
                  onRefresh: _load,
                  children: [
                    // --- 알림 --------------------------------------------
                    if (meal.isPending)
                      const NoticeBanner(
                        '사진을 분석하고 있습니다. 끝나면 항목과 칼로리가 채워집니다.',
                        tone: BadgeTone.accent,
                        busy: true,
                      ),
                    if (meal.isFailed)
                      NoticeBanner(
                        meal.error ?? '분석에 실패했습니다.',
                        tone: BadgeTone.danger,
                        action: _reanalyzing ? null : '다시 분석',
                        onAction: _retry,
                      ),
                    if (meal.openMode)
                      const NoticeBanner(
                        '이 끼니의 식단표가 없어 열린 인식 모드로 분석했습니다. '
                        '끼니를 잘못 잡았다면 아래에서 바꿔 주세요 — 식단표가 붙으면 정확해집니다.',
                      ),

                    // --- 히어로: 사진 ------------------------------------
                    _PhotoHero(meal: meal),

                    // --- 한 줄로 고치기 ----------------------------------
                    _EditCard(
                      controller: _edit,
                      focusNode: _editFocus,
                      applying: _applying,
                      examples: _examples,
                      onExample: _useExample,
                      onApply: _applyEdit,
                    ),

                    // --- 항목 ---------------------------------------------
                    SikpanCard(
                      title: '항목',
                      subtitle: meal.items.isEmpty
                          ? null
                          : '${meal.items.length}가지 · 막대는 AI의 확신 정도',
                      icon: Icons.checklist_rounded,
                      child: meal.items.isEmpty
                          ? EmptyState(
                              meal.isPending
                                  ? '분석이 끝나면 여기에 채워집니다.'
                                  : '위에서 "밥 150" 처럼 적으면 항목을 더할 수 있습니다.',
                              icon: Icons.ramen_dining_outlined,
                              title: '항목이 없습니다',
                            )
                          : Column(
                              children: [
                                for (var i = 0; i < meal.items.length; i++)
                                  _ItemRow(
                                    item: meal.items[i],
                                    showDivider: i != meal.items.length - 1,
                                    onEdit: () => _editGrams(meal.items[i]),
                                    onDelete: () => _deleteItem(meal.items[i]),
                                  ),
                              ],
                            ),
                    ),

                    // --- 끼니 ---------------------------------------------
                    SikpanCard(
                      title: '끼니',
                      subtitle: '바꾸면 그 끼니의 식단표로 다시 분석합니다',
                      icon: Icons.schedule_rounded,
                      trailing: _reanalyzing
                          ? const SikpanBadge('다시 분석 중',
                              tone: BadgeTone.accent, spinner: true)
                          : null,
                      child: Wrap(
                        spacing: Dim.s8,
                        runSpacing: Dim.s8,
                        children: [
                          for (final type in const [
                            'breakfast',
                            'lunch',
                            'dinner',
                            'snack'
                          ])
                            SikpanChip(
                              label: mealLabel[type]!,
                              icon: mealIcon[type],
                              selected: meal.mealType == type,
                              onTap: () => _changeSlot(type),
                            ),
                        ],
                      ),
                    ),

                    // --- 작업 ---------------------------------------------
                    SikpanCard(
                      title: '이 기록으로',
                      icon: Icons.more_horiz_rounded,
                      padding: const EdgeInsets.fromLTRB(
                          Dim.s16, Dim.s16, Dim.s16, Dim.s4),
                      child: Column(
                        children: [
                          _ActionRow(
                            icon: Icons.bookmark_add_outlined,
                            label: '내 식사 세트로 저장',
                            hint: '다음부터 한 번 눌러 기록합니다',
                            onTap: _saveAsSet,
                          ),
                          if (meal.isFailed)
                            _ActionRow(
                              icon: Icons.refresh_rounded,
                              label: '다시 분석',
                              hint: '같은 사진으로 한 번 더 시도합니다',
                              onTap: _reanalyzing ? null : _retry,
                            ),
                          _ActionRow(
                            icon: Icons.delete_outline_rounded,
                            label: '식사 삭제',
                            hint: '사진과 분석 결과가 함께 지워집니다',
                            danger: true,
                            showDivider: false,
                            onTap: _deleteMeal,
                          ),
                        ],
                      ),
                    ),

                    Padding(
                      padding: const EdgeInsets.only(top: Dim.s4),
                      child: Text(
                        '기록 시각 ${Fmt.dateTime(meal.shotAt)}',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11.5, color: c.ink3),
                      ),
                    ),
                  ],
                ),
    );
  }
}

// =============================================================================
// 히어로 — 사진
// =============================================================================

/// 사진 한 장 + 그 끼니의 요약.
///
/// 사진은 이 화면이 가진 가장 좋은 정보입니다. 화면 폭을 다 쓰고, 카드와 같은
/// 곡률로 잘라 카드의 일부처럼 보이게 합니다. 끼니와 시각은 사진 위에 얹어
/// 카드 안쪽 공간을 숫자에 양보합니다.
class _PhotoHero extends StatelessWidget {
  const _PhotoHero({required this.meal});

  final Meal meal;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final photo = meal.photoPath;
    final width = MediaQuery.sizeOf(context).width - Dim.screenH * 2;
    final photoHeight = (width * 0.72).clamp(200.0, 320.0);
    final slot = mealLabel[meal.mealType] ?? meal.mealType;

    final status = <Widget>[
      if (meal.isPending) const SikpanBadge('분석 중', spinner: true),
      if (meal.isFailed) const SikpanBadge('분석 실패', tone: BadgeTone.danger),
      if (meal.openMode)
        const SikpanBadge('식단표 없음 · 오차 큼', tone: BadgeTone.warn),
    ];

    final meta = <Widget>[
      if (meal.loggedByName != null)
        SikpanBadge('${meal.loggedByName}가 기록함', tone: BadgeTone.accent),
      if (meal.cacheHit) const SikpanBadge('캐시'),
      if (meal.callsUsed > 0) SikpanBadge('AI 호출 ${meal.callsUsed}회'),
    ];

    return SikpanCard(
      hero: true,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (photo != null)
            ClipRRect(
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(Dim.radiusXl)),
              child: Stack(
                children: [
                  MealPhoto(path: photo, height: photoHeight, radius: 0),
                  // 사진 아래쪽만 어둡게 깔아 흰 접시 위에서도 글씨가 읽히게.
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.center,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.62),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: Dim.s20,
                    right: Dim.s20,
                    bottom: Dim.s16,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Icon(mealIcon[meal.mealType] ?? Icons.restaurant,
                            size: 18, color: Colors.white),
                        const SizedBox(width: Dim.s8),
                        Expanded(
                          child: Text(
                            slot,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.4,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        Text(
                          Fmt.time(meal.shotAt),
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.white.withValues(alpha: 0.88),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(Dim.s20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 사진이 없으면(수동 기록·세트 적용) 끼니와 시각이 갈 곳이
                // 없습니다. 그때만 카드 안에 세웁니다.
                if (photo == null) ...[
                  Row(
                    children: [
                      Icon(mealIcon[meal.mealType] ?? Icons.restaurant,
                          size: 17, color: c.ink2),
                      const SizedBox(width: Dim.s8),
                      Expanded(
                        child: Text(slot,
                            style: const TextStyle(
                                fontSize: 17, fontWeight: FontWeight.w700)),
                      ),
                      Text(Fmt.time(meal.shotAt),
                          style: TextStyle(fontSize: 13, color: c.ink3)),
                    ],
                  ),
                  const SizedBox(height: Dim.s16),
                ],

                if (status.isNotEmpty) ...[
                  Wrap(spacing: 5, runSpacing: 5, children: status),
                  const SizedBox(height: Dim.s12),
                ],

                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    AnimatedCount(
                      meal.kcal,
                      style: TextStyle(
                        fontSize: 40,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1.6,
                        height: 1.0,
                        color: c.ink,
                      ),
                      format: (v) => Fmt.kcal(v),
                    ),
                    const SizedBox(width: Dim.s6),
                    Text('kcal',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: c.ink3)),
                  ],
                ),

                const SizedBox(height: Dim.s20),
                MacroBar(
                  proteinG: meal.proteinG,
                  carbG: meal.carbG,
                  fatG: meal.fatG,
                ),

                if (meta.isNotEmpty) ...[
                  const SizedBox(height: Dim.s20),
                  Divider(height: 1, color: c.lineSoft),
                  const SizedBox(height: Dim.s16),
                  Wrap(spacing: 5, runSpacing: 5, children: meta),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// 한 줄로 고치기
// =============================================================================

/// 자연어 수정.
///
/// 이 앱이 다른 기록 앱과 다른 지점입니다. 그런데 이전에는 화면 아래쪽에
/// 다른 카드들과 똑같은 모습으로 앉아 있어, 있는 줄도 모르고 지나갔습니다.
/// 강조색을 머금은 카드로 올리고, 무엇을 적을 수 있는지 예시를 눌러 넣게 합니다.
class _EditCard extends StatelessWidget {
  const _EditCard({
    required this.controller,
    required this.focusNode,
    required this.applying,
    required this.examples,
    required this.onExample,
    required this.onApply,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool applying;
  final List<String> examples;
  final void Function(String) onExample;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SikpanCard(
      title: '한 줄로 고치기',
      subtitle: '말하듯 적으면 항목이 바뀝니다',
      icon: Icons.auto_fix_high_rounded,
      tone: c.accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  enabled: !applying,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => onApply(),
                  decoration: InputDecoration(
                    hintText: '예: 밥 150으로',
                    fillColor: c.surface,
                    prefixIcon:
                        Icon(Icons.edit_note_rounded, size: 20, color: c.ink3),
                  ),
                ),
              ),
              const SizedBox(width: Dim.s8),
              SizedBox(
                width: 78,
                child: FilledButton(
                  onPressed: applying ? null : onApply,
                  child: applying
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('적용'),
                ),
              ),
            ],
          ),
          const SizedBox(height: Dim.s12),
          Wrap(
            spacing: Dim.s8,
            runSpacing: Dim.s8,
            children: [
              for (final example in examples)
                SikpanChip(
                  label: example,
                  selected: false,
                  onTap: () => onExample(example),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// 항목
// =============================================================================

/// 항목 한 줄.
///
/// 이전에는 신뢰도가 "확인 필요 40%" 배지 하나였습니다. 배지는 낮을 때만 떠서
/// 나머지 항목이 얼마나 믿을 만한지는 알 수 없었고, 숫자는 읽어야만 뜻이
/// 생겼습니다. 이제 모든 줄에 얇은 막대가 깔립니다 — 길이로 한 번, 색으로 한 번.
///
/// 왼쪽 색 띠가 줄의 성격을 말합니다. 초록은 사람이 고쳐 확정한 것, 주황은
/// 확인이 필요한 것, 회색은 그대로 두어도 되는 것.
class _ItemRow extends StatelessWidget {
  const _ItemRow({
    required this.item,
    required this.onEdit,
    required this.onDelete,
    required this.showDivider,
  });

  final MealItem item;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final edited = item.editedByUser;
    final unsure = !edited && item.confidence < 0.6;
    final tone = edited ? c.accent : (unsure ? c.warn : c.ink3);
    final label = edited
        ? '내가 고침'
        : unsure
            ? '확인 필요 ${Fmt.pct(item.confidence)}'
            : '확신 ${Fmt.pct(item.confidence)}';

    return ListRow(
      showDivider: showDivider,
      leading: Container(
        width: 3,
        height: 38,
        decoration: BoxDecoration(
          color: edited || unsure ? tone : c.lineSoft,
          borderRadius: BorderRadius.circular(99),
        ),
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(item.name,
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: edited ? c.accent : c.ink)),
              ),
              const SizedBox(width: Dim.s8),
              Text('${Fmt.kcal(item.kcal)}kcal',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: c.ink2,
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ],
          ),
          const SizedBox(height: Dim.s4),
          Text(
            '${categoryLabel[item.category] ?? item.category} · '
            '${Fmt.g(item.finalG)} · ×${item.portionRatio}',
            style: TextStyle(
                fontSize: 12,
                color: c.ink3,
                fontFeatures: const [FontFeature.tabularFigures()]),
          ),
          const SizedBox(height: Dim.s8),
          Row(
            children: [
              Expanded(
                child: Meter(
                  value: edited ? 1 : item.confidence,
                  target: 1,
                  warnOver: false,
                  height: 4,
                  color: tone,
                ),
              ),
              const SizedBox(width: Dim.s8),
              Text(label,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: edited || unsure ? tone : c.ink3)),
            ],
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: onEdit,
            icon: const Icon(Icons.tune, size: 20),
            tooltip: '중량 수정',
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            onPressed: onDelete,
            icon: Icon(Icons.close, size: 20, color: c.danger),
            tooltip: '삭제',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// 작업 줄
// =============================================================================

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.hint,
    this.danger = false,
    this.showDivider = true,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final String? hint;
  final bool danger;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final fg = danger ? c.danger : c.ink;
    return ListRow(
      onTap: onTap,
      showDivider: showDivider,
      leading: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: danger ? c.danger.withValues(alpha: 0.12) : c.surface2,
          borderRadius: BorderRadius.circular(Dim.radiusSm),
        ),
        child: Icon(icon, size: 19, color: danger ? c.danger : c.ink2),
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 14.5, fontWeight: FontWeight.w600, color: fg)),
          if (hint != null) ...[
            const SizedBox(height: Dim.s2),
            Text(hint!, style: TextStyle(fontSize: 11.5, color: c.ink3)),
          ],
        ],
      ),
      trailing: Icon(Icons.chevron_right_rounded,
          size: 20, color: danger ? c.danger.withValues(alpha: 0.7) : c.ink3),
    );
  }
}

// =============================================================================
// 로딩
// =============================================================================

/// 사진이 올 자리를 미리 그립니다. 가운데 스피너만 돌다가 내용이 도착하면
/// 화면이 통째로 튀고, 그 순간이 앱을 가장 싸구려로 보이게 합니다.
class _DetailSkeleton extends StatelessWidget {
  const _DetailSkeleton();

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width - Dim.screenH * 2;
    final photoHeight = (width * 0.72).clamp(200.0, 320.0);

    return ScreenBody(animate: false, children: [
      SikpanCard(
        hero: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Skeleton(height: photoHeight, radius: Dim.radius),
            const SizedBox(height: Dim.s20),
            const Skeleton(width: 130, height: 34),
            const SizedBox(height: Dim.s20),
            const Skeleton(height: 10, radius: 99),
          ],
        ),
      ),
      const SikpanCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Skeleton(width: 110),
            SizedBox(height: Dim.s16),
            Skeleton(height: 46, radius: Dim.radiusSm),
          ],
        ),
      ),
      const SikpanCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Skeleton(width: 80),
            SizedBox(height: Dim.s16),
            Skeleton(height: 40, radius: Dim.radiusSm),
            SizedBox(height: Dim.s12),
            Skeleton(height: 40, radius: Dim.radiusSm),
          ],
        ),
      ),
    ]);
  }
}
