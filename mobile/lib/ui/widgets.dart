import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';

// =============================================================================
// 표면
// =============================================================================

/// 카드.
///
/// 이전에는 모든 카드가 1px 테두리를 두른 같은 흰 사각형이라, 화면이 카드의
/// 수직 나열로만 읽혔습니다. 위계가 없으니 어디를 먼저 봐야 할지 알 수 없고
/// 그게 "구린" 인상의 큰 부분이었습니다.
///
/// 이제 라이트에서는 테두리 대신 아주 옅은 그림자로 띄웁니다. 다크에서는
/// 그림자가 보이지 않으므로 테두리를 유지합니다 — 같은 위계를 각 모드가 가장
/// 잘 표현하는 수단으로 냅니다.
class SikpanCard extends StatelessWidget {
  const SikpanCard({
    super.key,
    required this.child,
    this.title,
    this.subtitle,
    this.icon,
    this.trailing,
    this.padding = const EdgeInsets.all(Dim.s16),
    this.hero = false,
    this.tone,
  });

  final Widget child;
  final String? title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;
  final EdgeInsets padding;

  /// 화면의 주인공. 더 큰 곡률과 더 깊은 그림자를 씁니다.
  final bool hero;

  /// 강조색을 머금은 카드 (경고·위험 구역).
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final radius = hero ? Dim.radiusXl : Dim.radius;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: tone?.withValues(alpha: c.isDark ? 0.10 : 0.06) ??
            (hero ? c.elevated : c.surface),
        borderRadius: BorderRadius.circular(radius),
        border: c.isDark || tone != null
            ? Border.all(color: tone?.withValues(alpha: 0.30) ?? c.line)
            : null,
        boxShadow: hero ? context.heroShadow : context.cardShadow,
      ),
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null || trailing != null) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 17, color: tone ?? c.ink2),
                  const SizedBox(width: Dim.s8),
                ],
                if (title != null)
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title!, style: context.t.titleMedium),
                        if (subtitle != null) ...[
                          const SizedBox(height: Dim.s2),
                          Text(subtitle!,
                              style:
                                  TextStyle(fontSize: 12.5, color: c.ink3)),
                        ],
                      ],
                    ),
                  )
                else
                  const Spacer(),
                if (trailing != null) trailing!,
              ],
            ),
            SizedBox(height: subtitle == null ? Dim.s12 : Dim.s16),
          ],
          child,
        ],
      ),
    );
  }
}

/// 카드 바깥에 서는 구역 제목. 카드 제목보다 한 단계 위입니다.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action, this.onAction});

  final String title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.only(left: Dim.s4, right: Dim.s4, bottom: Dim.s4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
                color: c.ink3,
              ),
            ),
          ),
          if (action != null)
            Pressable(
              onTap: onAction,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: Dim.s6, vertical: Dim.s2),
                child: Text(
                  action!,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: c.accent,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 누를 수 있는 것은 눌린 티가 나야 합니다.
///
/// 손가락 아래에서 아무 반응이 없으면 사용자는 한 번 더 누릅니다. 잉크 리플은
/// 안드로이드의 언어라 iOS에서는 겉돌기 때문에, 살짝 줄어드는 스케일 + 햅틱으로
/// 대신합니다. 두 플랫폼 모두에서 자연스럽습니다.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.97,
    this.haptic = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;
  final bool haptic;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    if (widget.onTap == null && widget.onLongPress == null) return widget.child;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: () {
        if (widget.haptic) HapticFeedback.selectionClick();
        widget.onTap?.call();
      },
      onLongPress: widget.onLongPress == null
          ? null
          : () {
              HapticFeedback.mediumImpact();
              widget.onLongPress!();
            },
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: Motion.fast,
        curve: Motion.curve,
        child: widget.child,
      ),
    );
  }
}

// =============================================================================
// 숫자
// =============================================================================

/// 값이 바뀌면 세어 올라가는 숫자.
///
/// 사진을 올리고 나서 칼로리가 툭 바뀌면 무엇이 변했는지 못 봅니다. 0.7초에
/// 걸쳐 올라가면 눈이 따라갑니다. 자릿수가 흔들리지 않도록 tabular figures를
/// 씁니다 — 이게 없으면 세는 동안 글자가 좌우로 요동칩니다.
class AnimatedCount extends StatelessWidget {
  const AnimatedCount(
    this.value, {
    super.key,
    required this.style,
    this.format,
    this.duration = Motion.count,
  });

