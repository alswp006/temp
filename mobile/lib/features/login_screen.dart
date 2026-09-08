import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../app_state.dart';
import '../theme/tokens.dart';
import '../ui/widgets.dart';

/// 로그인.
///
/// 앱을 설치한 사람이 가장 먼저 보는 화면인데, 이전에는 여기가 가장 밋밋했습니다.
/// 제목 한 줄 아래에 회색 입력칸 두 개가 얹힌, 어느 앱에나 있는 폼이었습니다.
/// 다시 짜면서 네 가지를 고쳤습니다.
///
/// * **브랜드가 먼저 보입니다.** 식판 마크 + 이름 + 한 줄 가치 제안이 화면 위쪽을
///   차지합니다. 로그인은 그 아래 카드 한 장으로 내려갔습니다 — 첫 화면이
///   "무엇을 하는 앱인지"를 말하지 않으면 폼만 남습니다.
/// * **두 단계가 두 단계로 보입니다.** 이전에는 코드 입력칸이 폼 아래에 툭
///   덧붙어서, 지금이 어느 단계인지 알 수 없었습니다. 이제 이메일 단계와 코드
///   단계가 서로 교체되고([AnimatedSwitcher]) 위에 진행 표시가 붙습니다.
/// * **개발 모드 코드가 화면에 남습니다.** 자동으로 채워 주는 동작은 그대로지만,
///   스낵바로만 알리면 2.6초 뒤 사라져서 "왜 이미 채워져 있지"만 남습니다.
/// * **오류가 입력칸 아래에 붙습니다.** 잘못된 코드를 스낵바로 알리면 사용자는
///   메시지와 입력칸을 눈으로 이어 붙여야 합니다.
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

  /// 개발 서버가 돌려준 코드. 화면에 남겨 두려고 상태로 들고 있습니다.
  String? _devCode;

  /// 서버가 메일을 실제로 보냈는지. 실패해도 요청 자체는 성공으로 오기 때문에,
  /// 이 값이 false면 오지 않을 메일을 기다리는 일이 생깁니다.
  bool _mailSent = true;

  /// 지금 단계의 입력칸 아래에 붙는 오류.
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _nickname.dispose();
    _code.dispose();
    super.dispose();
  }

  /// 오류는 스낵바가 아니라 입력칸 아래에 답니다. 화면을 못 보고 있을 수도
  /// 있으니 햅틱은 그대로 남깁니다.
  void _fail(String message) {
    HapticFeedback.heavyImpact();
    setState(() => _error = message);
  }

  void _clearError(String _) {
    if (_error != null) setState(() => _error = null);
  }

  void _backToEmail() {
    setState(() {
      _codeSent = false;
      _error = null;
    });
  }

  Future<void> _requestCode() async {
    final email = _email.text.trim();
    if (email.isEmpty) {
      _fail('이메일을 입력해 주세요');
      return;
    }
    if (!email.contains('@')) {
      _fail('이메일 주소를 다시 확인해 주세요');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
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
      final devCode = res['dev_code'] as String?;
      setState(() {
        _codeSent = true;
        _devCode = devCode;
        _mailSent = res['sent'] == true;
      });
      if (devCode != null) {
        // 개발 서버는 코드를 그대로 돌려줍니다. 손으로 옮겨 적는 수고를 없앱니다.
        // 채워 넣었다는 사실은 코드 단계의 배너가 계속 알려 줍니다.
        _code.text = devCode;
      } else {
        showToast(context, '메일로 코드를 보냈습니다', tone: ToastTone.success);
      }
    } on ApiException catch (e) {
      if (mounted) _fail(e.message);
    } on OfflineException catch (e) {
      if (mounted) _fail(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    final code = _code.text.trim();
    if (code.isEmpty) {
      _fail('메일로 받은 코드를 입력해 주세요');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = context.api;
    final session = context.session;
    try {
      final res = await api.post(
        '/auth/verify',
        body: {'email': _email.text.trim(), 'code': code},
        auth: false,
      ) as Map<String, dynamic>;
      final user = User.fromJson(res['user'] as Map<String, dynamic>);
      await session.signIn(res['access_token'] as String, user);
      if (!mounted) return;
      context.go('/today');
    } on ApiException catch (e) {
      if (mounted) _fail(e.message);
    } on OfflineException catch (e) {
      if (mounted) _fail(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;

    return Scaffold(
      body: Stack(
        children: [
          const _Backdrop(),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                    Dim.s24, Dim.s32, Dim.s24, Dim.s32),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: AutofillGroup(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const _Brand(),
                        const SizedBox(height: Dim.s32),
                        _Steps(step: _codeSent ? 1 : 0),
                        const SizedBox(height: Dim.s12),

                        // 화면의 주인공. 단계가 바뀌면 안쪽만 갈아 끼우고,
                        // 카드 높이는 [AnimatedSize]가 따라갑니다 — 안 그러면
                        // 코드 칸이 나타나는 순간 카드가 툭 늘어납니다.
                        SikpanCard(
                          hero: true,
                          padding: const EdgeInsets.all(Dim.s20),
                          child: AnimatedSize(
                            duration: Motion.base,
                            curve: Motion.curve,
                            alignment: Alignment.topCenter,
                            child: AnimatedSwitcher(
                              duration: Motion.base,
                              switchInCurve: Motion.curve,
                              switchOutCurve: Motion.curve,
                              layoutBuilder: (current, previous) => Stack(
                                alignment: Alignment.topCenter,
                                children: [
                                  ...previous,
                                  if (current != null) current,
                                ],
                              ),
                              transitionBuilder: (child, anim) =>
                                  FadeTransition(
                                opacity: anim,
                                child: SlideTransition(
                                  position: Tween<Offset>(
                                    begin: const Offset(0, 0.06),
                                    end: Offset.zero,
                                  ).animate(anim),
                                  child: child,
                                ),
                              ),
                              child:
                                  _codeSent ? _codeStep() : _emailStep(),
                            ),
                          ),
                        ),

                        const SizedBox(height: Dim.s16),
                        Text(
                          '비밀번호가 없습니다. 메일로 온 코드로 로그인합니다.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 12, height: 1.5, color: c.ink3),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 1단계 — 이메일
  // ---------------------------------------------------------------------------

  Widget _emailStep() {
    return Column(
      key: const ValueKey('email'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Field(
          label: '이메일',
          error: _error,
          child: TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            textInputAction: TextInputAction.next,
            autocorrect: false,
            onChanged: _clearError,
            decoration: const InputDecoration(hintText: 'you@example.com'),
          ),
        ),
        const SizedBox(height: Dim.s12),
        _Field(
          label: '닉네임',
          child: TextField(
            controller: _nickname,
            textInputAction: TextInputAction.done,
            onSubmitted: _busy ? null : (_) => _requestCode(),
            decoration:
                const InputDecoration(hintText: '처음 로그인할 때만 쓰입니다'),
          ),
        ),
        const SizedBox(height: Dim.s20),
        _SubmitButton(
          label: _codeSent ? '코드 다시 받기' : '인증 코드 받기',
          icon: Icons.mail_outline_rounded,
          busy: _busy,
          onPressed: _requestCode,
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 2단계 — 코드
  // ---------------------------------------------------------------------------

  Widget _codeStep() {
    final c = context.c;
    final devCode = _devCode;

    return Column(
      key: const ValueKey('code'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SentTo(
          email: _email.text.trim(),
          onChange: _busy ? null : _backToEmail,
        ),
        const SizedBox(height: Dim.s12),

        if (devCode != null) ...[
          NoticeBanner(
            '개발 모드입니다. 코드 $devCode를 아래 칸에 미리 채워 두었습니다.',
            tone: BadgeTone.accent,
            icon: Icons.bolt_rounded,
          ),
          const SizedBox(height: Dim.s12),
        ] else if (!_mailSent) ...[
          const NoticeBanner(
            '메일이 나가지 않았을 수 있습니다. 받은 편지함에 없으면 코드를 다시 받아 주세요.',
            icon: Icons.mark_email_unread_outlined,
          ),
          const SizedBox(height: Dim.s12),
        ],

        _Field(
          label: '인증 코드',
          error: _error,
          child: TextField(
            controller: _code,
            // 이미 채워져 있으면 키보드를 올릴 이유가 없습니다.
            autofocus: _code.text.isEmpty,
            keyboardType: TextInputType.number,
            autofillHints: const [AutofillHints.oneTimeCode],
            textInputAction: TextInputAction.done,
            textAlign: TextAlign.center,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              letterSpacing: 10,
              color: c.ink,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            onChanged: _clearError,
            onSubmitted: _busy ? null : (_) => _verify(),
            decoration: InputDecoration(
              hintText: '000000',
              hintStyle: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w700,
                letterSpacing: 10,
                color: c.ink3.withValues(alpha: 0.45),
              ),
            ),
          ),
        ),
        const SizedBox(height: Dim.s20),
        _SubmitButton(
          label: '로그인',
          icon: Icons.login_rounded,
          busy: _busy,
          onPressed: _verify,
        ),
        const SizedBox(height: Dim.s4),
        TextButton(
          onPressed: _busy ? null : _requestCode,
          child: const Text('코드 다시 받기'),
        ),
      ],
    );
  }
}

// =============================================================================
// 브랜드
// =============================================================================

/// 마크 + 이름 + 한 줄.
///
/// 로그인 폼은 어느 앱이나 똑같이 생겼습니다. 그래서 이 화면이 어떤 앱인지는
/// 폼 위쪽에서 결정됩니다.
class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Motion.slow,
      curve: Motion.curve,
      builder: (_, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset(0, (1 - v) * 12),
          child: child,
        ),
      ),
      child: Column(
        children: [
          const _TrayMark(),
          const SizedBox(height: Dim.s20),
          Text(
            '식판',
            style: TextStyle(
              fontSize: 42,
              fontWeight: FontWeight.w800,
              letterSpacing: -2,
              height: 1.0,
              color: c.accent,
            ),
          ),
          const SizedBox(height: Dim.s8),
          Text(
            '기록을 나 혼자 하지 않아도 되는 앱',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              height: 1.4,
              fontWeight: FontWeight.w500,
              color: c.ink2,
            ),
          ),
        ],
      ),
    );
  }
}

/// 앱 마크. 이름 그대로 칸이 나뉜 식판입니다.
///
/// 이미지 파일 대신 그립니다 — 다크·라이트에서 같은 초록을 쓰려면 색을 토큰에서
/// 받아야 하고, 어느 화면 크기에서도 선 굵기가 일정해야 하기 때문입니다.
class _TrayMark extends StatelessWidget {
  const _TrayMark();

  static const size = 88.0;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [c.accent, c.accentDeep],
        ),
        borderRadius: BorderRadius.circular(size * 0.30),
        boxShadow: [
          BoxShadow(
            color: c.accent.withValues(alpha: c.isDark ? 0.22 : 0.32),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Center(
        child: CustomPaint(
          size: Size(size * 0.52, size * 0.40),
          painter: const _TrayPainter(Colors.white),
        ),
      ),
    );
  }
}

class _TrayPainter extends CustomPainter {
  const _TrayPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.height * 0.09;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          stroke / 2,
          stroke / 2,
          size.width - stroke,
          size.height - stroke,
        ),
        Radius.circular(size.height * 0.24),
      ),
      paint,
    );

    // 오른쪽을 위아래로 나눈 반찬 칸, 왼쪽은 밥·국 칸.
    final divider = size.width * 0.56;
    canvas.drawLine(
        Offset(divider, stroke), Offset(divider, size.height - stroke), paint);
    canvas.drawLine(Offset(divider, size.height / 2),
        Offset(size.width - stroke, size.height / 2), paint);
    canvas.drawCircle(
        Offset(divider / 2, size.height / 2), size.height * 0.16, paint);
  }

  @override
  bool shouldRepaint(_TrayPainter old) => old.color != color;
}

/// 배경의 옅은 초록 후광. 첫 화면만 갖는 사치입니다.
class _Backdrop extends StatelessWidget {
  const _Backdrop();

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Positioned.fill(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0, -0.85),
            radius: 1.1,
            colors: [
              c.accent.withValues(alpha: c.isDark ? 0.16 : 0.10),
              c.bg.withValues(alpha: 0),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// 폼 조각
// =============================================================================

/// 두 단계 진행 표시.
///
/// 코드 칸이 갑자기 나타나는 대신 "지금 2단계"라고 말해 주면, 화면이 바뀐 이유를
/// 사용자가 추측하지 않아도 됩니다.
class _Steps extends StatelessWidget {
  const _Steps({required this.step});

  /// 0 = 이메일, 1 = 인증 코드.
  final int step;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: _seg(context, 0, '1  이메일')),
        const SizedBox(width: Dim.s8),
        Expanded(child: _seg(context, 1, '2  인증 코드')),
      ],
    );
  }

  Widget _seg(BuildContext context, int index, String label) {
    final c = context.c;
    final reached = index <= step;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedContainer(
          duration: Motion.base,
          curve: Motion.curve,
          height: 3,
          decoration: BoxDecoration(
            color: reached ? c.accent : c.surface2,
            borderRadius: BorderRadius.circular(99),
          ),
        ),
        const SizedBox(height: Dim.s6),
        Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.1,
            color: index == step ? c.accent : c.ink3,
          ),
        ),
      ],
    );
  }
}

