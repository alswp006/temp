import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/tokens.dart';
import 'labels.dart';
import 'widgets.dart';

/// 요일별 섭취 막대.
///
/// 주간 리포트가 숫자 표뿐이었을 때는 "이번 주가 어땠나"를 읽으려면 다섯 줄을
/// 암산해야 했습니다. 막대 하나에 목표선을 그으면 넘긴 날과 빈 날이 즉시
/// 보입니다. 리포트 화면의 존재 이유가 바로 그 한눈입니다.
///
/// 기록이 없는 날을 0으로 그리면 "굶은 날"로 읽히므로, 빈 날은 바닥에 점선
/// 자리만 남기고 아래 라벨을 흐리게 둡니다.
class WeekBars extends StatelessWidget {
  const WeekBars({
    super.key,
    required this.days,
    this.target,
    this.height = 150,
  });

  final List<DaySummary> days;
  final double? target;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    if (days.isEmpty) {
      return const EmptyState('이번 주 기록이 없습니다.',
          icon: Icons.bar_chart_rounded);
    }

    final maxKcal = days.fold<double>(0, (m, d) => math.max(m, d.kcal));
    final ceiling = math.max(maxKcal, target ?? 0) * 1.15;
    final scale = ceiling > 0 ? ceiling : 1.0;
    final today = DateTime.now();
    final todayKey =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';

    return Column(
      children: [
        SizedBox(
          height: height,
          child: Stack(
            children: [
              if (target != null && target! > 0)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: (target! / scale) * height,
                  child: _TargetLine(label: '목표 ${Fmt.kcal(target)}'),
                ),
              // Positioned.fill이 없으면 Row가 Stack에서 느슨한 제약을 받아
              // 가장 높은 막대만큼만 커지고 좌상단에 정렬됩니다. 그러면 막대가
              // 바닥이 아니라 천장에 매달립니다.
              Positioned.fill(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final d in days)
                      Expanded(
                        child: _Bar(
                          ratio: d.kcal / scale,
                          height: height,
                          over:
                              target != null && target! > 0 && d.kcal > target!,
                          isToday: d.date == todayKey,
                          empty: d.meals == 0,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Dim.s8),
        Row(
          children: [
            for (final d in days)
              Expanded(
                child: Column(
                  children: [
                    Text(
                      Fmt.weekday(d.date),
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: d.date == todayKey
                            ? FontWeight.w800
                            : FontWeight.w500,
                        color: d.date == todayKey
                            ? c.accent
                            : (d.meals == 0 ? c.ink3 : c.ink2),
                      ),
                    ),
                    const SizedBox(height: Dim.s2),
                    Text(
                      d.meals == 0 ? '–' : Fmt.kcal(d.kcal),
                      style: TextStyle(
                        fontSize: 10.5,
                        color: c.ink3,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({
    required this.ratio,
    required this.height,
    required this.over,
    required this.isToday,
    required this.empty,
  });

  final double ratio;
  final double height;
  final bool over;
  final bool isToday;
  final bool empty;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final fill = over ? c.warn : c.accent;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: empty ? 0 : ratio.clamp(0.0, 1.0)),
        duration: Motion.count,
        curve: Motion.emphasized,
        builder: (_, v, __) => Container(
          height: math.max(v * height, empty ? 3 : 4),
          decoration: BoxDecoration(
            gradient: empty
                ? null
                : LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [fill, fill.withValues(alpha: 0.68)],
                  ),
            color: empty ? c.line : null,
            borderRadius: BorderRadius.circular(6),
            boxShadow: isToday && !empty && !c.isDark
                ? [
                    BoxShadow(
                      color: fill.withValues(alpha: 0.30),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    )
                  ]
                : null,
          ),
        ),
      ),
    );
  }
}

class _TargetLine extends StatelessWidget {
  const _TargetLine({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Row(
      children: [
        Expanded(
          child: CustomPaint(
            size: const Size(double.infinity, 1),
            painter: _DashPainter(color: c.ink3.withValues(alpha: 0.45)),
          ),
        ),
        const SizedBox(width: Dim.s6),
        Text(label,
            style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: c.ink3,
                fontFeatures: const [FontFeature.tabularFigures()])),
      ],
    );
  }
}

class _DashPainter extends CustomPainter {
  _DashPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const dash = 4.0, gap = 4.0;
    for (var x = 0.0; x < size.width; x += dash + gap) {
      canvas.drawLine(
          Offset(x, 0), Offset(math.min(x + dash, size.width), 0), paint);
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) => old.color != color;
}

/// 추세선 스파크라인 — 체중처럼 값 자체보다 방향이 중요한 계열용.
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.values,
    this.height = 44,
    this.color,
  });

  final List<double> values;
  final double height;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    if (values.length < 2) return SizedBox(height: height);
    return SizedBox(
      height: height,
      width: double.infinity,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: Motion.slow,
        curve: Motion.curve,
        builder: (_, v, __) => CustomPaint(
          painter: _SparkPainter(
            values: values,
            progress: v,
            color: color ?? c.accent,
          ),
        ),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter({
    required this.values,
    required this.progress,
    required this.color,
  });

  final List<double> values;
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final lo = values.reduce(math.min);
    final hi = values.reduce(math.max);
    final span = (hi - lo).abs() < 1e-9 ? 1.0 : hi - lo;
    final dx = size.width / (values.length - 1);

    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = dx * i;
      final y = size.height - ((values[i] - lo) / span) * size.height;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }

    final metrics = path.computeMetrics().toList();
    final drawn = Path();
    for (final m in metrics) {
      drawn.addPath(m.extractPath(0, m.length * progress), Offset.zero);
    }

    canvas.drawPath(
      drawn,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.progress != progress || old.values != values || old.color != color;
}
