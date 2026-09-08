import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import 'features/capture.dart';
import 'theme/tokens.dart';
import 'ui/labels.dart';
import 'ui/widgets.dart';

/// 탭 5개 + 촬영 버튼.
///
/// 촬영이 탭 하나가 아니라 떠 있는 버튼인 이유는, 이 앱에서 가장 자주 하는
/// 동작이면서 "화면 이동"이 아니라 "행동"이기 때문입니다.
///
/// 다만 **모든 탭에 떠 있지는 않습니다.** 주간 리포트나 더보기에서는 촬영이
/// 그 화면의 할 일이 아니고, 실제로 더보기의 "저장" 버튼 위에 겹쳐 앉아
/// 누르지 못하게 만들고 있었습니다. 지금은 오늘·기록에서만 나타납니다.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  static const _tabs = [
    (path: '/today', label: '오늘', icon: Icons.rice_bowl_outlined, active: Icons.rice_bowl),
    (path: '/log', label: '기록', icon: Icons.edit_outlined, active: Icons.edit),
    (path: '/week', label: '주간', icon: Icons.bar_chart_outlined, active: Icons.bar_chart),
    (path: '/battle', label: '배틀', icon: Icons.emoji_events_outlined, active: Icons.emoji_events),
    (path: '/more', label: '더보기', icon: Icons.more_horiz, active: Icons.more_horiz),
  ];

  static const _titles = ['오늘', '기록', '주간 리포트', '배틀', '더보기'];
  static const _subtitles = [
    null,
    'AI 호출 없이도 다 됩니다',
    null,
    '기록으로 겨룹니다',
    null,
  ];

  /// 촬영 버튼이 뜨는 탭.
  static const _captureTabs = {0, 1};

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final index = navigationShell.currentIndex;

    // 오늘 탭의 부제는 날짜입니다. 화면에 "오늘"만 있으면 어느 날의 오늘인지
    // 알 수 없고, 기록 앱에서 그건 꽤 자주 궁금해집니다.
    final now = DateTime.now();
    final subtitle = index == 0
        ? '${now.month}월 ${now.day}일 ${Fmt.weekday(now.toIso8601String())}요일'
        : _subtitles[index];

    return Scaffold(
      appBar: AppBar(
        titleSpacing: Dim.s20,
        toolbarHeight: subtitle == null ? 56 : 68,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_titles[index],
                style: const TextStyle(
                    fontSize: 27,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.9)),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Text(subtitle,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: c.ink3)),
              ),
          ],
        ),
      ),
      body: navigationShell,

      // 탭을 옮길 때 버튼이 툭 사라지면 화면이 덜컥거립니다. 크기와 투명도를
      // 함께 줄이면 "이 화면의 일이 아니다"가 부드럽게 읽힙니다.
      floatingActionButton: AnimatedScale(
        scale: _captureTabs.contains(index) ? 1 : 0,
        duration: Motion.base,
        curve: Motion.emphasized,
        child: AnimatedOpacity(
          opacity: _captureTabs.contains(index) ? 1 : 0,
          duration: Motion.fast,
          child: _CaptureButton(onTap: () => _capture(context)),
        ),
      ),

      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: c.surface,
          border: Border(top: BorderSide(color: c.lineSoft)),
        ),
        child: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: (i) {
            HapticFeedback.selectionClick();
            navigationShell.goBranch(i, initialLocation: i == index);
          },
          destinations: [
            for (var i = 0; i < _tabs.length; i++)
              NavigationDestination(
                icon: Icon(_tabs[i].icon),
                selectedIcon: Icon(_tabs[i].active, color: c.accent),
                label: _tabs[i].label,
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _capture(BuildContext context) async {
    final source = await askImageSource(
      context,
      title: '식사 촬영',
      subtitle: '한 장이면 됩니다. 분석은 백그라운드에서 돌아갑니다.',
    );
    if (source == null || !context.mounted) return;
    final ok = await MealCapture.shoot(context, source: source);
    // 업로드가 성공하면 MealCapture가 DataBus를 울리므로 오늘 화면은 이미
    // 다시 불러오는 중입니다. 여기서는 보여 줄 곳으로 옮기기만 합니다.
    if (ok && context.mounted) {
      navigationShell.goBranch(0, initialLocation: true);
    }
  }
}

/// 촬영 버튼.
///
/// 기본 FAB보다 조금 크고, 초록 그라데이션과 색 그림자를 씁니다. 화면에서 가장
/// 중요한 한 가지 행동이므로 가장 눈에 띄어야 합니다.
class _CaptureButton extends StatelessWidget {
  const _CaptureButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: () {
        HapticFeedback.mediumImpact();
        onTap();
      },
      haptic: false,
      scale: 0.92,
      child: Container(
        width: 62,
        height: 62,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [c.accent, c.accentDeep],
          ),
          borderRadius: BorderRadius.circular(Dim.radiusLg),
          boxShadow: [
            BoxShadow(
              color: c.accent.withValues(alpha: c.isDark ? 0.35 : 0.40),
              blurRadius: 18,
              offset: const Offset(0, 7),
            ),
          ],
        ),
        child: const Icon(Icons.photo_camera_rounded,
            size: 27, color: Colors.white),
      ),
    );
  }
}