  final double value;
  final TextStyle style;
  final String Function(double)? format;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: value),
      duration: duration,
      curve: Motion.emphasized,
      builder: (_, v, __) => Text(
        format?.call(v) ?? v.round().toString(),
        style: style.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// 큰 숫자 + 라벨.
class StatBlock extends StatelessWidget {
  const StatBlock({
    super.key,
    required this.value,
    required this.label,
    this.hint,
    this.color,
    this.dot = false,
  });

  final String value;
  final String label;
  final String? hint;
  final Color? color;

  /// 라벨 앞에 색 점을 찍습니다 (영양소 범례).
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(value,
            style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
                color: color ?? c.ink,
                fontFeatures: const [FontFeature.tabularFigures()])),
        const SizedBox(height: Dim.s4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (dot && color != null) ...[
              Container(
                width: 6,
                height: 6,
                decoration:
                    BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: Dim.s6),
            ],
            Text(label, style: TextStyle(fontSize: 12, color: c.ink2)),
          ],
        ),
        if (hint != null) ...[
          const SizedBox(height: Dim.s2),
          Text(hint!, style: TextStyle(fontSize: 11, color: c.ink3)),
        ],
      ],
    );
  }
}

class StatRow extends StatelessWidget {
  const StatRow({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [for (final child in children) Expanded(child: child)],
    );
  }
}

// =============================================================================
// 진행 표시
// =============================================================================

/// 진행 막대. 목표를 넘으면 색이 바뀝니다.
class Meter extends StatelessWidget {
  const Meter({
    super.key,
    required this.value,
    required this.target,
    this.warnOver = true,
    this.height = 8,
    this.color,
  });

  final double value;
  final double? target;
  final bool warnOver;
  final double height;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final t = target ?? 0;
    final ratio = t > 0 ? (value / t).clamp(0.0, 1.0) : 0.0;
    final over = warnOver && t > 0 && value > t;
    final fill = over ? c.warn : (color ?? c.accent);

    return LayoutBuilder(
      builder: (_, box) => Container(
        height: height,
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: BorderRadius.circular(99),
        ),
        alignment: Alignment.centerLeft,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: ratio),
          duration: Motion.count,
          curve: Motion.emphasized,
          builder: (_, v, __) => Container(
            width: math.max(v * box.maxWidth, v > 0 ? height : 0),
            height: height,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [fill.withValues(alpha: 0.75), fill],
              ),
              borderRadius: BorderRadius.circular(99),
            ),
          ),
        ),
      ),
    );
  }
}

/// 칼로리 링.
///
/// 히어로가 맨 숫자 하나였을 때는 "260"이 많은지 적은지 알 수 없었습니다. 링은
/// 목표 대비 위치를 한눈에 주고, **목표가 없을 때도** 하루를 채워 가는 감각을
/// 줍니다 — 그때는 눈금 트랙만 남기고 안내를 띄웁니다.
///
/// 목표를 넘기면 초록 링 위에 경고색 링이 한 겹 더 감깁니다. 색만 바꾸면 얼마나
/// 넘겼는지 알 수 없지만, 겹쳐 감으면 넘긴 양이 그대로 보입니다.
class CalorieRing extends StatelessWidget {
  const CalorieRing({
    super.key,
    required this.value,
    required this.target,
    this.size = 208,
    this.stroke = 15,
    required this.center,
  });

  final double value;
  final double? target;
  final double size;
  final double stroke;
  final Widget center;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final t = target ?? 0;
    final ratio = t > 0 ? value / t : 0.0;

    return SizedBox(
      width: size,
      height: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: ratio),
        duration: Motion.count,
        curve: Motion.emphasized,
        builder: (_, v, __) => CustomPaint(
          painter: _RingPainter(
            ratio: v,
            hasTarget: t > 0,
            stroke: stroke,
            track: c.surface2,
            from: c.accentDeep,
            to: c.accent,
            over: c.warn,
          ),
          child: Center(child: center),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.ratio,
    required this.hasTarget,
    required this.stroke,
    required this.track,
    required this.from,
    required this.to,
    required this.over,
  });

  final double ratio;
  final bool hasTarget;
  final double stroke;
  final Color track;
  final Color from;
  final Color to;
  final Color over;

  static const _start = -math.pi / 2;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset(stroke / 2, stroke / 2) &
        Size(size.width - stroke, size.height - stroke);

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = track;
    canvas.drawArc(rect, 0, math.pi * 2, false, trackPaint);

    if (!hasTarget || ratio <= 0) return;

    final first = ratio.clamp(0.0, 1.0);
    final progress = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: math.pi * 2,
        colors: [from, to, from],
        transform: const GradientRotation(_start),
      ).createShader(rect);
    canvas.drawArc(rect, _start, math.pi * 2 * first, false, progress);

    // 초과분은 한 겹 더 감습니다. 한 바퀴를 넘겨도 끝은 보이게 잘라 둡니다.
    if (ratio > 1) {
      final excess = (ratio - 1).clamp(0.0, 1.0);
      final overPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = over;
      canvas.drawArc(rect, _start, math.pi * 2 * excess, false, overPaint);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.ratio != ratio ||
      old.hasTarget != hasTarget ||
      old.track != track ||
      old.to != to;
}

