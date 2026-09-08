import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'client.dart';

/// 오프라인 업로드 큐.
///
/// 급식실 지하나 체육관 지하층에서 와이파이가 끊기는 건 예외가 아니라 일상이고,
/// 그때 셔터를 누른 사진이 사라지면 사용자는 그 앱을 다시 열지 않습니다.
/// 사진은 파일로 두고 메타데이터만 prefs에 남깁니다 — 이미지를 통째로 JSON에
/// 넣으면 prefs가 수 MB로 부풀고 앱 시작이 느려집니다.
class Outbox {
  Outbox(this.api);

  final ApiClient api;
  static const _key = 'sikpan.outbox';

  /// 큐가 바뀌면 알립니다 (적재·전송). 화면이 대기 장수와 새 끼니를 즉시
  /// 반영할 수 있도록, 여기서 알리지 않으면 "이미 보냈는데 아직 대기 중"이라고
  /// 거짓말하는 배너가 남습니다.
  VoidCallback? onChanged;

  Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/outbox');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<List<Map<String, dynamic>>> _entries() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key) ?? const [];
    return raw
        .map((s) {
          try {
            return jsonDecode(s) as Map<String, dynamic>;
          } on FormatException {
            return <String, dynamic>{};
          }
        })
        .where((m) => m.isNotEmpty)
        .toList();
  }

  Future<void> _save(List<Map<String, dynamic>> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, entries.map(jsonEncode).toList());
  }

  Future<int> count() async => (await _entries()).length;

  Future<void> enqueue(
    List<int> bytes, {
    int? canteenId,
    DateTime? shotAt,
  }) async {
    final dir = await _dir();
    final name = 'meal-${DateTime.now().microsecondsSinceEpoch}.jpg';
    await File('${dir.path}/$name').writeAsBytes(bytes);
    final entries = await _entries();
    entries.add({
      'file': name,
      'canteen_id': canteenId,
      'shot_at': (shotAt ?? DateTime.now()).toUtc().toIso8601String(),
    });
    await _save(entries);
    onChanged?.call();
  }

  /// 서버가 이 사진을 영영 받지 않을 상태인가.
  ///
  /// 이 한 줄이 "사진이 사라진다"와 "큐가 영원히 안 빠진다"를 가르므로,
  /// 테스트가 직접 부를 수 있게 공개해 둡니다.
  ///
  /// 이런 항목을 계속 재시도하면 큐에서 영원히 빠지지 않습니다. 반대로 일시적인
  /// 실패를 버리면 사용자의 사진이 사라집니다. 둘을 가르는 선입니다.
  static bool isPermanentReject(int status) {
    if (status == 401 || status == 408 || status == 429) return false;
    return status >= 400 && status < 500;
  }

  /// 큐를 비웁니다. 보낸 개수를 돌려줍니다.
  Future<int> drain() async {
    final entries = await _entries();
    if (entries.isEmpty) return 0;

    final dir = await _dir();
    final remaining = <Map<String, dynamic>>[];
    var sent = 0;

    for (final entry in entries) {
      final file = File('${dir.path}/${entry['file']}');
      if (!await file.exists()) continue; // 파일이 없으면 항목도 버립니다.
      try {
        await api.upload(
          '/meals/photo',
          await file.readAsBytes(),
          filename: 'meal.jpg',
          fields: {
            if (entry['canteen_id'] != null)
              'canteen_id': '${entry['canteen_id']}',
            if (entry['shot_at'] != null) 'shot_at': '${entry['shot_at']}',
          },
        );
        sent++;
        await file.delete();
      } on OfflineException {
        remaining.add(entry); // 아직 오프라인 — 다음 기회에.
      } on ApiException catch (e) {
        // ApiException은 400 이상 **전부**입니다. 예전에는 여기서 무조건
        // 파일을 지웠기 때문에, 서버가 잠깐 500을 뱉거나 토큰이 만료돼 401이
        // 나면 사용자가 찍어 둔 사진이 영구히 사라졌습니다. 사진이 사라지지
        // 않게 하는 것이 이 큐의 존재 이유인데 정반대로 동작했습니다.
        //
        // 서버가 "이 사진은 받을 수 없다"고 확정한 경우만 버립니다. 5xx는
        // 서버 사정이고, 401은 토큰 문제이며, 408·429는 다시 걸면 됩니다.
        if (isPermanentReject(e.status)) {
          debugPrint('outbox drop (${e.status}): ${e.message}');
          await file.delete();
        } else {
          debugPrint('outbox keep (${e.status}): ${e.message}');
          remaining.add(entry);
        }
      }
    }

    await _save(remaining);
    if (sent > 0 || remaining.length != entries.length) onChanged?.call();
    return sent;
  }
}
