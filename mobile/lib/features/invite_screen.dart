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
///
/// 로그아웃 상태에서도 열리는 유일한 화면이라 이 앱의 첫인상이기도 합니다.
/// 그래서 세 가지를 화면 구조로 못 박았습니다.
///
/// * **누가 무엇을 요구하는지**가 가장 큽니다 — 히어로 한 장.
/// * **권한은 위험도 순으로** 묶습니다. 서버가 주는 순서(Scope 열거형)는 읽기와
///   쓰기가 뒤섞여 있어, 위에서부터 훑으면 가장 무거운 "대리 기록"이 목록
///   중간에 파묻힙니다. 무거운 것을 맨 위로 올리고 각 항목이 실제로 무엇을
///   허용하는지 한 줄로 붙였습니다. `식단 대리 기록`이라는 이름만으로는 그게
///   내 이름으로 기록이 남는다는 뜻인지 알 수 없습니다.
/// * **수락과 거절의 무게가 다릅니다.** 수락만 채운 버튼이고, 거절은 글자
///   버튼입니다. 둘을 같은 무게로 놓으면 고르는 데 시간이 더 듭니다.
class InviteScreen extends StatefulWidget {
  const InviteScreen({super.key, required this.code});
  final String code;

  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<InviteScreen>
    with DataListener<InviteScreen> {
  InvitePreview? _preview;
  final _granted = <String, bool>{};
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// [DataBus]가 부릅니다.
  @override
  Future<void> reload() => _load();

  Future<void> _load() async {
    final api = context.api;
    try {
      final json =
          await api.get('/mentorships/invite/${widget.code}', auth: false);
      if (!mounted) return;
      final preview = InvitePreview.fromJson(json as Map<String, dynamic>);
      setState(() {
        _preview = preview;
        for (final s in preview.scopes) {
          // 이미 만진 항목은 건드리지 않습니다. 다시 불러왔다는 이유로 사용자가
          // 끈 스위치가 도로 켜지면, 동의 화면으로서는 치명적입니다.
          _granted.putIfAbsent(s.scope, () => s.recommended);
        }
        _error = null;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
      showToast(context, e.message, tone: ToastTone.error);
    } on OfflineException {
      if (!mounted) return;
      setState(() {
        _error = '네트워크에 연결할 수 없습니다.';
        _loading = false;
      });
    }
  }

  Future<void> _accept() async {
    final scope = AppScope.of(context);
    if (!scope.session.isLoggedIn) {
      showToast(context, '연결하려면 먼저 로그인해 주세요');
      context.go('/login');
      return;
    }
    setState(() => _busy = true);
    try {
      await scope.api.post('/mentorships/accept', body: {
        'invite_code': widget.code,
        'permissions': _granted,
      });
      if (!mounted) return;
      // 연결 목록·권한 화면이 스스로 갱신되도록 알립니다.
      scope.data.bump();
      showToast(context, '연결했습니다', tone: ToastTone.success);
      context.go('/more');
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, tone: ToastTone.error);
    } on OfflineException {
      if (mounted) {
        showToast(context, '네트워크에 연결할 수 없습니다', tone: ToastTone.error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 거절은 서버에 남길 것이 없습니다. 초대는 그대로 두고 화면만 닫습니다 —
  /// 아무것도 허용하지 않았다는 사실 자체가 거절이기 때문입니다.
  void _decline() {
    showToast(context, '연결하지 않았습니다');
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(context.session.isLoggedIn ? '/today' : '/login');
    }
  }

  /// 전부 켜져 있으면 한 번에 끄고, 아무것도 없으면 권장값으로 되돌립니다.
  void _resetAll(List<InviteScope> scopes, {required bool toRecommended}) {
    setState(() {
      for (final s in scopes) {
        _granted[s.scope] = toRecommended && s.recommended;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final preview = _preview;
    final loggedIn = AppScope.of(context, listen: true).session.isLoggedIn;

    final title = preview?.type == 'coach' ? '코치 연결 요청' : '연결 요청';

    if (_loading && preview == null) {
      return Scaffold(
        appBar: _bar(title),
        body: const _InviteSkeleton(),
      );
    }

    if (preview == null) {
      return Scaffold(
        appBar: _bar(title),
        body: ScreenBody(
          children: [
            EmptyState(
              _error ?? '링크가 만료되었거나 이미 사용된 코드일 수 있습니다.',
              icon: Icons.link_off_rounded,
              title: '초대를 열 수 없습니다',
              action: '다시 시도',
              onAction: () {
                setState(() => _loading = true);
                _load();
              },
            ),
          ],
        ),
      );
    }

    final scopes = preview.scopes;
    final granted = scopes.where((s) => _granted[s.scope] == true).toList();
    final writeOn = granted.where((s) => s.isWrite).length;
    final allOff = granted.isEmpty;

    // 위험도가 높은 묶음부터. 열거형 선언 순서가 곧 화면 순서입니다.
    final groups = <_Risk, List<InviteScope>>{};
    for (final s in scopes) {
      groups.putIfAbsent(_riskOf(s), () => <InviteScope>[]).add(s);
    }

    return Scaffold(
      appBar: _bar(title),
      body: ScreenBody(
        onRefresh: _load,
        padding: const EdgeInsets.fromLTRB(
            Dim.screenH, Dim.s8, Dim.screenH, Dim.s24),
        children: [
          if (!loggedIn)
            NoticeBanner(
              '로그인하지 않아도 무엇을 요구받는지 먼저 볼 수 있습니다. 연결은 로그인한 뒤에 끝납니다.',
              tone: BadgeTone.accent,
              icon: Icons.lock_open_rounded,
              action: '로그인',
              onAction: () => context.go('/login'),
            ),

          _Hero(
            preview: preview,
            grantedCount: granted.length,
            writeCount: writeOn,
            total: scopes.length,
          ),

          if (scopes.isNotEmpty)
            SectionHeader(
              '요구하는 권한',
              action: allOff ? '권장값으로' : '모두 끄기',
              onAction: () => _resetAll(scopes, toRecommended: allOff),
            ),

          for (final risk in _Risk.values)
            if (groups[risk] != null)
              SikpanCard(
                title: risk.title,
                subtitle: risk.subtitle,
                icon: risk.icon,
                tone: risk == _Risk.high ? c.warn : null,
                trailing: SikpanBadge(risk.badge, tone: risk.badgeTone),
                child: Column(
                  children: [
                    for (var i = 0; i < groups[risk]!.length; i++)
                      _ScopeRow(
                        scope: groups[risk]![i],
                        value: _granted[groups[risk]![i].scope] ?? false,
                        last: i == groups[risk]!.length - 1,
                        onChanged: (v) => setState(
                            () => _granted[groups[risk]![i].scope] = v),
                      ),
                  ],
                ),
              ),

          if (scopes.isEmpty)
            const SikpanCard(
              child: EmptyState(
                '이 초대는 아무 권한도 요구하지 않습니다.',
                icon: Icons.shield_outlined,
                title: '요구하는 권한 없음',
              ),
            ),

          if (preview.notice.isNotEmpty)
            NoticeBanner(
              preview.notice,
              tone: BadgeTone.accent,
              icon: Icons.verified_user_outlined,
            ),

          Text(
            '연결한 뒤에도 더보기 > 연결에서 항목을 끄거나 연결을 해제할 수 있습니다. '
            '끄는 즉시 열람이 차단됩니다.',
            style: TextStyle(fontSize: 12, color: c.ink3, height: 1.5),
          ),
        ],
      ),
      bottomNavigationBar: _Actions(
        busy: _busy,
        loggedIn: loggedIn,
        grantedCount: granted.length,
        onAccept: _accept,
        onDecline: _decline,
      ),
    );
  }

  PreferredSizeWidget _bar(String title) => AppBar(
        title: Text(title,
            style:
                const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
      );
}

// =============================================================================
// 히어로 — 누가, 무엇을
// =============================================================================

/// 요청의 주인공.
///
/// 예전에는 이름 한 줄과 안내 한 줄이 다른 카드들과 같은 무게로 놓여 있어서,
/// "누가 요청했는지"가 권한 목록에 묻혔습니다. 얼굴 자리(머리글자)와 큰 문장을
/// 주고, 아래에 지금 내가 허용한 양을 막대로 붙였습니다 — 스위치를 만질 때마다
/// 막대가 움직이므로 "얼마나 열어 주는 중인지"가 손 안에서 보입니다.
class _Hero extends StatelessWidget {
  const _Hero({
    required this.preview,
    required this.grantedCount,
    required this.writeCount,
    required this.total,
  });

  final InvitePreview preview;
  final int grantedCount;
  final int writeCount;
  final int total;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final name = preview.mentorName;
    final isCoach = preview.type == 'coach';
    final open = writeCount > 0;

    return SikpanCard(
      hero: true,
      padding: const EdgeInsets.fromLTRB(Dim.s20, Dim.s24, Dim.s20, Dim.s20),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.accentSoft,
              shape: BoxShape.circle,
            ),
            child: name == null || name.isEmpty
                ? Icon(Icons.person_rounded, size: 30, color: c.accent)
                : Text(
                    String.fromCharCode(name.runes.first),
                    style: TextStyle(
                      fontSize: 27,
                      fontWeight: FontWeight.w700,
                      color: c.accent,
                    ),
                  ),
          ),
          const SizedBox(height: Dim.s12),
          SikpanBadge(isCoach ? '코치' : '동료',
              tone: isCoach ? BadgeTone.accent : BadgeTone.neutral),
          const SizedBox(height: Dim.s12),
          Text(
            '${name ?? "누군가"}님이',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.ink2),
          ),
          const SizedBox(height: Dim.s2),
          const Text(
            '연결을 요청했습니다',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.7,
                height: 1.2),
          ),
          const SizedBox(height: Dim.s12),
          Text(
            '허용한 항목만 공유됩니다. 권장 항목만 미리 켜 두었고, 언제든 바꿀 수 있습니다.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, height: 1.5, color: c.ink2),
          ),
          const SizedBox(height: Dim.s20),
          Divider(height: 1, color: c.lineSoft),
          const SizedBox(height: Dim.s20),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Text('지금 허용한 항목',
                    style: TextStyle(fontSize: 12.5, color: c.ink3)),
              ),
              AnimatedCount(
                grantedCount.toDouble(),
                duration: Motion.base,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                  height: 1.0,
                  color: open ? c.warn : c.ink,
                ),
              ),
              Text(' / $total개',
                  style: TextStyle(fontSize: 12.5, color: c.ink3)),
            ],
          ),
          const SizedBox(height: Dim.s8),
          Meter(
            value: grantedCount.toDouble(),
            target: total.toDouble(),
            warnOver: false,
            color: open ? c.warn : c.accent,
          ),
          if (open) ...[
            const SizedBox(height: Dim.s12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.edit_note_rounded, size: 15, color: c.warn),
                const SizedBox(width: Dim.s6),
                Expanded(
                  child: Text(
                    '대리 기록 $writeCount개 포함 — 내 이름으로 기록이 남습니다.',
                    style: TextStyle(
                        fontSize: 12, height: 1.4, color: c.warn),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// =============================================================================
// 권한 — 위험도 순
// =============================================================================

/// 위험도 묶음. 선언 순서가 곧 화면에 놓이는 순서입니다 (높은 것이 위).
enum _Risk {
  high,
  medium,
  low;

  String get title => switch (this) {
        _Risk.high => '대신 기록하기',
        _Risk.medium => '사진 원본 보기',
        _Risk.low => '조회하고 제안하기',
      };

  String get subtitle => switch (this) {
        _Risk.high => '내 이름으로 기록이 남습니다',
        _Risk.medium => '내가 찍은 사진을 그대로 봅니다',
        _Risk.low => '보기만 합니다. 내 기록은 바뀌지 않습니다',
      };

  IconData get icon => switch (this) {
        _Risk.high => Icons.edit_note_rounded,
        _Risk.medium => Icons.photo_camera_back_outlined,
        _Risk.low => Icons.visibility_outlined,
      };

  String get badge => switch (this) {
        _Risk.high => '민감도 높음',
        _Risk.medium => '민감도 중간',
        _Risk.low => '민감도 낮음',
      };

  BadgeTone get badgeTone =>
      this == _Risk.high ? BadgeTone.warn : BadgeTone.neutral;
}

/// 쓰기가 가장 무겁고, 사진 원본이 그다음입니다. 사진에는 식탁만 찍히지
/// 않습니다 — 얼굴·명찰·장소가 함께 남습니다.
_Risk _riskOf(InviteScope s) {
  if (s.isWrite) return _Risk.high;
  if (s.scope == 'photo:read') return _Risk.medium;
  return _Risk.low;
}

/// 이름 대신 "그래서 무엇을 할 수 있는지".
///
/// `식단 대리 기록`이라는 라벨은 정확하지만, 처음 보는 사람에게는 그게 내 기록에
/// 남는 일인지 알려 주지 않습니다.
const _scopeMeaning = <String, String>{
  'diet:read': '내가 먹은 끼니와 칼로리·영양소 요약을 봅니다',
  'diet:write': '내 식단을 대신 추가하거나 고칩니다',
  'workout:read': '내 운동 종목과 세트 기록을 봅니다',
  'workout:write': '내 운동을 대신 기록하거나 고칩니다',
  'weight:read': '내 체중 추세를 봅니다',
  'photo:read': '내가 올린 식사 사진 원본을 봅니다',
  'goal:propose': '목표를 제안합니다. 적용할지는 내가 정합니다',
};

class _ScopeRow extends StatelessWidget {
  const _ScopeRow({
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
    final meaning = _scopeMeaning[scope.scope] ??
        (scope.isWrite ? '대신 기록할 수 있습니다' : '조회만 가능합니다');

    return ListRow(
      showDivider: !last,
      // 줄 아무 데나 눌러도 켜집니다. 스위치는 손가락보다 작습니다.
      onTap: () => onChanged(!value),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            scopeLabel[scope.scope] ?? scope.scope,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: value ? c.ink : c.ink2,
            ),
          ),
          const SizedBox(height: Dim.s2),
          Text(
            meaning,
            style: TextStyle(fontSize: 12.5, height: 1.35, color: c.ink3),
          ),
        ],
      ),
      trailing: Switch.adaptive(value: value, onChanged: onChanged),
    );
  }
}

// =============================================================================
// 수락 / 거절
// =============================================================================

/// 항상 손 닿는 곳에 두는 결정 바.
///
/// 예전에는 수락 버튼이 목록 맨 아래에 섞여 있어, 권한을 만지다 보면 화면
/// 밖으로 밀려났습니다. 아래에 고정하고 무게를 갈라 둡니다 — 수락은 채운
/// 버튼, 거절은 글자.
class _Actions extends StatelessWidget {
  const _Actions({
    required this.busy,
    required this.loggedIn,
    required this.grantedCount,
    required this.onAccept,
    required this.onDecline,
  });

  final bool busy;
  final bool loggedIn;
  final int grantedCount;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final label = !loggedIn
        ? '로그인하고 연결'
        : grantedCount == 0
            ? '아무것도 허용하지 않고 연결'
            : '$grantedCount개 항목 허용하고 연결';

    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.line)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              Dim.screenH, Dim.s12, Dim.screenH, Dim.s8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: busy ? null : onAccept,
                  child: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.2, color: Colors.white),
                        )
                      : Text(label),
                ),
              ),
              const SizedBox(height: Dim.s4),
              TextButton(
                onPressed: busy ? null : onDecline,
                style: TextButton.styleFrom(
                  foregroundColor: c.ink3,
                  minimumSize: const Size(0, 44),
                ),
                child: const Text('연결하지 않기'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// 로딩
// =============================================================================

/// 가운데 스피너 대신, 올 자리를 미리 그립니다. 첫인상인 화면이 통째로 튀면
/// 그것만으로 인상이 깎입니다.
class _InviteSkeleton extends StatelessWidget {
  const _InviteSkeleton();

  @override
  Widget build(BuildContext context) {
    return const ScreenBody(
      animate: false,
      padding:
          EdgeInsets.fromLTRB(Dim.screenH, Dim.s8, Dim.screenH, Dim.s24),
      children: [
        SikpanCard(
          hero: true,
          padding: EdgeInsets.symmetric(
              horizontal: Dim.s20, vertical: Dim.s24),
          child: Column(
            children: [
              Skeleton(width: 64, height: 64, radius: 999),
              SizedBox(height: Dim.s16),
              Skeleton(width: 180, height: 20),
              SizedBox(height: Dim.s12),
              Skeleton(width: 240, height: 12),
              SizedBox(height: Dim.s24),
              Skeleton(height: 8, radius: 999),
            ],
          ),
        ),
        SikpanCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Skeleton(width: 110),
              SizedBox(height: Dim.s20),
              Skeleton(height: 40, radius: Dim.radiusSm),
              SizedBox(height: Dim.s12),
              Skeleton(height: 40, radius: Dim.radiusSm),
            ],
          ),
        ),
        SikpanCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Skeleton(width: 110),
              SizedBox(height: Dim.s20),
              Skeleton(height: 40, radius: Dim.radiusSm),
            ],
          ),
        ),
      ],
    );
  }
}
