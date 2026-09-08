import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../app_state.dart';
import '../theme/tokens.dart';
import '../ui/labels.dart';
import '../ui/widgets.dart';
import 'capture.dart';

/// 기록 화면 — 사진 말고도 전부 되는 곳.
///
/// AI 호출이 하나도 없어도 이 앱은 동작해야 합니다. 모델이 죽어도, 키가
/// 없어도, 급식표가 없어도 기록은 이어져야 합니다.
///
/// 다만 "전부 된다"와 "전부 똑같이 보인다"는 다릅니다. 이전에는 사진·문장·
/// 체중·직접 입력이 같은 크기의 카드로 나란히 서 있어서, 처음 온 사람이 무엇부터
/// 눌러야 하는지 화면이 말해 주지 않았습니다. 실제로 가장 자주 쓰이고 가장 적게
/// 수고로운 길은 사진이므로 그것만 히어로로 올리고, 나머지는 **사진이 안 될 때의
/// 우회로**로 아래에 둡니다. 우회로를 없애는 게 아니라 순서를 정하는 것입니다.
class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  static const _tagMealPhoto = 'meal-photo';
  static const _tagNotePhoto = 'note-photo';
  static const _tagWorkout = 'workout';
  static const _tagWeight = 'weight';
  static const _tagFood = 'food';

  /// 눌러서 넣는 예시. 자연어 파서가 실제로 알아듣는 형태를 그대로 씁니다 —
  /// 흐린 힌트 글씨는 읽히기 전에 지나가지만, 한 번 눌러 본 문장은 남습니다.
  static const _examples = ['스쿼트 60에 10개 3세트', '벤치 40에 8개 5세트'];

  final _workout = TextEditingController();
  final _weight = TextEditingController();
  final _foodName = TextEditingController();
  final _foodGrams = TextEditingController(text: '200');

  /// 진행 중인 동작의 이름. 화면 전체를 스피너로 덮으면 무엇이 처리 중인지
  /// 알 수 없으므로, 해당 카드에만 배지를 답니다.
  String? _busy;

  /// 문장에서 못 알아들은 종목. 토스트로 흘려보내면 다음 토스트가 곧바로
  /// 덮어써서 사라집니다. 고칠 거리가 있는 정보는 화면에 남겨 둡니다.
  List<String> _unmatched = const [];

  bool get _idle => _busy == null;

  @override
  void dispose() {
    _workout.dispose();
    _weight.dispose();
    _foodName.dispose();
    _foodGrams.dispose();
    super.dispose();
  }

  Future<void> _run(String tag, Future<void> Function() action) async {
    if (!_idle) return;
    setState(() => _busy = tag);
    try {
      await action();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, tone: ToastTone.error);
    } on OfflineException catch (e) {
      if (mounted) showToast(context, e.toString(), tone: ToastTone.error);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  /// "스쿼트 3세트" / "스쿼트 외 2종목 9세트".
  ///
  /// 세트 수만 알리면 무엇을 기록했는지는 화면을 옮겨 가서 확인해야 합니다.
  String _summary(Workout w) {
    final names = <String>[];
    for (final s in w.sets) {
      if (s.exerciseName.isEmpty || names.contains(s.exerciseName)) continue;
      names.add(s.exerciseName);
    }
    final head = names.isEmpty
        ? '운동'
        : names.length == 1
            ? names.first
            : '${names.first} 외 ${names.length - 1}종목';
    return '$head ${w.sets.length}세트';
  }

  void _fillWorkout(String text) {
    _workout.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  Future<void> _logWorkoutText() => _run(_tagWorkout, () async {
        final text = _workout.text.trim();
        if (text.isEmpty) {
          showToast(context, '한 문장으로 적어 주세요. 예: ${_examples.first}');
          return;
        }
        final json =
            await context.api.post('/workouts/text', body: {'text': text});
        final workout = Workout.fromJson(json as Map<String, dynamic>);
        if (!mounted) return;
        _workout.clear();
        setState(() => _unmatched = workout.unmatched);
        // 오늘 화면·주간 화면이 스스로 다시 불러옵니다.
        context.data.bump();
        if (workout.sets.isEmpty) {
          showToast(context, '세트를 읽지 못했습니다. "${_examples.first}"처럼 적어 주세요');
          return;
        }
        showToast(context, '${_summary(workout)} 기록했습니다',
            tone: ToastTone.success);
      });

  Future<void> _logWeight() => _run(_tagWeight, () async {
        final kg = double.tryParse(_weight.text.trim());
        if (kg == null || kg <= 0) {
          showToast(context, '체중을 숫자로 입력해 주세요. 예: 72.4',
              tone: ToastTone.error);
          return;
        }
        final json = await context.api.post('/weights', body: {'raw_kg': kg});
        if (!mounted) return;
        _weight.clear();
        context.data.bump();
        // 하루치 체중은 재는 시각에 따라 1kg씩 흔들립니다. 서버가 돌려준 추세를
        // 같이 알려 주면 "어제보다 늘었다"는 오해가 줄어듭니다.
        final trend = json is Map<String, dynamic>
            ? (json['trend_kg'] as num?)?.toDouble()
            : null;
        showToast(
          context,
          trend == null
              ? '${Fmt.kg(kg)} 기록했습니다'
              : '${Fmt.kg(kg)} 기록했습니다 · 추세 ${Fmt.kg(trend)}',
          tone: ToastTone.success,
        );
      });

  Future<void> _logFood() => _run(_tagFood, () async {
        final name = _foodName.text.trim();
        if (name.isEmpty) {
          showToast(context, '음식 이름을 적어 주세요. 예: 닭가슴살');
          return;
        }
        final grams = double.tryParse(_foodGrams.text.trim()) ?? 100;
        final json = await context.api.post('/meals/manual', body: {
          'items': [
            {'name': name, 'final_g': grams}
          ],
        });
        if (!mounted) return;
        _foodName.clear();
        context.data.bump();
        final kcal =
            json is Map<String, dynamic> ? Meal.fromJson(json).kcal : 0.0;
        showToast(
          context,
          kcal > 0
              ? '$name ${grams.round()}g · ${Fmt.kcal(kcal)}kcal 기록했습니다'
              : '$name ${grams.round()}g 기록했습니다',
          tone: ToastTone.success,
        );
      });

  Future<void> _shootWorkoutNote() async {
    final source = await askImageSource(context,
        title: '운동 수첩', subtitle: '수첩·화이트보드·다른 앱 화면 아무거나');
    if (source == null || !mounted) return;
    await _run(_tagNotePhoto, () async {
      final bytes = await MealCapture.pickBytes(source: source);
      if (bytes == null || !mounted) return;
      showToast(context, '수첩을 읽는 중…');
      final json = await context.api
          .upload('/workouts/photo', bytes, filename: 'note.jpg');
      final workout = Workout.fromJson(json as Map<String, dynamic>);
      if (!mounted) return;
      setState(() => _unmatched = workout.unmatched);
      context.data.bump();
      if (workout.sets.isEmpty) {
        showToast(context, '사진에서 세트를 찾지 못했습니다. 한 문장으로 적어 보세요');
        return;
      }
      showToast(context, '${_summary(workout)} 기록했습니다',
          tone: ToastTone.success);
    });
  }

  Future<void> _shootMeal() async {
    final source = await askImageSource(context,
        title: '식판 촬영', subtitle: '한 장이면 메뉴·양·칼로리까지 채웁니다');
    if (source == null || !mounted) return;
    // 업로드·오프라인 큐·토스트·bump까지 MealCapture가 책임집니다. 여기서는
    // 두 번 눌리지 않게 잠그기만 합니다.
    await _run(_tagMealPhoto, () async {
      if (!mounted) return;
      await MealCapture.shoot(context, source: source);
    });
  }

  Widget? _spinner(String tag) => _busy == tag
      ? const SikpanBadge('기록 중', tone: BadgeTone.accent, spinner: true)
      : null;

  @override
  Widget build(BuildContext context) {
    return ScreenBody(
      children: [
        _photoHero(),
        const SectionHeader('사진이 어려울 때'),
        _workoutCard(),
        _foodCard(),
        _weightCard(),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 주 경로 — 사진
  // ---------------------------------------------------------------------------

  Widget _photoHero() {
    final shooting = _busy == _tagMealPhoto || _busy == _tagNotePhoto;
    return SikpanCard(
      hero: true,
      title: '사진으로',
      subtitle: '찍어 두면 나머지는 앱이 채웁니다',
      icon: Icons.photo_camera_rounded,
      trailing: shooting
          ? const SikpanBadge('읽는 중', tone: BadgeTone.accent, spinner: true)
          : null,
      child: Column(
        children: [
          _PhotoAction(
            icon: Icons.restaurant_rounded,
            label: '식판 촬영',
            hint: '메뉴·양·칼로리까지 알아서 채웁니다',
            primary: true,
            busy: _busy == _tagMealPhoto,
            onTap: _idle ? _shootMeal : null,
          ),
          const SizedBox(height: Dim.s8),
          _PhotoAction(
            icon: Icons.menu_book_rounded,
            label: '운동 수첩',
            hint: '수첩·화이트보드·다른 앱 화면을 찍으면 세트 단위로 읽어옵니다',
            busy: _busy == _tagNotePhoto,
            onTap: _idle ? _shootWorkoutNote : null,
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 우회로 — 문장·직접 입력·체중
  // ---------------------------------------------------------------------------

  Widget _workoutCard() {
    final c = context.c;
    return SikpanCard(
      title: '한 문장으로 운동',
      subtitle: '말하듯 적으면 세트로 나눕니다',
      icon: Icons.mic_none_rounded,
      trailing: _spinner(_tagWorkout),
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
                  decoration: InputDecoration(hintText: _examples.first),
                ),
              ),
              const SizedBox(width: Dim.s8),
              FilledButton(
                onPressed: _idle ? _logWorkoutText : null,
                child: const Text('기록'),
              ),
            ],
          ),
          const SizedBox(height: Dim.s12),
          Text('예시를 눌러 넣어 보세요',
              style: TextStyle(fontSize: 11.5, color: c.ink3)),
          const SizedBox(height: Dim.s8),
          Wrap(
            spacing: Dim.s6,
            runSpacing: Dim.s6,
            children: [
              for (final example in _examples)
                SikpanChip(
                  label: example,
                  icon: Icons.add_rounded,
                  selected: false,
                  onTap: () => _fillWorkout(example),
                ),
            ],
          ),
          const SizedBox(height: Dim.s12),
          Text('키보드 마이크를 쓰면 말로 넣을 수 있습니다.',
              style: TextStyle(fontSize: 12, color: c.ink3)),
          if (_unmatched.isNotEmpty) ...[
            const SizedBox(height: Dim.s12),
            NoticeBanner(
              '못 알아들은 말: ${_unmatched.join(", ")}',
              icon: Icons.help_outline_rounded,
              action: '지우기',
              onAction: () => setState(() => _unmatched = const []),
            ),
          ],
        ],
      ),
    );
  }

  Widget _foodCard() {
    final c = context.c;
    return SikpanCard(
      title: '직접 입력',
      subtitle: '사진도 AI도 없이, 이름과 무게만',
      icon: Icons.keyboard_rounded,
      trailing: _spinner(_tagFood),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _foodName,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _logFood(),
                  decoration: const InputDecoration(hintText: '예: 닭가슴살'),
                ),
              ),
              const SizedBox(width: Dim.s8),
              Expanded(
                child: TextField(
                  controller: _foodGrams,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.end,
                  decoration: const InputDecoration(
                      hintText: '200', suffixText: 'g'),
                ),
              ),
            ],
          ),
          const SizedBox(height: Dim.s12),
          OutlinedButton(
            onPressed: _idle ? _logFood : null,
            child: const Text('식사에 추가'),
          ),
          const SizedBox(height: Dim.s8),
          Text('무게를 모르면 그대로 두세요. 밥 한 공기가 200g쯤입니다.',
              style: TextStyle(fontSize: 12, color: c.ink3)),
        ],
      ),
    );
  }

  Widget _weightCard() {
    final c = context.c;
    return SikpanCard(
      title: '체중',
      subtitle: '아침 공복에 재면 추세가 덜 흔들립니다',
      icon: Icons.monitor_weight_outlined,
      trailing: _spinner(_tagWeight),
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
                  decoration: const InputDecoration(
                      hintText: '예: 72.4', suffixText: 'kg'),
                ),
              ),
              const SizedBox(width: Dim.s8),
              FilledButton(
                onPressed: _idle ? _logWeight : null,
                child: const Text('기록'),
              ),
            ],
          ),
          const SizedBox(height: Dim.s12),
          Text('체중은 본인만 입력할 수 있습니다. 코치도 대신 넣을 수 없습니다.',
              style: TextStyle(fontSize: 12, color: c.ink3)),
        ],
      ),
    );
  }
}

