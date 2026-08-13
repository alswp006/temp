import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:http/http.dart' as http;

import 'session.dart';

/// 서버가 돌려준 오류. 서버는 `{error, message, detail}` 형태로 답합니다.
class ApiException implements Exception {
  ApiException(this.status, this.code, this.message, this.detail);

  final int status;
  final String code;
  final String message;
  final Map<String, dynamic>? detail;

  /// 목표 칼로리가 너무 공격적이라 멘티 재확인이 필요한 경우.
  bool get requiresConfirmation => detail?['requires_confirmation'] == true;

  @override
  String toString() => message;
}

/// 네트워크가 아예 닿지 않은 경우. 오프라인 큐로 보낼지 판단하는 데 씁니다.
class OfflineException implements Exception {
  const OfflineException();
  @override
  String toString() => '네트워크에 연결할 수 없습니다';
}

class ApiClient {
  ApiClient({required this.baseUrl, required this.session, http.Client? inner})
      : _http = inner ?? http.Client();

  /// 개발 중에는 `--dart-define=SIKPAN_API=http://192.168.0.5:8000` 로 바꿉니다.
  /// 시뮬레이터는 localhost가 맥과 같지만, 실기기는 LAN 주소가 필요합니다.
  final String baseUrl;
  final Session session;
  final http.Client _http;

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final cleaned = <String, String>{};
    query?.forEach((k, v) {
      if (v != null && v != '') cleaned[k] = '$v';
    });
    return Uri.parse('$baseUrl/api$path')
        .replace(queryParameters: cleaned.isEmpty ? null : cleaned);
  }

  Map<String, String> _headers({bool auth = true, bool json = false}) {
    final h = <String, String>{};
    if (auth && session.token != null) {
      h['Authorization'] = 'Bearer ${session.token}';
    }
    if (json) h['Content-Type'] = 'application/json';
    return h;
  }

  Future<dynamic> _send(Future<http.Response> Function() run) async {
    late http.Response res;
    try {
      res = await run().timeout(const Duration(seconds: 30));
    } on SocketException {
      throw const OfflineException();
    } on http.ClientException {
      throw const OfflineException();
    }

    if (res.statusCode == 204 || res.bodyBytes.isEmpty) return null;

    // 서버는 UTF-8로 한국어를 보냅니다. res.body는 latin1로 읽는 경우가 있어
    // 바이트에서 직접 디코드합니다 — 안 그러면 메뉴 이름이 깨집니다.
    final text = utf8.decode(res.bodyBytes);
    dynamic data;
    try {
      data = jsonDecode(text);
    } on FormatException {
      data = null;
    }

    if (res.statusCode >= 400) {
      if (res.statusCode == 401) await session.signOut();
      final map = data is Map<String, dynamic> ? data : const {};
      throw ApiException(
        res.statusCode,
        (map['error'] as String?) ?? 'error',
        (map['message'] as String?) ?? '요청에 실패했습니다 (${res.statusCode})',
        map['detail'] as Map<String, dynamic>?,
      );
    }
    return data;
  }

  Future<dynamic> get(String path,
          {Map<String, dynamic>? query, bool auth = true}) =>
      _send(() =>
          _http.get(_uri(path, query), headers: _headers(auth: auth)));

  Future<dynamic> post(String path,
          {Object? body, bool auth = true}) =>
      _send(() => _http.post(
            _uri(path),
            headers: _headers(auth: auth, json: true),
            body: jsonEncode(body ?? const {}),
          ));

  Future<dynamic> put(String path, {Object? body}) => _send(() => _http.put(
        _uri(path),
        headers: _headers(json: true),
        body: jsonEncode(body ?? const {}),
      ));

  Future<dynamic> patch(String path, {Object? body}) =>
      _send(() => _http.patch(
            _uri(path),
            headers: _headers(json: true),
            body: jsonEncode(body ?? const {}),
          ));

  Future<dynamic> delete(String path) =>
      _send(() => _http.delete(_uri(path), headers: _headers()));

  /// 사진 업로드. 서버는 multipart의 `file` 필드를 받습니다.
  Future<dynamic> upload(
    String path,
    List<int> bytes, {
    String filename = 'photo.jpg',
    Map<String, String> fields = const {},
  }) async {
    final req = http.MultipartRequest('POST', _uri(path))
      ..headers.addAll(_headers())
      ..fields.addAll(fields)
      ..files.add(http.MultipartFile.fromBytes('file', bytes,
          filename: filename));
    return _send(() async {
      final streamed = await _http.send(req);
      return http.Response.fromStream(streamed);
    });
  }

  void close() => _http.close();
}
