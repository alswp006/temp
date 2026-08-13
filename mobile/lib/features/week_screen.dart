import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../app_state.dart';
import '../theme/tokens.dart';
import '../ui/labels.dart';
import '../ui/widgets.dart';

class WeekScreen extends StatefulWidget {
  const WeekScreen({super.key});

  @override
  State<WeekScreen> createState() => _WeekScreenState();
}

class _WeekScreenState extends State<WeekScreen> {
  WeeklyReport? _report;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

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
      showToast(context, e.message);
    } on OfflineException {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final r = _report;

    if (_loading) return const Center(child: CircularProgressIndicator());
    if (r == null) {
      return ScreenBody(children: [
        const EmptyState('불러오지 못했습니다.'),
        OutlinedButton(onPressed: _load, child: const Text('다시 시도')),
      ]);
    }

    return ScreenBody(
      onRefresh: _load,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text('${Fmt.date(r.start)} – ${Fmt.date(r.end)}',
              style: TextStyle(fontSize: 13, color: c.ink3)),
        ),

        // --- 북극성 지표 ---------------------------------------------------
        SikpanCard(
          title: '북극성 지표',
          child: Column(
            children: [
              Text('${r.totalEntries}',
                  style: TextStyle(
                      fontSize: 44,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1.5,
                      height: 1.05,
                      color: c.ink,
                      fontFeatures: const [FontFeature.tabularFigures()])),
              const SizedBox(height: 4),
              Text('이번 주 기록 항목 수 (식단 + 운동)',
                  style: TextStyle(fontSize: 13, color: c.ink2)),
              const SizedBox(height: 18),
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
          child: Column(
            children: [
              StatRow(children: [
                StatBlock(value: Fmt.kcal(r.avgKcal), label: '평균 kcal'),
                StatBlock(value: Fmt.g(r.avgProteinG), label: '평균 단백질'),
                StatBlock(value: '${r.onTargetDays}일', label: '목표 달성일'),
              ]),
              const SizedBox(height: 18),
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
                    label: '추세 체중'),
              ]),
            ],
          ),
        ),

        // --- 품질 지표 -----------------------------------------------------
        SikpanCard(
          title: '품질 지표',
          child: Column(
            children: [
              _MetricRow('수정 발생률', Fmt.pct(r.editRate), 'AI 결과를 손으로 고친 비율'),
              _MetricRow('메뉴 커버리지', Fmt.pct(r.menuCoverage), '식단표가 있던 끼니 비율'),
              _MetricRow('대리 기록 비율', Fmt.pct(r.delegatedRatio), '멘토가 대신 쓴 비율'),
              _MetricRow(
                  '끼니당 AI 호출',
                  r.avgCallsPerMeal > 0
                      ? r.avgCallsPerMeal.toStringAsFixed(1)
                      : '–',
                  '낮을수록 저렴'),
              _MetricRow('캐시 적중률', Fmt.pct(r.cacheHitRate),
                  '같은 식당 유저가 많을수록 상승',
                  last: true),
            ],
          ),
        ),

        // --- 요일별 --------------------------------------------------------
        SikpanCard(
          title: '요일별',
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(flex: 3, child: _head('날짜')),
                    Expanded(flex: 2, child: _head('kcal', end: true)),
                    Expanded(flex: 2, child: _head('단백질', end: true)),
                    Expanded(flex: 2, child: _head('끼니', end: true)),
                    Expanded(flex: 2, child: _head('운동', end: true)),
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

  Widget _head(String label, {bool end = false}) => Text(
        label,
        textAlign: end ? TextAlign.right : TextAlign.left,
        style: TextStyle(
            fontSize: 11.5, fontWeight: FontWeight.w600, color: context.c.ink3),
      );
}

class _MetricRow extends StatelessWidget {
  const _MetricRow(this.label, this.value, this.hint, {this.last = false});
  final String label;
  final String value;
  final String hint;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ListRow(
      showDivider: !last,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 2),
          Text(hint, style: TextStyle(fontSize: 11.5, color: c.ink3)),
        ],
      ),
      trailing: Text(value,
          style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: c.ink,
              fontFeatures: const [FontFeature.tabularFigures()])),
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
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Text(
                    '${Fmt.date(day.date)} (${Fmt.weekday(day.date)})',
                    style: TextStyle(fontSize: 13, color: c.ink)),
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
        if (!last) Divider(height: 1, color: c.line),
      ],
    );
  }
}