// =============================================================================
// 사진 경로 타일
// =============================================================================

/// 히어로 안에 서는 큰 실행 타일.
///
/// 나란한 두 개의 버튼은 "둘 중 아무거나"로 읽힙니다. 주 경로는 채운 면과 큰
/// 글자로, 보조 경로는 같은 형태를 유지하되 조용한 색으로 두어 순서를 만듭니다.
/// 설명 한 줄을 버튼 안에 넣은 것은, 밖에 두면 어느 버튼의 설명인지 모호해지기
/// 때문입니다.
class _PhotoAction extends StatelessWidget {
  const _PhotoAction({
    required this.icon,
    required this.label,
    required this.hint,
    required this.onTap,
    this.primary = false,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final String hint;
  final VoidCallback? onTap;
  final bool primary;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final fg = primary ? Colors.white : c.ink;
    final sub = primary ? Colors.white.withValues(alpha: 0.85) : c.ink3;

    return Pressable(
      onTap: onTap,
      scale: 0.98,
      child: AnimatedOpacity(
        opacity: onTap == null && !busy ? 0.5 : 1,
        duration: Motion.fast,
        child: Container(
          padding: const EdgeInsets.all(Dim.s12 + 2),
          decoration: BoxDecoration(
            color: primary ? c.accent : c.surface2,
            borderRadius: BorderRadius.circular(Dim.radius),
            boxShadow: primary && !c.isDark
                ? [
                    BoxShadow(
                      color: c.accent.withValues(alpha: 0.28),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    )
                  ]
                : null,
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: primary
                      ? Colors.white.withValues(alpha: 0.18)
                      : c.accentSoft,
                  borderRadius: BorderRadius.circular(Dim.radiusSm),
                ),
                child: busy
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: primary ? Colors.white : c.accent,
                        ),
                      )
                    : Icon(icon,
                        size: 21, color: primary ? Colors.white : c.accent),
              ),
              const SizedBox(width: Dim.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: TextStyle(
                          fontSize: primary ? 17 : 15,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                          color: fg,
                        )),
                    const SizedBox(height: Dim.s2),
                    Text(hint,
                        style: TextStyle(
                            fontSize: 12.5, height: 1.35, color: sub)),
                  ],
                ),
              ),
              const SizedBox(width: Dim.s4),
              Icon(Icons.chevron_right_rounded,
                  size: 20,
                  color: primary ? Colors.white.withValues(alpha: 0.8) : c.ink3),
            ],
          ),
        ),
      ),
    );
  }
}