/// 영양소 비율 막대.
///
/// 숫자 세 개(5g·56g·1g)만으로는 "탄수화물에 치우쳤다"가 읽히지 않습니다. 무게가
/// 아니라 **칼로리 기여분**으로 나눠야 비율이 의미를 갖습니다 — 지방은 1g이
/// 9kcal이라 무게로 그리면 항상 작아 보입니다.
class MacroBar extends StatelessWidget {
  const MacroBar({
    super.key,
    required this.proteinG,
    required this.carbG,
    required this.fatG,
    this.height = 10,
    this.showLegend = true,
  });

  final double proteinG;
  final double carbG;
  final double fatG;
  final double height;
  final bool showLegend;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final p = proteinG * 4, cb = carbG * 4, f = fatG * 9;
    final total = p + cb + f;

    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: SizedBox(
            height: height,
            child: total <= 0
                ? Container(color: c.surface2)
                : TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: Motion.count,
                    curve: Motion.emphasized,
                    builder: (_, v, __) => Row(
                      children: [
                        Expanded(
                          flex: math.max((p / total * 1000 * v).round(), 0),
                          child: Container(color: c.protein),
                        ),
                        Expanded(
                          flex: math.max((cb / total * 1000 * v).round(), 0),
                          child: Container(color: c.carb),
                        ),
                        Expanded(
                          flex: math.max((f / total * 1000 * v).round(), 0),
                          child: Container(color: c.fat),
                        ),
                        Expanded(
                          flex: math.max(((1 - v) * 1000).round(), 0),
                          child: Container(color: c.surface2),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
        if (showLegend) ...[
          const SizedBox(height: Dim.s16),
          StatRow(children: [
            StatBlock(
                value: '${proteinG.round()}g',
                label: '단백질',
                color: c.protein,
                dot: true),
            StatBlock(
                value: '${carbG.round()}g',
                label: '탄수화물',
                color: c.carb,
                dot: true),
            StatBlock(
                value: '${fatG.round()}g',
                label: '지방',
                color: c.fat,
                dot: true),
          ]),
        ],
      ],
    );
  }
}

// =============================================================================
// 상태 표시
// =============================================================================

enum BadgeTone { neutral, accent, warn, danger }

class SikpanBadge extends StatelessWidget {
  const SikpanBadge(this.label,
      {super.key, this.tone = BadgeTone.neutral, this.spinner = false});

  final String label;
  final BadgeTone tone;
  final bool spinner;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final (bg, fg) = switch (tone) {
      BadgeTone.accent => (c.accentSoft, c.accent),
      BadgeTone.warn => (c.warn.withValues(alpha: 0.13), c.warn),
      BadgeTone.danger => (c.danger.withValues(alpha: 0.13), c.danger),
      BadgeTone.neutral => (c.surface2, c.ink2),
    };
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: Dim.s8, vertical: Dim.s4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (spinner) ...[
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: fg),
            ),
            const SizedBox(width: Dim.s6),
          ],
          Text(label,
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.1,
                  color: fg)),
        ],
      ),
    );
  }
}

/// 안내 배너. 아이콘을 달아 종류가 색뿐 아니라 형태로도 구분되게 합니다
/// (색각 이상에서 초록/주황 배너가 같아 보이는 문제).
class NoticeBanner extends StatelessWidget {
  const NoticeBanner(
    this.text, {
    super.key,
    this.tone = BadgeTone.warn,
    this.busy = false,
    this.icon,
    this.action,
    this.onAction,
  });

