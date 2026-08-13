import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../app_state.dart';
import '../theme/tokens.dart';
import '../ui/labels.dart';
import '../ui/meal_photo.dart';
import '../ui/widgets.dart';

class MealDetailScreen extends StatefulWidget {
  const MealDetailScreen({super.key, required this.mealId});
  final int mealId;

  @override
  State<MealDetailScreen> createState() => _MealDetailScreenState();
}

class _MealDetailScreenState extends State<MealDetailScreen> {
  final _edit = TextEditingController();
  Meal? _meal;
  bool _loading = true;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _edit.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final json = await context.api.get('/meals/${widget.mealId}');
      if (!mounted) return;
      setState(() {
        _meal = Meal.fromJson(json as Map<String, dynamic>);
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showToast(context, e.message);
    }
  }

  Future<void> _applyEdit() async {
    final text = _edit.text.trim();
    if (text.isEmpty) return;
    setState(() => _applying = true);
    try {
      final json = await context.api
          .post('/meals/${widget.mealId}/edit', body: {'text': text});
      final result = EditResult.fromJson(json as Map<String, dynamic>);
      if (!mounted) return;
      showToast(context, result.message);
      if (result.changed) {
        _edit.clear();
        HapticFeedback.lightImpact();
        // 서버가 갱신된 식사를 함께 돌려주므로 한 번 더 부르지 않습니다.
        final mealJson = json['meal'] as Map<String, dynamic>?;
        if (mealJson != null) {
          setState(() => _meal = Meal.fromJson(mealJson));
        } else {
          await _load();
        }
      }
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  Future<void> _changeSlot(String type) async {
    if (_meal?.mealType == type) return;
    try {
      await context.api
          .patch('/meals/${widget.mealId}', body: {'meal_type': type});
      if (!mounted) return;
      showToast(context, '끼니를 바꾸고 다시 분석합니다');
      // 재분석은 백그라운드 잡이라 잠시 뒤에 결과가 붙습니다.
      await Future<void>.delayed(const Duration(milliseconds: 1800));
      if (mounted) await _load();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message);
    }
  }

  Future<void> _editGrams(MealItem item) async {
    final controller =
        TextEditingController(text: item.finalG.round().toString());
    final grams = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(item.name),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(suffixText: 'g'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('취소')),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, double.tryParse(controller.text)),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (grams == null || grams <= 0 || !mounted) return;
    try {
      await context.api.patch(
          '/meals/${widget.mealId}/items/${item.id}',
          body: {'final_g': grams});
      if (mounted) await _load();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message);
    }
  }

  Future<void> _deleteItem(MealItem item) async {
    try {
      await context.api.delete('/meals/${widget.mealId}/items/${item.id}');
      if (mounted) await _load();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message);
    }
  }

  Future<void> _saveAsSet() async {
    final meal = _meal!;
    final controller = TextEditingController(
        text: '${mealLabel[meal.mealType] ?? ''} 기본');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('세트 이름'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('취소')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    try {
      await context.api.post('/meal-sets/from-meal',
          body: {'meal_id': meal.id, 'name': name});
      if (mounted) showToast(context, '세트로 저장했습니다');
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message);
    }
  }

  Future<void> _retry() async {
    final api = context.api;
    try {
      await api.post('/meals/${widget.mealId}/retry');
      if (!mounted) return;
      showToast(context, '다시 분석합니다');
      // 재분석은 백그라운드 잡이라 결과가 붙기까지 잠깐 걸립니다.
      await Future<void>.delayed(const Duration(seconds: 2));
      if (mounted) await _load();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message);
    }
  }

  Future<void> _deleteMeal() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('이 식사를 삭제할까요?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.c.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.api.delete('/meals/${widget.mealId}');
      if (mounted) context.go('/today');
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final meal = _meal;

    return Scaffold(
      appBar: AppBar(
        title: const Text('식사 상세',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : meal == null
              ? const EmptyState('식사를 찾을 수 없습니다.')
              : ScreenBody(
                  onRefresh: _load,
                  children: [
                    if (meal.photoPath != null)
                      MealPhoto(path: meal.photoPath!),
                    if (meal.openMode)
                      const NoticeBanner(
                          '이 끼니의 식단표가 없어 열린 인식 모드로 분석했습니다. '
                          '끼니를 잘못 잡았다면 아래에서 바꿔 주세요 — 식단표가 붙으면 정확해집니다.'),

                    // --- 요약 -------------------------------------------
                    SikpanCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${mealLabel[meal.mealType]} · ${Fmt.time(meal.shotAt)}',
                                  style: const TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w700),
                                ),
                              ),
                              Text('${Fmt.kcal(meal.kcal)}kcal',
                                  style: TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w700,
                                      color: c.accent)),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 12,
                            runSpacing: 4,
                            children: [
                              Text('단백질 ${Fmt.g(meal.proteinG)}',
                                  style: TextStyle(fontSize: 13, color: c.ink2)),
                              Text('탄수 ${Fmt.g(meal.carbG)}',
                                  style: TextStyle(fontSize: 13, color: c.ink2)),
                              Text('지방 ${Fmt.g(meal.fatG)}',
                                  style: TextStyle(fontSize: 13, color: c.ink2)),
                              if (meal.callsUsed > 0)
                                Text('AI 호출 ${meal.callsUsed}회',
                                    style:
                                        TextStyle(fontSize: 13, color: c.ink3)),
                            ],
                          ),
                          if (meal.loggedByName != null) ...[
                            const SizedBox(height: 10),
                            SikpanBadge('${meal.loggedByName}가 기록함',
                                tone: BadgeTone.accent),
                          ],
                        ],
                      ),
                    ),

                    // --- 끼니 -------------------------------------------
                    SikpanCard(
                      title: '끼니',
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final type in const [
                            'breakfast',
                            'lunch',
                            'dinner',
                            'snack'
                          ])
                            SikpanChip(
                              label: mealLabel[type]!,
                              selected: meal.mealType == type,
                              onTap: () => _changeSlot(type),
                            ),
                        ],
                      ),
                    ),

                    // --- 항목 -------------------------------------------
                    SikpanCard(
                      title: '항목',
                      child: meal.items.isEmpty
                          ? const EmptyState('항목이 없습니다')
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

                    // --- 한 줄로 고치기 ----------------------------------
                    SikpanCard(
                      title: '한 줄로 고치기',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _edit,
                                  textInputAction: TextInputAction.send,
                                  onSubmitted: (_) => _applyEdit(),
                                  decoration: const InputDecoration(
                                      hintText: '예: 밥 150으로'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                onPressed: _applying ? null : _applyEdit,
                                child: const Text('적용'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text('"국 안 먹음", "고기 두 배"처럼 말하듯 고칠 수 있습니다.',
                              style: TextStyle(fontSize: 12, color: c.ink3)),
                        ],
                      ),
                    ),

                    // --- 액션 -------------------------------------------
                    Column(
                      children: [
                        OutlinedButton(
                          onPressed: _saveAsSet,
                          child: const SizedBox(
                              width: double.infinity,
                              child: Center(child: Text('내 식사 세트로 저장'))),
                        ),
                        if (meal.isFailed) ...[
                          const SizedBox(height: 10),
                          OutlinedButton(
                            onPressed: _retry,
                            child: const SizedBox(
                                width: double.infinity,
                                child: Center(child: Text('다시 분석'))),
                          ),
                        ],
                        const SizedBox(height: 10),
                        OutlinedButton(
                          onPressed: _deleteMeal,
                          style: OutlinedButton.styleFrom(
                              foregroundColor: c.danger,
                              side: BorderSide(
                                  color: c.danger.withValues(alpha: 0.5))),
                          child: const SizedBox(
                              width: double.infinity,
                              child: Center(child: Text('식사 삭제'))),
                        ),
                      ],
                    ),
                  ],
                ),
    );
  }
}

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
    return ListRow(
      showDivider: showDivider,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(item.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15)),
              ),
              Text('${Fmt.kcal(item.kcal)}kcal',
                  style: TextStyle(
                      fontSize: 13,
                      color: c.ink2,
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(categoryLabel[item.category] ?? item.category,
                  style: TextStyle(fontSize: 12, color: c.ink3)),
              Text(Fmt.g(item.finalG),
                  style: TextStyle(fontSize: 12, color: c.ink3)),
              Text('×${item.portionRatio}',
                  style: TextStyle(fontSize: 12, color: c.ink3)),
              if (item.editedByUser)
                const SikpanBadge('수정함', tone: BadgeTone.accent)
              else if (item.confidence < 0.6)
                SikpanBadge('확인 필요 ${Fmt.pct(item.confidence)}',
                    tone: BadgeTone.warn),
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