/// 라벨 + 입력칸 + (있다면) 오류 한 줄.
///
/// 오류를 스낵바로 띄우면 어느 칸이 잘못됐는지 사용자가 이어 붙여야 합니다.
/// 칸 바로 아래에 붙으면 읽을 필요조차 줄어듭니다.
class _Field extends StatelessWidget {
  const _Field({required this.label, required this.child, this.error});

  final String label;
  final Widget child;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: Dim.s2, bottom: Dim.s6),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: c.ink2,
            ),
          ),
        ),
        child,
        AnimatedSize(
          duration: Motion.fast,
          curve: Motion.curve,
          alignment: Alignment.topLeft,
          child: error == null
              ? const SizedBox(width: double.infinity, height: 0)
              : Padding(
                  padding: const EdgeInsets.only(top: Dim.s8, left: Dim.s2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.error_outline_rounded,
                          size: 15, color: c.danger),
                      const SizedBox(width: Dim.s6),
                      Expanded(
                        child: Text(
                          error!,
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.35,
                            color: c.danger,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

/// 코드를 어디로 보냈는지, 그리고 그게 틀렸을 때 돌아가는 길.
class _SentTo extends StatelessWidget {
  const _SentTo({required this.email, required this.onChange});

  final String email;
  final VoidCallback? onChange;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.fromLTRB(Dim.s12, Dim.s12, Dim.s8, Dim.s12),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(Dim.radiusSm),
      ),
      child: Row(
        children: [
          Icon(Icons.mark_email_read_outlined, size: 18, color: c.accent),
          const SizedBox(width: Dim.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('코드를 보낸 곳',
                    style: TextStyle(fontSize: 11.5, color: c.ink3)),
                const SizedBox(height: Dim.s2),
                Text(
                  email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: c.ink,
                  ),
                ),
              ],
            ),
          ),
          Pressable(
            onTap: onChange,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: Dim.s8, vertical: Dim.s4),
              child: Text(
                '변경',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: onChange == null ? c.ink3 : c.accent,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 채운 버튼 하나. 처리 중에는 글자를 그대로 두고 앞에 스피너만 붙습니다 —
/// 글자가 사라지면 버튼 폭이 흔들리고, 무엇을 누른 건지도 잊게 됩니다.
class _SubmitButton extends StatelessWidget {
  const _SubmitButton({
    required this.label,
    required this.busy,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final bool busy;
  final VoidCallback onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return FilledButton(
      onPressed: busy ? null : onPressed,
      child: AnimatedSwitcher(
        duration: Motion.fast,
        child: Row(
          key: ValueKey(busy),
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              SizedBox(
                width: 15,
                height: 15,
                child:
                    CircularProgressIndicator(strokeWidth: 2, color: c.ink3),
              )
            else if (icon != null)
              Icon(icon, size: 17)
            else
              const SizedBox.shrink(),
            if (busy || icon != null) const SizedBox(width: Dim.s8),
            Text(label),
          ],
        ),
      ),
    );
  }
}
