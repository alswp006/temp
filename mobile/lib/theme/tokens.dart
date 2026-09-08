import 'package:flutter/material.dart';

/// 색 토큰.
///
/// 출처는 `web/css/app.css`의 `:root`였습니다. 웹과 앱이 다른 초록을 쓰면 같은
/// 제품으로 보이지 않기 때문입니다. 여기에 앱에만 필요한 것 세 가지를 더
/// 얹었습니다.
///
/// * **영양소 색** — 단백질·탄수화물·지방을 숫자 세 개로만 보여주면 비율이
///   읽히지 않습니다. 색을 고정으로 배정해 두면 한 번 익힌 뒤로는 막대만 봐도
///   알 수 있습니다. 초록(accent)과 부딪히지 않도록 보라·호박·장미로 골랐고,
///   다크에서는 채도를 낮추고 명도를 올려 같은 위계를 유지합니다.
/// * **표면 위계** — 이전에는 모든 카드가 같은 흰 사각형이라 어느 것이 중요한지
///   구분되지 않았습니다. `surface`(기본 카드) 위에 `elevated`(히어로)를 두고,
///   라이트에서는 그림자로, 다크에서는 밝기로 띄웁니다.
/// * **그림자** — 회색이 아니라 배경의 따뜻한 기운을 머금은 색입니다. 중성 회색
///   그림자는 베이지 배경 위에서 지저분해 보입니다.
class SikpanColors extends ThemeExtension<SikpanColors> {
  const SikpanColors({
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.elevated,
    required this.line,
    required this.lineSoft,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.accent,
    required this.accentSoft,
    required this.accentDeep,
    required this.warn,
    required this.danger,
    required this.protein,
    required this.carb,
    required this.fat,
    required this.shadow,
    required this.scrim,
  });

  final Color bg;
  final Color surface;
  final Color surface2;

  /// 히어로 카드처럼 한 단계 떠 있어야 하는 표면.
  final Color elevated;

  final Color line;

  /// 카드 내부 구분선. `line`보다 흐려서 목록이 격자처럼 보이지 않습니다.
  final Color lineSoft;

  final Color ink;
  final Color ink2;
  final Color ink3;
  final Color accent;
  final Color accentSoft;

  /// 링·그라데이션의 어두운 끝.
  final Color accentDeep;

  final Color warn;
  final Color danger;

  final Color protein;
  final Color carb;
  final Color fat;

  final Color shadow;
  final Color scrim;

