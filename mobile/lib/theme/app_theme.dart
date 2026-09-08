import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tokens.dart';

/// 플랫폼별 결을 살린 테마.
///
/// 이 앱이 PWA를 버리고 Flutter로 온 이유가 "웹 티"였으므로, 플랫폼 고유 동작은
/// 건드리지 않습니다. Flutter는 iOS에서 Cupertino 전환·뒤로가기 스와이프·고무줄
/// 스크롤을, 안드로이드에서 Material 동작을 알아서 씁니다. 여기서 얹는 것은
/// 색·타이포·모서리·여백까지입니다.
///
/// 다만 **기본값을 그대로 쓰는 것**과 **아무것도 정하지 않는 것**은 다릅니다.
/// 이전 테마는 후자에 가까웠습니다 — 카드도 버튼도 입력칸도 머티리얼 기본형에
/// 색만 칠한 상태라, 어느 화면이든 같은 회색 상자의 나열로 보였습니다.
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
    final isDark = brightness == Brightness.dark;

    return base.copyWith(
      scaffoldBackgroundColor: c.bg,
      colorScheme: base.colorScheme.copyWith(
        brightness: brightness,
        primary: c.accent,
        onPrimary: Colors.white,
        secondary: c.accent,
        surface: c.surface,
        onSurface: c.ink,
        surfaceContainerHighest: c.surface2,
        outline: c.line,
        error: c.danger,
      ),
      extensions: [c],

      // 큰 숫자와 제목은 자간을 좁혀야 "디자인된" 인상이 납니다. 기본 자간은
      // 본문용이라 44pt 숫자에 그대로 쓰면 헐겁게 벌어집니다.
      textTheme: text.copyWith(
        headlineLarge: text.headlineLarge?.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: -1.0,
        ),
        headlineSmall: text.headlineSmall?.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: -0.5,
        ),
        titleLarge: text.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
        ),
        titleMedium: text.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
          fontSize: 15.5,
          letterSpacing: -0.2,
        ),
        bodyMedium: text.bodyMedium?.copyWith(fontSize: 15, height: 1.45),
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
        // 상태바 글자색을 배경에 맞춰 줍니다. 안 맞추면 다크 배경 위에 검은
        // 시계가 얹혀 안 보입니다.
        systemOverlayStyle:
            isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      ),

      dividerTheme: DividerThemeData(color: c.lineSoft, thickness: 1, space: 1),

      cardTheme: CardThemeData(
        color: c.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Dim.radius),
        ),
      ),

      // 입력칸에서 테두리를 걷어냅니다. 채움색만으로 충분히 구분되고, 테두리가
      // 없으면 폼이 훨씬 조용해집니다. 포커스일 때만 초록 링이 들어옵니다.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surface2,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: Dim.s16, vertical: 15),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Dim.radiusSm),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Dim.radiusSm),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Dim.radiusSm),
          borderSide: BorderSide(color: c.accent, width: 1.8),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Dim.radiusSm),
          borderSide: BorderSide(color: c.danger, width: 1.4),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Dim.radiusSm),
          borderSide: BorderSide(color: c.danger, width: 1.8),
        ),
        hintStyle: TextStyle(color: c.ink3),
        errorStyle: TextStyle(color: c.danger, fontSize: 12.5),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: c.accent,
          foregroundColor: Colors.white,
          disabledBackgroundColor: c.surface2,
          disabledForegroundColor: c.ink3,
          minimumSize: const Size(0, 50),
          textStyle: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 15,
              letterSpacing: -0.2,
              fontFamilyFallback: koFallback),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Dim.radiusSm),
          ),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.ink,
          minimumSize: const Size(0, 50),
          side: BorderSide(color: c.line),
          textStyle: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 15,
              letterSpacing: -0.2,
              fontFamilyFallback: koFallback),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Dim.radiusSm),
          ),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: c.accent,
          textStyle: const TextStyle(
              fontWeight: FontWeight.w700, fontFamilyFallback: koFallback),
        ),
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: c.accentSoft,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(99),
        ),
        height: 64,
        elevation: 0,
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
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 23,
            color: states.contains(WidgetState.selected) ? c.accent : c.ink3,
          ),
        ),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: c.surface,
        dragHandleColor: c.line,
        shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(Dim.radiusXl)),
        ),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Dim.radiusLg),
        ),
        titleTextStyle: TextStyle(
          color: c.ink,
          fontSize: 17,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.3,
          fontFamilyFallback: koFallback,
        ),
        contentTextStyle: TextStyle(
          color: c.ink2,
          fontSize: 14.5,
          height: 1.45,
          fontFamilyFallback: koFallback,
        ),
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: c.ink,
        contentTextStyle: TextStyle(
            color: c.bg, fontSize: 14, fontFamilyFallback: koFallback),
        behavior: SnackBarBehavior.floating,
        insetPadding: const EdgeInsets.fromLTRB(Dim.s16, 0, Dim.s16, Dim.s16),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Dim.radiusSm),
        ),
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? Colors.white : c.surface),
        trackColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? c.accent : c.surface2),
        trackOutlineColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? c.accent : c.line),
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.accent,
        linearTrackColor: c.surface2,
        circularTrackColor: Colors.transparent,
      ),

      cupertinoOverrideTheme: CupertinoThemeData(
        primaryColor: c.accent,
        brightness: brightness,
      ),
    );
  }
}
