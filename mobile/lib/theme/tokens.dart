import 'package:flutter/material.dart';

/// 색 토큰 — `web/css/app.css`의 `:root` 값을 그대로 옮겼습니다.
///
/// 웹과 앱이 다른 초록을 쓰면 같은 제품으로 보이지 않습니다. 값을 한 벌만
/// 두고 양쪽이 참조하는 게 맞지만, 지금은 두 클라이언트가 별개 저장소 트리에
/// 있으므로 최소한 출처를 명시해 둡니다.
class SikpanColors extends ThemeExtension<SikpanColors> {
  const SikpanColors({
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.line,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.accent,
    required this.accentSoft,
    required this.warn,
    required this.danger,
  });

  final Color bg;
  final Color surface;
  final Color surface2;
  final Color line;
  final Color ink;
  final Color ink2;
  final Color ink3;
  final Color accent;
  final Color accentSoft;
  final Color warn;
  final Color danger;

  static const light = SikpanColors(
    bg: Color(0xFFF7F5F0),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF0EDE6),
    line: Color(0xFFE2DED4),
    ink: Color(0xFF1C1E22),
    ink2: Color(0xFF5B6068),
    ink3: Color(0xFF8B9098),
    accent: Color(0xFF2F7D5D),
    accentSoft: Color(0xFFE3F0EA),
    warn: Color(0xFFB46A2B),
    danger: Color(0xFFB3453A),
  );

  static const dark = SikpanColors(
    bg: Color(0xFF14161A),
    surface: Color(0xFF1C1F25),
    surface2: Color(0xFF23272E),
    line: Color(0xFF2E333B),
    ink: Color(0xFFECEEF1),
    ink2: Color(0xFFA8AEB7),
    ink3: Color(0xFF767D87),
    accent: Color(0xFF56B98C),
    accentSoft: Color(0xFF1D3A2E),
    warn: Color(0xFFD79753),
    danger: Color(0xFFE0705F),
  );

  @override
  SikpanColors copyWith({
    Color? bg,
    Color? surface,
    Color? surface2,
    Color? line,
    Color? ink,
    Color? ink2,
    Color? ink3,
    Color? accent,
    Color? accentSoft,
    Color? warn,
    Color? danger,
  }) {
    return SikpanColors(
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      surface2: surface2 ?? this.surface2,
      line: line ?? this.line,
      ink: ink ?? this.ink,
      ink2: ink2 ?? this.ink2,
      ink3: ink3 ?? this.ink3,
      accent: accent ?? this.accent,
      accentSoft: accentSoft ?? this.accentSoft,
      warn: warn ?? this.warn,
      danger: danger ?? this.danger,
    );
  }

  @override
  SikpanColors lerp(ThemeExtension<SikpanColors>? other, double t) {
    if (other is! SikpanColors) return this;
    return SikpanColors(
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surface2: Color.lerp(surface2, other.surface2, t)!,
      line: Color.lerp(line, other.line, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      ink2: Color.lerp(ink2, other.ink2, t)!,
      ink3: Color.lerp(ink3, other.ink3, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      warn: Color.lerp(warn, other.warn, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
    );
  }
}

/// 간격·모서리도 웹과 동일하게 (--radius: 14px, --gap: 14px).
class Dim {
  static const radius = 14.0;
  static const radiusSm = 10.0;
  static const gap = 14.0;
}

extension SikpanTheme on BuildContext {
  SikpanColors get c => Theme.of(this).extension<SikpanColors>()!;
  TextTheme get t => Theme.of(this).textTheme;
}
