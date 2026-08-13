import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

const mealLabel = <String, String>{
  'breakfast': '조식',
  'lunch': '중식',
  'dinner': '석식',
  'snack': '간식',
};

const mealIcon = <String, IconData>{
  'breakfast': Icons.wb_twilight,
  'lunch': Icons.rice_bowl,
  'dinner': Icons.nightlight_round,
  'snack': Icons.apple,
};

const categoryLabel = <String, String>{
  'rice': '밥',
  'soup': '국·찌개',
  'main': '주찬',
  'side': '부찬',
  'kimchi': '김치',
  'dessert': '후식',
};

/// 스코프 순서가 곧 동의 화면의 순서입니다. 읽기를 먼저, 쓰기를 나중에 두어
/// 사용자가 위에서부터 훑을 때 위험도가 올라가도록 배치했습니다.
const scopeLabel = <String, String>{
  'diet:read': '식단 조회',
  'diet:write': '식단 대리 기록',
  'workout:read': '운동 조회',
  'workout:write': '운동 대리 기록',
  'weight:read': '체중 조회',
  'photo:read': '사진 원본 조회',
  'goal:propose': '목표 제안',
};

class Fmt {
  static final _kcal = NumberFormat('#,###', 'ko_KR');

  static String kcal(num? v) => _kcal.format((v ?? 0).round());
  static String g(num? v) => '${(v ?? 0).round()}g';
  static String kg(num? v) => v == null ? '–' : '${v.toStringAsFixed(1)}kg';
  static String pct(num? v) => '${((v ?? 0) * 100).round()}%';

  /// '2026-08-13' 또는 ISO 타임스탬프 → '8월 13일'
  static String date(String iso) {
    final d = _parse(iso);
    if (d == null) return iso;
    return '${d.month}월 ${d.day}일';
  }

  static String weekday(String iso) {
    final d = _parse(iso);
    if (d == null) return '';
    // DateTime.weekday: 월=1 … 일=7
    return const ['월', '화', '수', '목', '금', '토', '일'][d.weekday - 1];
  }

  /// '오후 12:02'
  ///
  /// intl 패키지가 들고 있는 한국어 데이터의 AMPMS가 `[AM, PM]`이라
  /// `DateFormat('a')`는 한국어 로케일에서도 영어를 뱉습니다. 사용자에게
  /// 가장 자주 보이는 문자열이라 직접 만듭니다.
  static String time(DateTime dt) {
    final ampm = dt.hour < 12 ? '오전' : '오후';
    final h12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    return '$ampm $h12:${dt.minute.toString().padLeft(2, '0')}';
  }

  static String dateTime(DateTime dt) =>
      '${dt.month}월 ${dt.day}일 ${time(dt)}';

  static DateTime? _parse(String iso) {
    if (iso.isEmpty) return null;
    // 날짜만 온 경우 로컬 자정으로 읽습니다. UTC로 읽으면 한국에서 하루가
    // 밀려 표시됩니다.
    return DateTime.tryParse(iso.length == 10 ? '${iso}T00:00:00' : iso)
        ?.toLocal();
  }
}
