import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../api/client.dart';
import '../app_state.dart';
import '../theme/tokens.dart';
import '../ui/widgets.dart';

/// 사진 한 장을 식사로 만드는 경로. 앱에서 가장 자주 눌리는 버튼이므로
/// 실패 처리가 특히 중요합니다 — 네트워크가 없으면 큐에 넣고, 사용자에게는
/// "사라지지 않았다"는 사실을 분명히 알립니다.
class MealCapture {
  static final _picker = ImagePicker();

  /// 촬영 → 업로드. 성공하면 true.
  static Future<bool> shoot(BuildContext context, {ImageSource? source}) async {
    final picked = await _picker.pickImage(
      source: source ?? ImageSource.camera,
      // 12MP 원본은 급식실 와이파이에서 낭비입니다. 모델도 1600px 위로는
      // 이득이 없습니다.
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 85,
    );
    if (picked == null) return false;
    if (!context.mounted) return false;

    final bytes = await picked.readAsBytes();
    if (!context.mounted) return false;

    final scope = AppScope.of(context);
    final canteenId = scope.session.canteenId;
    final shotAt = DateTime.now();

    HapticFeedback.mediumImpact();
    showToast(context, '업로드 중…');

    try {
      try {
        await scope.api.upload(
          '/meals/photo',
          bytes,
          filename: 'meal.jpg',
          fields: {
            if (canteenId != null) 'canteen_id': '$canteenId',
            'shot_at': shotAt.toUtc().toIso8601String(),
          },
        );
      } on ApiException catch (e) {
        // 고른 식당이 서버에서 사라졌거나 권한을 잃으면 403이 납니다. 그런데
        // 선택은 기기에만 남아 있어서, 목록이 비면 화면에서 지울 방법조차
        // 없습니다. 그러면 사진을 찍을 때마다 영원히 실패합니다.
        //
        // 서버가 그 식당을 거절하면 선택을 버리고 한 번 더 보냅니다. 식당은
        // 정확도를 올리는 장치일 뿐이고, 기록 자체를 막을 이유가 없습니다.
        if (e.status != 403 || canteenId == null) rethrow;
        await scope.session.selectCanteen(null);
        await scope.api.upload(
          '/meals/photo',
          bytes,
          filename: 'meal.jpg',
          fields: {'shot_at': shotAt.toUtc().toIso8601String()},
        );
      }
      // 화면들이 스스로 다시 불러옵니다. 이게 없으면 서버에는 저장됐는데
      // 오늘 화면은 "0끼"인 채로 남습니다.
      scope.data.bump();
      if (context.mounted) {
        showToast(context, '접수했습니다. 분석 중…', tone: ToastTone.success);
      }
      return true;
    } on OfflineException {
      await scope.outbox.enqueue(bytes, canteenId: canteenId, shotAt: shotAt);
      if (context.mounted) {
        showToast(context, '오프라인 — 사진을 저장했습니다. 연결되면 자동 전송합니다.');
      }
      return true;
    } on ApiException catch (e) {
      if (context.mounted) showToast(context, e.message, tone: ToastTone.error);
      return false;
    }
  }

  /// 갤러리에서 고르기. 시뮬레이터에는 카메라가 없어서 이 경로가 필요합니다.
  static Future<bool> pickFromGallery(BuildContext context) =>
      shoot(context, source: ImageSource.gallery);

  /// 임의의 사진을 골라 바이트로. 식단표·운동 수첩 업로드에서 씁니다.
  static Future<List<int>?> pickBytes({
    ImageSource source = ImageSource.camera,
    int maxEdge = 1600,
  }) async {
    final picked = await _picker.pickImage(
      source: source,
      maxWidth: maxEdge.toDouble(),
      maxHeight: maxEdge.toDouble(),
      imageQuality: 85,
    );
    if (picked == null) return null;
    return picked.readAsBytes();
  }
}

/// 촬영 소스를 고르는 시트. 카메라가 없는 기기(시뮬레이터)에서도 막히지
/// 않도록 항상 앨범 선택지를 함께 둡니다.
Future<ImageSource?> askImageSource(BuildContext context,
    {String title = '사진', String? subtitle}) {
  return showModalBottomSheet<ImageSource>(
    context: context,
    showDragHandle: true,
    backgroundColor: context.c.surface,
    shape: const RoundedRectangleBorder(
      borderRadius:
          BorderRadius.vertical(top: Radius.circular(Dim.radiusXl)),
    ),
    builder: (context) {
      final c = context.c;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              Dim.s16, Dim.s4, Dim.s16, Dim.s16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    Dim.s4, 0, Dim.s4, Dim.s16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.4)),
                    if (subtitle != null) ...[
                      const SizedBox(height: Dim.s4),
                      Text(subtitle,
                          style: TextStyle(fontSize: 13, color: c.ink3)),
                    ],
                  ],
                ),
              ),
              _SourceTile(
                icon: Icons.photo_camera_rounded,
                label: '카메라로 촬영',
                hint: '지금 눈앞의 것을 찍습니다',
                onTap: () => Navigator.pop(context, ImageSource.camera),
              ),
              const SizedBox(height: Dim.s8),
              _SourceTile(
                icon: Icons.photo_library_rounded,
                label: '앨범에서 선택',
                hint: '이미 찍어 둔 사진을 씁니다',
                onTap: () => Navigator.pop(context, ImageSource.gallery),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.icon,
    required this.label,
    required this.hint,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(Dim.s16),
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: BorderRadius.circular(Dim.radius),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.accentSoft,
                borderRadius: BorderRadius.circular(Dim.radiusSm),
              ),
              child: Icon(icon, size: 21, color: c.accent),
            ),
            const SizedBox(width: Dim.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(height: Dim.s2),
                  Text(hint,
                      style: TextStyle(fontSize: 12.5, color: c.ink3)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 20, color: c.ink3),
          ],
        ),
      ),
    );
  }
}
