import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'tokens.dart';

/// 플랫폼별 결을 살린 테마.
///
/// 이 앱이 PWA를 버리고 Flutter로 온 이유가 "웹 티"였으므로, 기본값을 그대로
/// 쓰는 게 오히려 중요합니다. Flutter는 iOS에서 Cupertino 전환·고무줄 스크롤을,
/// 안드로이드에서 Material 동작을 알아서 씁니다. 여기서는 색과 타이포만 얹고
/// 플랫폼 고유 동작은 건드리지 않습니다.
class AppTheme {
  static ThemeData light() => _build(SikpanColors.light, Brightness.light);
  static ThemeData dark() => _build(SikpanColors.dark, Brightness.dark);

  static ThemeData _build(SikpanColors c, Brightness brightness) {
    // 모바일은 시스템 한글 폰트를 그대로 씁니다. 애플 SD 고딕 / 본고딕은 각
    // 플랫폼에서 이미 가장 잘 읽히고, 무엇보다 다른 앱들과 같아 보입니다.
    // 웹만 폴백을 답니다 — CanvasKit은 시스템 폰트를 쓰지 않습니다.
    //
    // ThemeData 생성자에 넣는 것이 중요합니다. textTheme에만 얹으면 버튼처럼
    // ButtonStyle.textStyle을 따로 갖는 위젯이 폴백을 물려받지 못해, 웹에서
    // 버튼 글자만 두부(□)로 남습니다.
    const koFallback = kIsWeb ? <String>['NanumGothic'] : null;
    final base = ThemeData(
      brightness: brightness,
      useMaterial3: true,
      fontFamilyFallback: koFallback,
    );

    final text = base.textTheme.apply(bodyColor: c.ink, displayColor: c.ink);

    return base.copyWith(
      scaffoldBackgroundColor: c.bg,
      colorScheme: base.colorScheme.copyWith(
        brightness: brightness,
        primary: c.accent,
        onPrimary: Colors.white,
        surface: c.surface,
        onSurface: c.ink,
        error: c.danger,
      ),
      extensions: [c],
      textTheme: text.copyWith(
        headlineSmall: text.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
        ),
        titleMedium: text.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
        bodyMedium: text.bodyMedium?.copyWith(fontSize: 15, height: 1.4),
        bodySmall: text.bodySmall?.copyWith(fontSize: 13, color: c.ink2),
        labelSmall: text.labelSmall?.copyWith(fontSize: 11.5, color: c.ink3),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: c.bg,
        surfaceTintColor: Colors.transparent,
        foregroundColor: c.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      dividerTheme: DividerThemeData(color: c.line, thickness: 1, space: 1),
      cardTheme: CardThemeData(
        color: c.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Dim.radius),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surface2,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Dim.radiusSm),
          borderSide: BorderSide(color: c.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Dim.radiusSm),
          borderSide: BorderSide(color: c.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Dim.radiusSm),
          borderSide: BorderSide(color: c.accent, width: 1.6),
        ),
        hintStyle: TextStyle(color: c.ink3),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: c.accent,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 48),
          textStyle: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 15,
              fontFamilyFallback: koFallback),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Dim.radiusSm),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.ink,
          minimumSize: const Size(0, 48),
          side: BorderSide(color: c.line),
          textStyle: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 15,
              fontFamilyFallback: koFallback),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Dim.radiusSm),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: c.accent),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: c.accentSoft,
        height: 62,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 11,
            fontFamilyFallback: koFallback,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
            color: states.contains(WidgetState.selected) ? c.accent : c.ink3,
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: c.ink,
        contentTextStyle: TextStyle(
            color: c.bg, fontSize: 14, fontFamilyFallback: koFallback),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Dim.radiusSm),
        ),
      ),
      cupertinoOverrideTheme: CupertinoThemeData(
        primaryColor: c.accent,
        brightness: brightness,
      ),
    );
  }
}
