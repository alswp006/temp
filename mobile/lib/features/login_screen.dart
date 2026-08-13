import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../app_state.dart';
import '../theme/tokens.dart';
import '../ui/widgets.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _nickname = TextEditingController();
  final _code = TextEditingController();
  bool _codeSent = false;
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _nickname.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _requestCode() async {
    final email = _email.text.trim();
    if (email.isEmpty) {
      showToast(context, '이메일을 입력해 주세요');
      return;
    }
    setState(() => _busy = true);
    try {
      final res = await context.api.post(
        '/auth/request-code',
        body: {
          'email': email,
          'nickname':
              _nickname.text.trim().isEmpty ? null : _nickname.text.trim(),
        },
        auth: false,
      ) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() => _codeSent = true);
      final devCode = res['dev_code'] as String?;
      if (devCode != null) {
        // 개발 서버는 코드를 그대로 돌려줍니다. 손으로 옮겨 적는 수고를 없앱니다.
        _code.text = devCode;
        showToast(context, '개발 모드 코드: $devCode');
      } else {
        showToast(context, '메일로 코드를 보냈습니다');
      }
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } on OfflineException catch (e) {
      if (mounted) showToast(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    setState(() => _busy = true);
    final api = context.api;
    final session = context.session;
    try {
      final res = await api.post(
        '/auth/verify',
        body: {'email': _email.text.trim(), 'code': _code.text.trim()},
        auth: false,
      ) as Map<String, dynamic>;
      final user = User.fromJson(res['user'] as Map<String, dynamic>);
      await session.signIn(res['access_token'] as String, user);
      if (!mounted) return;
      context.go('/today');
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } on OfflineException catch (e) {
      if (mounted) showToast(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('식판',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 40,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -1.5,
                          color: c.accent)),
                  const SizedBox(height: 6),
                  Text('기록을 나 혼자 하지 않아도 되는 앱',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, color: c.ink2)),
                  const SizedBox(height: 28),
                  SikpanCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Field(
                          label: '이메일',
                          child: TextField(
                            controller: _email,
                            keyboardType: TextInputType.emailAddress,
                            autofillHints: const [AutofillHints.email],
                            decoration:
                                const InputDecoration(hintText: 'you@example.com'),
                          ),
                        ),
                        const SizedBox(height: 12),
                        _Field(
                          label: '닉네임',
                          child: TextField(
                            controller: _nickname,
                            decoration: const InputDecoration(
                                hintText: '처음 로그인할 때만 쓰입니다'),
                          ),
                        ),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: _busy ? null : _requestCode,
                          child: Text(_codeSent ? '코드 다시 받기' : '인증 코드 받기'),
                        ),
                        if (_codeSent) ...[
                          const SizedBox(height: 16),
                          _Field(
                            label: '인증 코드',
                            child: TextField(
                              controller: _code,
                              keyboardType: TextInputType.number,
                              autofillHints: const [AutofillHints.oneTimeCode],
                              decoration:
                                  const InputDecoration(hintText: '6자리 코드'),
                            ),
                          ),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: _busy ? null : _verify,
                            child: const Text('로그인'),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('비밀번호가 없습니다. 메일로 온 코드로 로그인합니다.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: c.ink3)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 6),
          child: Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: context.c.ink2)),
        ),
        child,
      ],
    );
  }
}