  final String text;
  final BadgeTone tone;
  final bool busy;
  final IconData? icon;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final color = switch (tone) {
      BadgeTone.accent => c.accent,
      BadgeTone.danger => c.danger,
      _ => c.warn,
    };
    final glyph = icon ??
        switch (tone) {
          BadgeTone.accent => Icons.info_outline_rounded,
          BadgeTone.danger => Icons.error_outline_rounded,
          _ => Icons.schedule_rounded,
        };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
          horizontal: Dim.s12, vertical: Dim.s12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: c.isDark ? 0.14 : 0.09),
        borderRadius: BorderRadius.circular(Dim.radiusSm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (busy)
            SizedBox(
              width: 15,
              height: 15,
              child: CircularProgressIndicator(strokeWidth: 1.9, color: color),
            )
          else
            Icon(glyph, size: 17, color: color),
          const SizedBox(width: Dim.s12),
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 13, height: 1.35, color: c.ink)),
          ),
          if (action != null) ...[
            const SizedBox(width: Dim.s8),
            Pressable(
              onTap: onAction,
              child: Text(action!,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: color)),
            ),
          ],
        ],
      ),
    );
  }
}

/// 빈 상태.
///
/// 회색 글자 한 줄은 "고장난 것"과 구분되지 않습니다. 아이콘·제목·설명·다음
/// 행동을 갖추면 빈 화면도 안내가 됩니다.
class EmptyState extends StatelessWidget {
  const EmptyState(
    this.text, {
    super.key,
    this.busy = false,
    this.icon,
    this.title,
    this.action,
    this.onAction,
  });

  final String text;
  final bool busy;
  final IconData? icon;
  final String? title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    if (busy) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Dim.s24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: Dim.s12),
            Flexible(
              child: Text(text,
                  style: TextStyle(color: c.ink3, fontSize: 14)),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Dim.s24),
      child: Column(
        children: [
          if (icon != null) ...[
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: c.surface2,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 24, color: c.ink3),
            ),
            const SizedBox(height: Dim.s16),
          ],
          if (title != null) ...[
            Text(title!,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: c.ink2)),
            const SizedBox(height: Dim.s6),
          ],
          Text(text,
              textAlign: TextAlign.center,
              style: TextStyle(color: c.ink3, fontSize: 13.5, height: 1.45)),
          if (action != null) ...[
            const SizedBox(height: Dim.s16),
            OutlinedButton(onPressed: onAction, child: Text(action!)),
          ],
        ],
      ),
    );
  }
}

/// 로딩 자리표시자.
///
/// 화면 한가운데 도는 스피너는 레이아웃이 어떻게 생겼는지 알려주지 않아, 내용이
/// 도착하는 순간 화면이 통째로 튑니다. 올 자리를 미리 그려 두면 튀지 않습니다.
class Skeleton extends StatefulWidget {
  const Skeleton({
    super.key,
    this.width,
    this.height = 14,
    this.radius = Dim.radiusXs,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return AnimatedBuilder(
      animation: _ctl,
      builder: (_, __) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: Color.lerp(c.surface2, c.line, _ctl.value * 0.7),
          borderRadius: BorderRadius.circular(widget.radius),
        ),
      ),
    );
  }
}

/// 오늘 화면이 처음 뜰 때 쓰는 뼈대.
class TodaySkeleton extends StatelessWidget {
  const TodaySkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ScreenBody(animate: false, children: [
      SikpanCard(
        hero: true,
        padding: const EdgeInsets.symmetric(vertical: Dim.s32),
        child: Column(
          children: [
            const Skeleton(width: 190, height: 190, radius: 999),
            const SizedBox(height: Dim.s24),
            Skeleton(width: MediaQuery.sizeOf(context).width * 0.5, height: 10),
          ],
        ),
      ),
      SikpanCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Skeleton(width: 120),
            SizedBox(height: Dim.s20),
            Skeleton(height: 44, radius: Dim.radiusSm),
            SizedBox(height: Dim.s12),
            Skeleton(height: 44, radius: Dim.radiusSm),
          ],
        ),
      ),
    ]);
  }
}

// =============================================================================
// 입력
// =============================================================================

/// 선택 칩.
class SikpanChip extends StatelessWidget {
  const SikpanChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: onTap,
      scale: 0.94,
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.curve,
        padding: const EdgeInsets.symmetric(
            horizontal: Dim.s16, vertical: Dim.s8 + 1),
        decoration: BoxDecoration(
          color: selected ? c.accent : c.surface2,
          borderRadius: BorderRadius.circular(99),
          boxShadow: selected && !c.isDark
              ? [
                  BoxShadow(
                    color: c.accent.withValues(alpha: 0.28),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  )
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon,
                  size: 15, color: selected ? Colors.white : c.ink2),
              const SizedBox(width: Dim.s6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : c.ink2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// 목록
// =============================================================================

/// 목록 한 줄.
class ListRow extends StatelessWidget {
  const ListRow({
    super.key,
    this.leading,
    required this.content,
    this.trailing,
    this.onTap,
    this.showDivider = true,
    this.chevron = false,
  });

  final Widget? leading;
  final Widget content;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showDivider;

  /// 눌러서 들어가는 줄임을 알립니다.
  final bool chevron;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: Dim.s12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: Dim.s12)],
          Expanded(child: content),
          if (trailing != null) ...[const SizedBox(width: Dim.s8), trailing!],
          if (chevron && onTap != null) ...[
            const SizedBox(width: Dim.s4),
            Icon(Icons.chevron_right_rounded, size: 20, color: c.ink3),
          ],
        ],
      ),
    );

    return Column(
      children: [
        if (onTap != null)
          Pressable(onTap: onTap, scale: 0.985, child: row)
        else
          row,
        if (showDivider) Divider(height: 1, color: c.lineSoft),
      ],
    );
  }
}

