import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import 'features/capture.dart';
import 'theme/tokens.dart';

/// 탭 5개 + 촬영 버튼.
///
/// 촬영이 탭 하나가 아니라 떠 있는 버튼인 이유는, 이 앱에서 가장 자주 하는
/// 동작이면서 "화면 이동"이 아니라 "행동"이기 때문입니다.
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

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final index = navigationShell.currentIndex;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        toolbarHeight: _subtitles[index] == null ? 56 : 66,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_titles[index],
                style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.8)),
            if (_subtitles[index] != null)
              Text(_subtitles[index]!,
                  style: TextStyle(fontSize: 12.5, color: c.ink3)),
          ],
        ),
      ),
      body: navigationShell,
      floatingActionButton: FloatingActionButton(
        onPressed: () => _capture(context),
        backgroundColor: c.accent,
        foregroundColor: Colors.white,
        elevation: 2,
        tooltip: '식사 촬영',
        child: const Icon(Icons.photo_camera, size: 26),
      ),
      bottomNavigationBar: NavigationBar(
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
    );
  }

  Future<void> _capture(BuildContext context) async {
    final source = await askImageSource(context, title: '식사 촬영');
    if (source == null || !context.mounted) return;
    final ok = await MealCapture.shoot(context, source: source);
    if (ok && context.mounted) {
      // 오늘 화면이 폴링으로 알아서 갱신되므로, 탭만 옮겨 줍니다.
      navigationShell.goBranch(0, initialLocation: true);
    }
  }
}
