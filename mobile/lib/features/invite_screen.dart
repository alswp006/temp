import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../app_state.dart';
import '../theme/tokens.dart';
import '../ui/labels.dart';
import '../ui/widgets.dart';

/// 멘티가 보는 동의 화면.
///
/// 이 화면이 로그인 없이 열리는 것이 핵심입니다. 무엇을 요구받는지 보기도 전에
/// 계정부터 만들게 하면 동의의 순서가 거꾸로입니다. 기본값은 전부 꺼짐이고,
/// 권장 항목만 미리 켜져 있습니다.
class InviteScreen extends StatefulWidget {
  const InviteScreen({super.key, required this.code});
  final String code;

  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<InviteScreen> {
  InvitePreview? _preview;
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
      final json = await context.api
          .get('/mentorships/invite/${widget.code}', auth: false);
      if (!mounted) return;
      final preview = InvitePreview.fromJson(json as Map<String, dynamic>);
      setState(() {
        _preview = preview;
        for (final s in preview.scopes) {
          _granted[s.scope] = s.recommended;
        }
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showToast(context, e.message);
    }
  }

  Future<void> _accept() async {
    if (!context.session.isLoggedIn) {
      showToast(context, '연결하려면 먼저 로그인해 주세요');
      context.go('/login');
      return;
    }
    setState(() => _busy = true);
    try {
      await context.api.post('/mentorships/accept', body: {
        'invite_code': widget.code,
        'permissions': _granted,
      });
      if (!mounted) return;
      showToast(context, '연결했습니다');
      context.go('/more');
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final preview = _preview;

    return Scaffold(
      appBar: AppBar(
        title: Text(preview?.type == 'coach' ? '코치 연결 요청' : '연결 요청',
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : preview == null
              ? const EmptyState('초대를 찾을 수 없습니다.')
              : ScreenBody(
                  children: [
                    SikpanCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${preview.mentorName ?? "누군가"}님이 연결을 요청했습니다',
                              style: const TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 8),
                          Text(
                              '허용할 항목만 켜 주세요. 전부 꺼진 상태가 기본이고, 언제든 바꿀 수 있습니다.',
                              style: TextStyle(
                                  fontSize: 13, height: 1.45, color: c.ink2)),
                        ],
                      ),
                    ),
                    SikpanCard(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                      child: Column(
                        children: [
                          for (var i = 0; i < preview.scopes.length; i++)
                            _ScopeToggle(
                              scope: preview.scopes[i],
                              value: _granted[preview.scopes[i].scope] ?? false,
                              last: i == preview.scopes.length - 1,
                              onChanged: (v) => setState(
                                  () => _granted[preview.scopes[i].scope] = v),
                            ),
                        ],
                      ),
                    ),
                    NoticeBanner(preview.notice),
                    FilledButton(
                      onPressed: _busy ? null : _accept,
                      child: const Text('이 조건으로 연결'),
                    ),
                  ],
                ),
    );
  }
}

class _ScopeToggle extends StatelessWidget {
  const _ScopeToggle({
    required this.scope,
    required this.value,
    required this.onChanged,
    required this.last,
  });

  final InviteScope scope;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      children: [
        SwitchListTile.adaptive(
          value: value,
          onChanged: onChanged,
          contentPadding: EdgeInsets.zero,
          title: Text(scopeLabel[scope.scope] ?? scope.scope,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          subtitle: Text(
            scope.isWrite ? '대신 기록할 수 있습니다' : '조회만 가능합니다',
            style: TextStyle(
                fontSize: 12, color: scope.isWrite ? c.warn : c.ink3),
          ),
        ),
        if (!last) Divider(height: 1, color: c.line),
      ],
    );
  }
}