/// 화면 전체를 감싸는 스크롤 + 여백.
///
/// 내용이 한 번에 튀어나오는 대신 위에서부터 차례로 들어옵니다. 45ms 간격이면
/// 느리다고 느끼지 않으면서도 "화면이 조립된다"는 인상을 줍니다. 애니메이션은
/// 마운트할 때 한 번만 돌고, 이후 setState에는 다시 돌지 않습니다.
class ScreenBody extends StatefulWidget {
  const ScreenBody({
    super.key,
    required this.children,
    this.onRefresh,
    this.padding,
    this.animate = true,
  });

  final List<Widget> children;
  final Future<void> Function()? onRefresh;
  final EdgeInsets? padding;
  final bool animate;

  @override
  State<ScreenBody> createState() => _ScreenBodyState();
}

class _ScreenBodyState extends State<ScreenBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      _ctl.forward();
    } else {
      _ctl.value = 1;
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final list = ListView.separated(
      // 하단 탭바 + 촬영 버튼에 마지막 카드가 가리지 않도록 넉넉히.
      padding: widget.padding ??
          EdgeInsets.fromLTRB(Dim.screenH, Dim.s8, Dim.screenH,
              120 + MediaQuery.paddingOf(context).bottom),
      physics:
          widget.onRefresh != null ? const AlwaysScrollableScrollPhysics() : null,
      itemCount: widget.children.length,
      separatorBuilder: (_, __) => const SizedBox(height: Dim.gap),
      itemBuilder: (_, i) => _Enter(
        controller: _ctl,
        index: i,
        child: widget.children[i],
      ),
    );
    if (widget.onRefresh == null) return list;
    return RefreshIndicator(
      onRefresh: widget.onRefresh!,
      color: context.c.accent,
      backgroundColor: context.c.surface,
      child: list,
    );
  }
}

class _Enter extends StatelessWidget {
  const _Enter({
    required this.controller,
    required this.index,
    required this.child,
  });

  final AnimationController controller;
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 화면 밖까지 시차를 주면 아래쪽 카드가 영영 안 들어오는 것처럼 보입니다.
    final start = (index * 0.09).clamp(0.0, 0.55);
    final anim = CurvedAnimation(
      parent: controller,
      curve: Interval(start, math.min(start + 0.45, 1.0), curve: Motion.curve),
    );
    return AnimatedBuilder(
      animation: anim,
      builder: (_, c) => Opacity(
        opacity: anim.value,
        child: Transform.translate(
          offset: Offset(0, (1 - anim.value) * 14),
          child: c,
        ),
      ),
      child: child,
    );
  }
}

// =============================================================================
// 알림
// =============================================================================

enum ToastTone { neutral, success, error }

/// 토스트.
///
/// 성공과 실패가 같은 검정 막대로 뜨면 사용자는 결과를 읽어야만 알 수 있습니다.
/// 색과 아이콘을 붙이고 햅틱까지 맞춰 주면 화면을 안 봐도 전달됩니다.
void showToast(
  BuildContext context,
  String message, {
  ToastTone tone = ToastTone.neutral,
}) {
  final c = context.c;
  final (bg, icon) = switch (tone) {
    ToastTone.success => (c.accent, Icons.check_circle_rounded),
    ToastTone.error => (c.danger, Icons.error_rounded),
    ToastTone.neutral => (c.ink, null),
  };
  switch (tone) {
    case ToastTone.success:
      HapticFeedback.lightImpact();
    case ToastTone.error:
      HapticFeedback.heavyImpact();
    case ToastTone.neutral:
      break;
  }

  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      backgroundColor: bg,
      content: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: Colors.white),
            const SizedBox(width: Dim.s8),
          ],
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: tone == ToastTone.neutral ? c.bg : Colors.white,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
      duration: const Duration(milliseconds: 2600),
    ));
}
