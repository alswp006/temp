import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../app_state.dart';
import '../theme/tokens.dart';
import '../ui/charts.dart';
import '../ui/labels.dart';
import '../ui/widgets.dart';

class WeekScreen extends StatefulWidget {
  const WeekScreen({super.key});

  @override
  State<WeekScreen> createState() => _WeekScreenState();
}

class _WeekScreenState extends State<WeekScreen>
    with DataListener<WeekScreen> {
  WeeklyReport? _report;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  Future<void> reload() => _load();

  Future<void> _load() async {
    try {
      final json = await context.api.get('/reports/weekly');
      if (!mounted) return;
      setState(() {
        _report = WeeklyReport.fromJson(json as Map<String, dynamic>);
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showToast(context, e.message, tone: ToastTone.error);
    } on OfflineException {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final r = _report;

    if (_loading && r == null) {
      return const ScreenBody(animate: false, children: [
        SikpanCard(
          hero: true,
          child: Column(children: [
            Skeleton(width: 120, height: 40),
            SizedBox(height: Dim.s20),
            Skeleton(height: 130, radius: Dim.radiusSm),
          ]),
        ),
        SikpanCard(child: Skeleton(height: 90, radius: Dim.radiusSm)),
      ]);
    }
    if (r == null) {
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
        // --- 요일별 섭취 (히어로) -------------------------------------------
        //
        // 리포트에서 가장 먼저 보고 싶은 것은 "이번 주가 어땠나"입니다. 예전에는
        // 그걸 알려면 맨 아래 표에서 숫자 다섯 개를 읽어야 했습니다.
        SikpanCard(
          hero: true,
          title: '요일별 섭취',
          subtitle: '${Fmt.date(r.start)} – ${Fmt.date(r.end)}',
          icon: Icons.insights_rounded,
          child: WeekBars(days: r.days, target: r.targetKcal),
        ),

        // --- 북극성 지표 ---------------------------------------------------
        SikpanCard(
          title: '북극성 지표',
          subtitle: '이번 주 기록 항목 수 (식단 + 운동)',
          icon: Icons.star_rounded,
          child: Column(
            children: [
              AnimatedCount(
                r.totalEntries.toDouble(),
                style: TextStyle(
                  fontSize: 44,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1.8,
                  height: 1.05,
                  color: c.ink,
                ),
              ),
              const SizedBox(height: Dim.s20),
              StatRow(children: [
                StatBlock(value: '${r.loggedDays}일', label: '기록 일수'),
                StatBlock(value: '${r.mealEntries}', label: '식단 항목'),
                StatBlock(value: '${r.workoutEntries}', label: '운동 세트'),
              ]),
            ],
          ),
        ),

        // --- 섭취 ----------------------------------------------------------
        SikpanCard(
          title: '섭취',
          icon: Icons.local_fire_department_rounded,
          child: Column(
            children: [
              StatRow(children: [
                StatBlock(value: Fmt.kcal(r.avgKcal), label: '평균 kcal'),
                StatBlock(value: Fmt.g(r.avgProteinG), label: '평균 단백질'),
                StatBlock(value: '${r.onTargetDays}일', label: '목표 달성일'),
              ]),
              const SizedBox(height: Dim.s20),
              Divider(height: 1, color: c.lineSoft),
              const SizedBox(height: Dim.s20),
              StatRow(children: [
                StatBlock(
                    value: r.estTdee != null ? Fmt.kcal(r.estTdee) : '–',
                    label: '추정 TDEE'),
                StatBlock(
                    value: r.targetKcal != null ? Fmt.kcal(r.targetKcal) : '–',
                    label: '목표 kcal'),
                StatBlock(
                    value: r.weightChangeKg == null
                        ? '–'
                        : '${r.weightChangeKg! > 0 ? '+' : ''}${r.weightChangeKg!.toStringAsFixed(1)}kg',
                    label: '추세 체중',
                    color: r.weightChangeKg == null
                        ? null
                        : (r.weightChangeKg! > 0 ? c.warn : c.accent)),
              ]),
            ],
          ),
        ),

        // --- 품질 지표 -----------------------------------------------------
        //
        // 비율은 숫자보다 길이로 읽힙니다. 막대를 달면 "50%"가 절반이라는 걸
        // 읽지 않고도 압니다.
        SikpanCard(
          title: '품질 지표',
          icon: Icons.verified_outlined,
          child: Column(
            children: [
              _Metric('수정 발생률', r.editRate, 'AI 결과를 손으로 고친 비율',
                  invert: true),
              _Metric('메뉴 커버리지', r.menuCoverage, '식단표가 있던 끼니 비율'),
              _Metric('대리 기록 비율', r.delegatedRatio, '멘토가 대신 쓴 비율'),
              _Metric('캐시 적중률', r.cacheHitRate, '같은 식당 유저가 많을수록 상승'),
              ListRow(
                showDivider: false,
                content: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('끼니당 AI 호출',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: Dim.s2),
                    Text('낮을수록 저렴',
                        style: TextStyle(fontSize: 11.5, color: c.ink3)),
                  ],
                ),
                trailing: Text(
                    r.avgCallsPerMeal > 0
                        ? r.avgCallsPerMeal.toStringAsFixed(1)
                        : '–',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: c.ink,
                        fontFeatures: const [FontFeature.tabularFigures()])),
              ),
            ],
          ),
        ),

        // --- 요일별 표 -----------------------------------------------------
        SikpanCard(
          title: '자세히',
          icon: Icons.table_rows_outlined,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: Dim.s8),
                child: Row(
                  children: [
                    Expanded(flex: 3, child: _head(context, '날짜')),
                    Expanded(flex: 2, child: _head(context, 'kcal', end: true)),
                    Expanded(flex: 2, child: _head(context, '단백질', end: true)),
                    Expanded(flex: 2, child: _head(context, '끼니', end: true)),
                    Expanded(flex: 2, child: _head(context, '운동', end: true)),
                  ],
                ),
              ),
              for (var i = 0; i < r.days.length; i++)
                _DayRow(day: r.days[i], last: i == r.days.length - 1),
            ],
          ),
        ),
      ],
    );
  }

  Widget _head(BuildContext context, String label, {bool end = false}) => Text(
        label,
        textAlign: end ? TextAlign.right : TextAlign.left,
        style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: context.c.ink3),
      );
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.value, this.hint, {this.invert = false});

  final String label;
  final double value;
  final String hint;

  /// 낮을수록 좋은 지표 (수정 발생률).
  final bool invert;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Dim.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    const SizedBox(height: Dim.s2),
                    Text(hint,
                        style: TextStyle(fontSize: 11.5, color: c.ink3)),
                  ],
                ),
              ),
              Text(Fmt.pct(value),
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: c.ink,
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ],
          ),
          const SizedBox(height: Dim.s8),
          Meter(
            value: value,
            target: 1,
            warnOver: false,
            height: 6,
            color: invert
                ? (value > 0.4 ? c.warn : c.ink3)
                : c.accent,
          ),
        ],
      ),
    );
  }
}

class _DayRow extends StatelessWidget {
  const _DayRow({required this.day, required this.last});
  final DaySummary day;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final logged = day.meals > 0;
    final style = TextStyle(
        fontSize: 13,
        color: c.ink2,
        fontFeatures: const [FontFeature.tabularFigures()]);

    Widget cell(String text) =>
        Text(text, textAlign: TextAlign.right, style: style);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Dim.s8 + 1),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Text(
                    '${Fmt.date(day.date)} (${Fmt.weekday(day.date)})',
                    style: TextStyle(
                        fontSize: 13,
                        color: logged ? c.ink : c.ink3,
                        fontWeight:
                            logged ? FontWeight.w500 : FontWeight.w400)),
              ),
              Expanded(flex: 2, child: cell(logged ? Fmt.kcal(day.kcal) : '–')),
              Expanded(
                  flex: 2, child: cell(logged ? Fmt.g(day.proteinG) : '–')),
              Expanded(flex: 2, child: cell(logged ? '${day.meals}' : '–')),
              Expanded(
                  flex: 2,
                  child: cell(day.workouts > 0 ? '${day.workouts}' : '–')),
            ],
          ),
        ),
        if (!last) Divider(height: 1, color: c.lineSoft),
      ],
    );
  }
}
