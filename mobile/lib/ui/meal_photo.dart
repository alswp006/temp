import 'package:flutter/material.dart';

import '../app_state.dart';
import '../theme/tokens.dart';

/// 식사 사진.
///
/// `/api/media/{path}`는 인증을 요구합니다 — 사진은 이 시스템에서 가장 민감한
/// 산출물(얼굴, 이름표, 위치 단서)이라 `diet:read`와 분리된 `photo:read`
/// 스코프를 따로 둡니다. 그래서 헤더를 실어 보냅니다.
///
/// 사진을 찍게 해 놓고 다시 보여주지 않으면, 사용자는 자기가 무엇을 기록했는지
/// 확인할 방법이 없습니다.
class MealPhoto extends StatelessWidget {
  const MealPhoto({
    super.key,
    required this.path,
    this.height = 200,
    this.radius = Dim.radius,
    this.fadeIn = true,
  });

  final String path;
  final double height;
  final double radius;
  final bool fadeIn;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final c = context.c;
    final url = '${scope.api.baseUrl}/api/media/$path';

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.network(
        url,
        height: height,
        width: double.infinity,
        fit: BoxFit.cover,
        headers: {
          if (scope.session.token != null)
            'Authorization': 'Bearer ${scope.session.token}',
        },
        // 사진이 딱 나타나면 화면이 튑니다. 짧게 페이드하면 도착이 부드럽습니다.
        frameBuilder: (context, child, frame, wasSyncLoaded) {
          if (!fadeIn || wasSyncLoaded) return child;
          return AnimatedOpacity(
            opacity: frame == null ? 0 : 1,
            duration: Motion.base,
            curve: Motion.curve,
            child: child,
          );
        },
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return Container(
            height: height,
            color: c.surface2,
            alignment: Alignment.center,
            child: const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        },
        // 사진이 안 열려도 나머지 화면은 멀쩡해야 합니다. 권한을 껐거나
        // 파일이 지워진 경우가 정상적으로 있습니다.
        errorBuilder: (context, error, stack) => Container(
          height: height,
          color: c.surface2,
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.image_not_supported_outlined, color: c.ink3, size: 22),
              const SizedBox(height: Dim.s6),
              Text('사진을 불러올 수 없습니다',
                  style: TextStyle(fontSize: 12, color: c.ink3)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 목록용 정사각 썸네일.
///
/// 목록이 끼니 아이콘(달·해)만 보여줄 때는, 앱이 이미 갖고 있는 가장 좋은 정보를
/// 버리고 있었습니다. 자기가 뭘 먹었는지는 글자보다 사진이 훨씬 빨리 알려줍니다.
/// 사진이 없거나 아직 분석 전이면 끼니 아이콘으로 물러납니다.
class MealThumb extends StatelessWidget {
  const MealThumb({
    super.key,
    required this.path,
    required this.fallback,
    this.size = 54,
  });

  final String? path;
  final IconData fallback;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final scope = AppScope.of(context);

    final placeholder = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(Dim.radiusSm),
      ),
      child: Icon(fallback, size: size * 0.42, color: c.ink3),
    );

    if (path == null || path!.isEmpty) return placeholder;

    return ClipRRect(
      borderRadius: BorderRadius.circular(Dim.radiusSm),
      child: Image.network(
        '${scope.api.baseUrl}/api/media/${path!}',
        width: size,
        height: size,
        fit: BoxFit.cover,
        headers: {
          if (scope.session.token != null)
            'Authorization': 'Bearer ${scope.session.token}',
        },
        frameBuilder: (context, child, frame, wasSync) {
          if (wasSync) return child;
          return AnimatedSwitcher(
            duration: Motion.base,
            child: frame == null ? placeholder : child,
          );
        },
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : placeholder,
        errorBuilder: (context, error, stack) => placeholder,
      ),
    );
  }
}
