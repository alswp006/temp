import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../app_state.dart';
import '../theme/tokens.dart';
import '../ui/labels.dart';
import '../ui/widgets.dart';
import 'capture.dart';

/// 주간 식단표.
///
/// 이 앱의 정확도가 나오는 곳입니다. 한 주에 한 명만 올리면 같은 식당 사람
/// 전부가 객관식 인식의 혜택을 받습니다.
class MenuScreen extends StatefulWidget {
  const MenuScreen({super.key, required this.canteenId});
  final int canteenId;

  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  List<MenuPlan> _plans = const [];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = (await context.api
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
      showToast(context, e.message);
    }
  }

  Future<void> _uploadBoard() async {
    final source = await askImageSource(context, title: '주간 식단표');
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
        showToast(context, '읽어낸 메뉴가 없습니다. 사진을 다시 찍어 주세요.');
        return;
      }

      // 저장 전에 사람이 확인합니다. 잘못 읽은 식단표는 그 식당 전원의
      // 인식을 망가뜨리므로 자동 저장하지 않습니다.
      final confirmed = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => _DraftSheet(slots: slots),
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
      showToast(context, '식단표를 저장했습니다');
      await _load();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _report(MenuPlan plan) async {
    try {
      final res = await context.api.post(
          '/canteens/${widget.canteenId}/menu-plans/${plan.id}/report',
          body: {'note': null}) as Map<String, dynamic>;
      if (!mounted) return;
      showToast(
          context,
          res['threshold_reached'] == true
              ? '재확인 대상으로 표시했습니다'
              : '신고 ${res['reports']}건');
      await _load();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('식단표',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
            Text('이번 주', style: TextStyle(fontSize: 12, color: c.ink3)),
          ],
        ),
        toolbarHeight: 64,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ScreenBody(
              onRefresh: _load,
              children: [
                SikpanCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FilledButton.icon(
                        onPressed: _busy ? null : _uploadBoard,
                        icon: const Icon(Icons.photo_camera, size: 19),
                        label: const Text('주간 식단표 올리기'),
                      ),
                      const SizedBox(height: 10),
                      Text('한 주에 한 번, 한 명만 올리면 같은 식당 사람 전부가 씁니다.',
                          style: TextStyle(fontSize: 12, color: c.ink3)),
                    ],
                  ),
                ),
                if (_plans.isEmpty)
                  const EmptyState('이번 주 식단표가 없습니다.')
                else
                  for (final plan in _plans)
                    SikpanCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${Fmt.date(plan.date)} (${Fmt.weekday(plan.date)}) '
                                  '${mealLabel[plan.mealType] ?? plan.mealType}',
                                  style: const TextStyle(
                                      fontSize: 15, fontWeight: FontWeight.w700),
                                ),
                              ),
                              if (!plan.verified)
                                const SikpanBadge('확인 필요',
                                    tone: BadgeTone.warn),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            plan.items
                                .map((i) =>
                                    '${i.name}(${i.standardG.round()}g)')
                                .join(' · '),
                            style: TextStyle(
                                fontSize: 13, height: 1.45, color: c.ink2),
                          ),
                          const SizedBox(height: 10),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: () => _report(plan),
                              style: TextButton.styleFrom(
                                  foregroundColor: c.ink3,
                                  padding: EdgeInsets.zero,
                                  minimumSize: const Size(0, 30)),
                              child: const Text('메뉴 틀림 신고',
                                  style: TextStyle(fontSize: 13)),
                            ),
                          ),
                        ],
                      ),
                    ),
              ],
            ),
    );
  }
}

/// 읽어낸 식단표 초안. 저장 전 확인용.
class _DraftSheet extends StatelessWidget {
  const _DraftSheet({required this.slots});
  final List<MenuDraftSlot> slots;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      builder: (context, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('이렇게 읽었습니다',
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 4),
                Text('${slots.length}개 끼니. 틀린 게 있으면 저장 후 신고할 수 있습니다.',
                    style: TextStyle(fontSize: 13, color: c.ink2)),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              controller: controller,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: slots.length,
              separatorBuilder: (_, __) => Divider(height: 20, color: c.line),
              itemBuilder: (_, i) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${Fmt.date(slots[i].date)} '
                    '${mealLabel[slots[i].mealType] ?? slots[i].mealType}',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(slots[i].items.map((e) => e.name).join(', '),
                      style: TextStyle(
                          fontSize: 13, height: 1.45, color: c.ink2)),
                ],
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('취소'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('저장'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
