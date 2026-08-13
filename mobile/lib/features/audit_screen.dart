import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../app_state.dart';
import '../theme/tokens.dart';
import '../ui/labels.dart';
import '../ui/widgets.dart';

/// 누가 내 기록을 건드렸는지.
///
/// 대리 기록을 허용하는 제품에서 이 화면은 부가 기능이 아니라 전제 조건입니다.
class AuditScreen extends StatefulWidget {
  const AuditScreen({super.key});

  @override
  State<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends State<AuditScreen> {
  List<AuditEntry> _rows = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = (await context.api.get('/audit-log') as List)
          .map((e) => AuditEntry.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() {
        _rows = list;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showToast(context, e.message);
    }
  }

  static const _actionLabel = {
    'create': '만듦',
    'update': '고침',
    'delete': '지움',
    'grant': '권한 부여',
  };

  static const _entityLabel = {
    'meal': '식사',
    'workout': '운동',
    'mentorship': '연결',
    'mentorship_permissions': '연결 권한',
    'target': '목표',
  };

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('변경 이력',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
            Text('누가 내 기록을 건드렸는지',
                style: TextStyle(fontSize: 12, color: c.ink3)),
          ],
        ),
        toolbarHeight: 64,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ScreenBody(
              onRefresh: _load,
              children: [
                SikpanCard(
                  child: _rows.isEmpty
                      ? const EmptyState('대리 기록 이력이 없습니다.')
                      : Column(
                          children: [
                            for (var i = 0; i < _rows.length; i++)
                              ListRow(
                                showDivider: i != _rows.length - 1,
                                content: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${_rows[i].actorName ?? "?"}님이 '
                                      '${_entityLabel[_rows[i].entity] ?? _rows[i].entity}을(를) '
                                      '${_actionLabel[_rows[i].action] ?? _rows[i].action}',
                                      style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(Fmt.dateTime(_rows[i].createdAt),
                                        style: TextStyle(
                                            fontSize: 12, color: c.ink3)),
                                  ],
                                ),
                              ),
                          ],
                        ),
                ),
              ],
            ),
    );
  }
}
