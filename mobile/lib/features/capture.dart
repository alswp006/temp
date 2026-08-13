import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../api/client.dart';
import '../app_state.dart';
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
      await scope.api.upload(
        '/meals/photo',
        bytes,
        filename: 'meal.jpg',
        fields: {
          if (canteenId != null) 'canteen_id': '$canteenId',
          'shot_at': shotAt.toUtc().toIso8601String(),
        },
      );
      if (context.mounted) showToast(context, '접수했습니다. 분석 중…');
      return true;
    } on OfflineException {
      await scope.outbox.enqueue(bytes, canteenId: canteenId, shotAt: shotAt);
      if (context.mounted) {
        showToast(context, '오프라인 — 사진을 저장했습니다. 연결되면 자동 전송합니다.');
      }
      return true;
    } on ApiException catch (e) {
      if (context.mounted) showToast(context, e.message);
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
    {String title = '사진'}) {
  return showModalBottomSheet<ImageSource>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(title,
                  style: Theme.of(context).textTheme.titleMedium),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('카메라로 촬영'),
            onTap: () => Navigator.pop(context, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('앨범에서 선택'),
            onTap: () => Navigator.pop(context, ImageSource.gallery),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
