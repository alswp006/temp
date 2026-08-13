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
  }

  /// 큐를 비웁니다. 보낸 개수를 돌려줍니다.
  ///
  /// 네트워크로 실패한 항목은 큐에 남기고, 서버가 거절(4xx)한 항목은 버립니다.
  /// 거절된 사진을 계속 재시도하면 영원히 빠지지 않습니다.
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
        debugPrint('outbox drop (${e.status}): ${e.message}');
        await file.delete();
      }
    }

    await _save(remaining);
    return sent;
  }
}
