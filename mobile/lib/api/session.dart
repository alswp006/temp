import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// 로그인 상태.
///
/// 토큰은 Keychain/Keystore에, 나머지는 일반 저장소에 둡니다. 이 토큰 하나면
/// 남의 건강 기록을 읽을 수 있으므로 평문 prefs에 둘 물건이 아닙니다.
class Session extends ChangeNotifier {
  Session({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _tokenKey = 'sikpan.token';
  static const _userKey = 'sikpan.user';
  static const _canteenKey = 'sikpan.canteen';

  final FlutterSecureStorage _storage;

  String? _token;
  User? _user;
  int? _canteenId;
  bool _restored = false;

  String? get token => _token;
  User? get user => _user;
  int? get canteenId => _canteenId;
  bool get isLoggedIn => _token != null;
  bool get restored => _restored;

  Future<void> restore() async {
    try {
      _token = await _storage.read(key: _tokenKey);
    } on Exception {
      // 시크릿 저장소를 못 쓰는 기기/에뮬레이터가 있습니다. 로그인 화면으로
      // 떨어뜨릴지언정 앱이 부팅에서 죽으면 안 됩니다.
      _token = null;
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_userKey);
    if (raw != null) {
      try {
        _user = User.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } on FormatException {
        _user = null;
      }
    }
    final canteen = prefs.getInt(_canteenKey);
    _canteenId = canteen;
    _restored = true;
    notifyListeners();
  }

  Future<void> signIn(String token, User user) async {
    _token = token;
    _user = user;
    await _storage.write(key: _tokenKey, value: token);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userKey, jsonEncode(user.toJson()));
    notifyListeners();
  }

  Future<void> updateUser(User user) async {
    _user = user;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userKey, jsonEncode(user.toJson()));
    notifyListeners();
  }

  Future<void> signOut() async {
    _token = null;
    _user = null;
    await _storage.delete(key: _tokenKey);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_userKey);
    notifyListeners();
  }

  Future<void> selectCanteen(int? id) async {
    _canteenId = id;
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(_canteenKey);
    } else {
      await prefs.setInt(_canteenKey, id);
    }
    notifyListeners();
  }
}
