import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../app_state.dart';
import '../theme/tokens.dart';
import '../ui/labels.dart';
import '../ui/widgets.dart';

/// 이미 맺은 연결의 권한을 멘티가 다시 만지는 화면. 해제는 즉시 반영됩니다.
class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key, required this.mentorshipId});
  final int mentorshipId;

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> {
  Mentorship? _m;
  final _granted = <String, bool>{};
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = (await context.api.get('/mentorships') as List)
          .map((e) => Mentorship.fromJson(e as Map<String, dynamic>))
          .toList();
      final found =
          list.where((m) => m.id == widget.mentorshipId).firstOrNull;
      if (!mounted) return;
      setState(() {
        _m = found;
        for (final scope in scopeLabel.keys) {
          _granted[scope] = found?.permissions[scope] ?? false;
        }
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showToast(context, e.message);
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await context.api.put('/mentorships/${widget.mentorshipId}/permissions',
          body: {'permissions': _granted});
      if (!mounted) return;
      showToast(context, '변경했습니다');
      context.pop();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final m = _m;

    return Scaffold(
      appBar: AppBar(
        title: Text(m == null ? '권한' : '${m.mentorName ?? ""} 권한',
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : m == null
              ? const EmptyState('연결을 찾을 수 없습니다.')
              : ScreenBody(
                  children: [
                    SikpanCard(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                      child: Column(
                        children: [
                          for (var i = 0; i < scopeLabel.length; i++)
                            _Toggle(
                              scope: scopeLabel.keys.elementAt(i),
                              value:
                                  _granted[scopeLabel.keys.elementAt(i)] ?? false,
                              last: i == scopeLabel.length - 1,
                              onChanged: (v) => setState(() =>
                                  _granted[scopeLabel.keys.elementAt(i)] = v),
                            ),
                        ],
                      ),
                    ),
                    FilledButton(
                        onPressed: _busy ? null : _save,
                        child: const Text('저장')),
                    NoticeBanner('체중 대리 입력은 어떤 경우에도 열 수 없습니다.',
                        tone: BadgeTone.accent),
                    Text(
                      '끄는 즉시 열람이 차단됩니다. 지금까지 남은 대리 기록 이력은 변경 이력에서 계속 보실 수 있습니다.',
                      style: TextStyle(fontSize: 12, color: c.ink3, height: 1.5),
                    ),
                  ],
                ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.scope,
    required this.value,
    required this.onChanged,
    required this.last,
  });

  final String scope;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final isWrite = scope.endsWith(':write');
    return Column(
      children: [
        SwitchListTile.adaptive(
          value: value,
          onChanged: onChanged,
          contentPadding: EdgeInsets.zero,
          title: Text(scopeLabel[scope] ?? scope,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          subtitle: Text(isWrite ? '대신 기록할 수 있습니다' : '조회만 가능합니다',
              style: TextStyle(
                  fontSize: 12, color: isWrite ? c.warn : c.ink3)),
        ),
        if (!last) Divider(height: 1, color: c.line),
      ],
    );
  }
}
