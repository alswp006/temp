import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';

/// 카드 — 웹의 `.card`와 같은 역할.
class SikpanCard extends StatelessWidget {
  const SikpanCard({
    super.key,
    required this.child,
    this.title,
    this.icon,
    this.trailing,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final String? title;
  final IconData? icon;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(Dim.radius),
        border: Border.all(color: c.line),
      ),
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null || trailing != null) ...[
            Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 17, color: c.ink2),
                  const SizedBox(width: 7),
                ],
                if (title != null)
                  Expanded(
                    child: Text(title!,
                        style: Theme.of(context).textTheme.titleMedium),
                  )
                else
                  const Spacer(),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 12),
          ],
          child,
        ],
      ),
    );
  }
}

/// 진행 막대. 목표를 넘으면 색이 바뀝니다 (웹의 `.meter.warn`).
class Meter extends StatelessWidget {
  const Meter({
    super.key,
    required this.value,
    required this.target,
    this.warnOver = true,
  });

  final double value;
  final double? target;
  final bool warnOver;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final t = target ?? 0;
    final ratio = t > 0 ? (value / t).clamp(0.0, 1.0) : 0.0;
    final over = warnOver && t > 0 && value > t;
    return ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: LinearProgressIndicator(
        value: ratio,
        minHeight: 8,
        backgroundColor: c.surface2,
        valueColor:
            AlwaysStoppedAnimation<Color>(over ? c.warn : c.accent),
      ),
    );
  }
}

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
      BadgeTone.warn => (c.warn.withValues(alpha: 0.14), c.warn),
      BadgeTone.danger => (c.danger.withValues(alpha: 0.14), c.danger),
      BadgeTone.neutral => (c.surface2, c.ink2),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
            const SizedBox(width: 6),
          ],
          Text(label,
              style: TextStyle(
                  fontSize: 11.5, fontWeight: FontWeight.w600, color: fg)),
        ],
      ),
    );
  }
}

/// 안내 배너 — 웹의 `.banner`.
class NoticeBanner extends StatelessWidget {
  const NoticeBanner(this.text, {super.key, this.tone = BadgeTone.warn, this.busy = false});

  final String text;
  final BadgeTone tone;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final color = tone == BadgeTone.accent ? c.accent : c.warn;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Dim.radiusSm),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (busy) ...[
            SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 1.8, color: color),
            ),
            const SizedBox(width: 9),
          ],
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 13, height: 1.4, color: c.ink)),
          ),
        ],
      ),
    );
  }
}

/// 큰 숫자 + 라벨 묶음 (kcal 히어로, 주간 지표).
class StatBlock extends StatelessWidget {
  const StatBlock({
    super.key,
    required this.value,
    required this.label,
    this.hint,
  });

  final String value;
  final String label;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(value,
            style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w700,
                color: c.ink,
                fontFeatures: const [FontFeature.tabularFigures()])),
        const SizedBox(height: 3),
        Text(label, style: TextStyle(fontSize: 12, color: c.ink2)),
        if (hint != null) ...[
          const SizedBox(height: 2),
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
      children: [
        for (final child in children) Expanded(child: child),
      ],
    );
  }
}

/// 선택 칩 — 끼니 고르기, 식당 고르기.
class SikpanChip extends StatelessWidget {
  const SikpanChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Material(
      color: selected ? c.accent : c.surface2,
      borderRadius: BorderRadius.circular(99),
      child: InkWell(
        borderRadius: BorderRadius.circular(99),
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: selected ? Colors.white : c.ink2,
            ),
          ),
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState(this.text, {super.key, this.busy = false});
  final String text;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (busy) ...[
            const SizedBox(
                width: 15, height: 15,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
          ],
          Flexible(
            child: Text(text,
                textAlign: TextAlign.center,
                style: TextStyle(color: c.ink3, fontSize: 14)),
          ),
        ],
      ),
    );
  }
}

/// 목록 한 줄. 카드 안에서 구분선으로 이어집니다.
class ListRow extends StatelessWidget {
  const ListRow({
    super.key,
    this.leading,
    required this.content,
    this.trailing,
    this.onTap,
    this.showDivider = true,
  });

  final Widget? leading;
  final Widget content;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          Expanded(child: content),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
        ],
      ),
    );

    return Column(
      children: [
        if (onTap != null)
          InkWell(
            onTap: () {
              HapticFeedback.selectionClick();
              onTap!();
            },
            child: row,
          )
        else
          row,
        if (showDivider) Divider(height: 1, color: c.line),
      ],
    );
  }
}

/// 화면 전체를 감싸는 스크롤 + 여백. 모든 화면이 같은 리듬을 갖도록.
class ScreenBody extends StatelessWidget {
  const ScreenBody({
    super.key,
    required this.children,
    this.onRefresh,
    this.padding,
  });

  final List<Widget> children;
  final Future<void> Function()? onRefresh;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final list = ListView.separated(
      // 하단 탭바 + 촬영 버튼에 마지막 카드가 가리지 않도록 넉넉히.
      // FAB(56) + 여백. 이게 모자라면 마지막 카드의 버튼이 촬영 버튼에
      // 가려서 누를 수 없습니다.
      padding: padding ??
          EdgeInsets.fromLTRB(
              16, 8, 16, 96 + MediaQuery.paddingOf(context).bottom),
      physics: onRefresh != null
          ? const AlwaysScrollableScrollPhysics()
          : null,
      itemCount: children.length,
      separatorBuilder: (_, __) => const SizedBox(height: Dim.gap),
      itemBuilder: (_, i) => children[i],
    );
    if (onRefresh == null) return list;
    return RefreshIndicator(onRefresh: onRefresh!, child: list);
  }
}

void showToast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(milliseconds: 2600),
    ));
}