  static const light = SikpanColors(
    bg: Color(0xFFF7F5F0),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF0EDE6),
    elevated: Color(0xFFFFFFFF),
    line: Color(0xFFE2DED4),
    lineSoft: Color(0xFFEDE9E1),
    ink: Color(0xFF1C1E22),
    ink2: Color(0xFF5B6068),
    ink3: Color(0xFF8B9098),
    accent: Color(0xFF2F7D5D),
    accentSoft: Color(0xFFE3F0EA),
    accentDeep: Color(0xFF1E5C42),
    warn: Color(0xFFB46A2B),
    danger: Color(0xFFB3453A),
    protein: Color(0xFF6C5CE0),
    carb: Color(0xFFC98A2B),
    fat: Color(0xFFC2566B),
    shadow: Color(0x14413A2E),
    scrim: Color(0x991C1E22),
  );

  static const dark = SikpanColors(
    bg: Color(0xFF14161A),
    surface: Color(0xFF1C1F25),
    surface2: Color(0xFF23272E),
    elevated: Color(0xFF23262D),
    line: Color(0xFF2E333B),
    lineSoft: Color(0xFF262B32),
    ink: Color(0xFFECEEF1),
    ink2: Color(0xFFA8AEB7),
    ink3: Color(0xFF767D87),
    accent: Color(0xFF56B98C),
    accentSoft: Color(0xFF1D3A2E),
    accentDeep: Color(0xFF2F7D5D),
    warn: Color(0xFFD79753),
    danger: Color(0xFFE0705F),
    protein: Color(0xFF9C8CFF),
    carb: Color(0xFFE0B063),
    fat: Color(0xFFE58AA0),
    shadow: Color(0x66000000),
    scrim: Color(0xCC000000),
  );

  bool get isDark => bg.computeLuminance() < 0.5;

  @override
  SikpanColors copyWith({
    Color? bg,
    Color? surface,
    Color? surface2,
    Color? elevated,
    Color? line,
    Color? lineSoft,
    Color? ink,
    Color? ink2,
    Color? ink3,
    Color? accent,
    Color? accentSoft,
    Color? accentDeep,
    Color? warn,
    Color? danger,
    Color? protein,
    Color? carb,
    Color? fat,
    Color? shadow,
    Color? scrim,
  }) {
    return SikpanColors(
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      surface2: surface2 ?? this.surface2,
      elevated: elevated ?? this.elevated,
      line: line ?? this.line,
      lineSoft: lineSoft ?? this.lineSoft,
      ink: ink ?? this.ink,
      ink2: ink2 ?? this.ink2,
      ink3: ink3 ?? this.ink3,
      accent: accent ?? this.accent,
      accentSoft: accentSoft ?? this.accentSoft,
      accentDeep: accentDeep ?? this.accentDeep,
      warn: warn ?? this.warn,
      danger: danger ?? this.danger,
      protein: protein ?? this.protein,
      carb: carb ?? this.carb,
      fat: fat ?? this.fat,
      shadow: shadow ?? this.shadow,
      scrim: scrim ?? this.scrim,
    );
  }

  @override
  SikpanColors lerp(ThemeExtension<SikpanColors>? other, double t) {
    if (other is! SikpanColors) return this;
    return SikpanColors(
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surface2: Color.lerp(surface2, other.surface2, t)!,
      elevated: Color.lerp(elevated, other.elevated, t)!,
      line: Color.lerp(line, other.line, t)!,
      lineSoft: Color.lerp(lineSoft, other.lineSoft, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      ink2: Color.lerp(ink2, other.ink2, t)!,
      ink3: Color.lerp(ink3, other.ink3, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      accentDeep: Color.lerp(accentDeep, other.accentDeep, t)!,
      warn: Color.lerp(warn, other.warn, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      protein: Color.lerp(protein, other.protein, t)!,
      carb: Color.lerp(carb, other.carb, t)!,
      fat: Color.lerp(fat, other.fat, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
      scrim: Color.lerp(scrim, other.scrim, t)!,
    );
  }
}

/// 간격·모서리.
///
/// 4의 배수로 고정합니다. 임의의 숫자를 그때그때 쓰면 화면마다 리듬이 달라지고,
/// 그 어긋남이 "만들다 만 앱" 인상의 큰 부분을 차지합니다.
class Dim {
  static const radiusXs = 8.0;
  static const radiusSm = 12.0;
  static const radius = 16.0;
  static const radiusLg = 20.0;

  /// 히어로 카드. iOS 26의 큰 곡률과 결을 맞춥니다.
  static const radiusXl = 28.0;

  static const gap = 14.0;

  static const s2 = 2.0;
  static const s4 = 4.0;
  static const s6 = 6.0;
  static const s8 = 8.0;
  static const s12 = 12.0;
  static const s16 = 16.0;
  static const s20 = 20.0;
  static const s24 = 24.0;
  static const s32 = 32.0;

  /// 화면 좌우 여백.
  static const screenH = 16.0;
}

/// 모션.
///
/// 값을 한 곳에 모아 두면 화면마다 다른 속도로 움직이는 일이 없습니다. 곡선은
/// iOS의 기본 감각에 맞춰 `easeOutCubic` 계열로 통일하고, 숫자가 올라가는 것처럼
/// "세어지는" 연출만 조금 더 길게 잡았습니다.
class Motion {
  static const fast = Duration(milliseconds: 160);
  static const base = Duration(milliseconds: 260);
  static const slow = Duration(milliseconds: 420);

  /// 숫자 카운트업·링 채우기.
  static const count = Duration(milliseconds: 700);

  /// 목록이 차례로 들어오는 간격.
  static const stagger = Duration(milliseconds: 45);

  static const curve = Curves.easeOutCubic;
  static const emphasized = Curves.easeOutQuart;
}

extension SikpanTheme on BuildContext {
  SikpanColors get c => Theme.of(this).extension<SikpanColors>()!;
  TextTheme get t => Theme.of(this).textTheme;

  /// 카드 그림자. 다크에서는 그림자 대신 테두리로 띄우므로 비워 둡니다.
  List<BoxShadow> get cardShadow => c.isDark
      ? const []
      : [
          BoxShadow(
            color: c.shadow,
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ];

  List<BoxShadow> get heroShadow => c.isDark
      ? const []
      : [
          BoxShadow(
            color: c.shadow,
            blurRadius: 28,
            offset: const Offset(0, 10),
          ),
        ];
}
