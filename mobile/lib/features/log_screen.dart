import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../app_state.dart';
import '../theme/tokens.dart';
import '../ui/widgets.dart';
import 'capture.dart';

/// 기록 화면 — 사진 말고도 전부 되는 곳.
///
/// AI 호출이 하나도 없어도 이 앱은 동작해야 합니다. 모델이 죽어도, 키가
/// 없어도, 급식표가 없어도 기록은 이어져야 합니다.
class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  final _workout = TextEditingController();
  final _weight = TextEditingController();
  final _foodName = TextEditingController();
  final _foodGrams = TextEditingController(text: '200');
  bool _busy = false;

  @override
  void dispose() {
    _workout.dispose();
    _weight.dispose();
    _foodName.dispose();
    _foodGrams.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } on OfflineException catch (e) {
      if (mounted) showToast(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logWorkoutText() => _run(() async {
        final text = _workout.text.trim();
        if (text.isEmpty) return;
        final json = await context.api.post('/workouts/text', body: {'text': text});
        final workout = Workout.fromJson(json as Map<String, dynamic>);
        if (!mounted) return;
        _workout.clear();
        showToast(context, '${workout.sets.length}세트 기록했습니다');
        if (workout.unmatched.isNotEmpty && mounted) {
          showToast(context, '확인 필요: ${workout.unmatched.join(", ")}');
        }
      });

  Future<void> _logWeight() => _run(() async {
        final kg = double.tryParse(_weight.text.trim());
        if (kg == null || kg <= 0) {
          showToast(context, '체중을 입력해 주세요');
          return;
        }
        await context.api.post('/weights', body: {'raw_kg': kg});
        if (!mounted) return;
        _weight.clear();
        showToast(context, '체중을 기록했습니다');
      });

  Future<void> _logFood() => _run(() async {
        final name = _foodName.text.trim();
        if (name.isEmpty) return;
        await context.api.post('/meals/manual', body: {
          'items': [
            {
              'name': name,
              'final_g': double.tryParse(_foodGrams.text.trim()) ?? 100,
            }
          ],
        });
        if (!mounted) return;
        _foodName.clear();
        showToast(context, '기록했습니다');
      });

  Future<void> _shootWorkoutNote() async {
    final source = await askImageSource(context, title: '운동 수첩');
    if (source == null || !mounted) return;
    await _run(() async {
      final bytes = await MealCapture.pickBytes(source: source);
      if (bytes == null || !mounted) return;
      showToast(context, '읽는 중…');
      final json = await context.api
          .upload('/workouts/photo', bytes, filename: 'note.jpg');
      final workout = Workout.fromJson(json as Map<String, dynamic>);
      if (!mounted) return;
      showToast(context, '${workout.sets.length}세트를 읽었습니다');
    });
  }

  Future<void> _shootMeal() async {
    final source = await askImageSource(context, title: '식판 촬영');
    if (source == null || !mounted) return;
    await MealCapture.shoot(context, source: source);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ScreenBody(
      children: [
        SikpanCard(
          title: '사진으로',
          icon: Icons.photo_camera_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: _busy ? null : _shootMeal,
                      child: const Text('식판 촬영'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : _shootWorkoutNote,
                      child: const Text('운동 수첩'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text('수첩·화이트보드·다른 앱 화면을 찍으면 세트 단위로 읽어옵니다.',
                  style: TextStyle(fontSize: 12, color: c.ink3)),
            ],
          ),
        ),
        SikpanCard(
          title: '한 문장으로 운동',
          icon: Icons.mic_none_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _workout,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _logWorkoutText(),
                      decoration: const InputDecoration(
                          hintText: '스쿼트 60에 10개 3세트'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                      onPressed: _busy ? null : _logWorkoutText,
                      child: const Text('기록')),
                ],
              ),
              const SizedBox(height: 8),
              Text('키보드 마이크를 쓰면 말로 넣을 수 있습니다.',
                  style: TextStyle(fontSize: 12, color: c.ink3)),
            ],
          ),
        ),
        SikpanCard(
          title: '체중',
          icon: Icons.monitor_weight_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _weight,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _logWeight(),
                      decoration: const InputDecoration(hintText: '예: 72.4'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                      onPressed: _busy ? null : _logWeight,
                      child: const Text('기록')),
                ],
              ),
              const SizedBox(height: 8),
              Text('체중은 본인만 입력할 수 있습니다. 코치도 대신 넣을 수 없습니다.',
                  style: TextStyle(fontSize: 12, color: c.ink3)),
            ],
          ),
        ),
        SikpanCard(
          title: '직접 입력',
          icon: Icons.keyboard_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _foodName,
                      decoration: const InputDecoration(hintText: '음식 이름'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _foodGrams,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(suffixText: 'g'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              OutlinedButton(
                  onPressed: _busy ? null : _logFood,
                  child: const Text('식사에 추가')),
            ],
          ),
        ),
      ],
    );
  }
}
