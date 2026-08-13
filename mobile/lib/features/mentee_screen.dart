import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../app_state.dart';
import '../theme/tokens.dart';
import '../ui/widgets.dart';
import 'capture.dart';
import 'today_screen.dart' show MealRow;

/// 코치가 보는 멘티 화면.
///
/// 권한이 없는 항목은 숨기지 않고 "권한 없음"이라고 말합니다. 조용히 비어
/// 보이면 코치는 멘티가 기록을 안 한 걸로 오해합니다.
class MenteeScreen extends StatefulWidget {
  const MenteeScreen({super.key, required this.userId});
  final int userId;

  @override
  State<MenteeScreen> createState() => _MenteeScreenState();
}

class _MenteeScreenState extends State<MenteeScreen> {
  final _note = TextEditingController();
  List<Meal>? _meals;
  List<Workout>? _workouts;
  bool _loading = true;
  bool _busy = false;

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

  Future<void> _load() async {
    final api = context.api;
    List<Meal>? meals;
    List<Workout>? workouts;
    try {
      meals = ((await api
                  .get('/meals', query: {'user_id': widget.userId})) as List)
          .map((e) => Meal.fromJson(e as Map<String, dynamic>))
          .toList();
    } on ApiException {
      meals = null; // 권한 없음
    }
    try {
      workouts = ((await api
                  .get('/workouts', query: {'user_id': widget.userId})) as List)
          .map((e) => Workout.fromJson(e as Map<String, dynamic>))
          .toList();
    } on ApiException {
      workouts = null;
    }
    if (!mounted) return;
    setState(() {
      _meals = meals;
      _workouts = workouts;
      _loading = false;
    });
  }

  Future<void> _logWorkoutFor() async {
    final source = await askImageSource(context, title: '운동 수첩');
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
      showToast(context, '${workout.sets.length}세트 기록했습니다');
      await _load();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _comment() async {
    final body = _note.text.trim();
    if (body.isEmpty) return;
    try {
      await context.api.post('/mentorships/comments', body: {
        'target_user_id': widget.userId,
        'entity': 'day',
        'body': body,
      });
      if (!mounted) return;
      _note.clear();
      showToast(context, '코멘트를 남겼습니다');
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Scaffold(
      appBar: AppBar(
        title: const Text('멘티',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ScreenBody(
              onRefresh: _load,
              children: [
                SikpanCard(
                  title: '오늘 식단',
                  child: _meals == null
                      ? const EmptyState('식단 조회 권한이 없습니다')
                      : _meals!.isEmpty
                          ? const EmptyState('기록 없음')
                          : Column(
                              children: [
                                for (var i = 0; i < _meals!.length; i++)
                                  MealRow(
                                      meal: _meals![i],
                                      showDivider: i != _meals!.length - 1),
                              ],
                            ),
                ),
                SikpanCard(
                  title: '오늘 운동',
                  child: _workouts == null
                      ? const EmptyState('운동 조회 권한이 없습니다')
                      : _workouts!.isEmpty
                          ? const EmptyState('기록 없음')
                          : Column(
                              children: [
                                for (var i = 0; i < _workouts!.length; i++)
                                  ListRow(
                                    showDivider: i != _workouts!.length - 1,
                                    content: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text('${_workouts![i].sets.length}세트',
                                            style: const TextStyle(
                                                fontSize: 15,
                                                fontWeight: FontWeight.w700)),
                                        const SizedBox(height: 2),
                                        Text(
                                          _workouts![i]
                                              .sets
                                              .map((s) =>
                                                  '${s.exerciseName} ${s.weightKg?.round() ?? ""}×${s.reps ?? ""}')
                                              .join(', '),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              fontSize: 13, color: c.ink2),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                ),
                SikpanCard(
                  title: '대신 기록하기',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FilledButton.icon(
                        onPressed: _busy ? null : _logWorkoutFor,
                        icon: const Icon(Icons.photo_camera, size: 19),
                        label: const Text('수첩 찍어서 운동 기록'),
                      ),
                      const SizedBox(height: 12),
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
                          const SizedBox(width: 8),
                          OutlinedButton(
                              onPressed: _comment, child: const Text('남기기')),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text('체중은 대신 입력할 수 없습니다.',
                          style: TextStyle(fontSize: 12, color: c.ink3)),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
