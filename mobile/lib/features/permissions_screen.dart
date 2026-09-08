import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../app_state.dart';
import '../theme/tokens.dart';
import '../ui/labels.dart';
import '../ui/widgets.dart';

/// 이미 맺은 연결의 권한을 멘티가 다시 만지는 화면.
///
/// 예전 화면은 똑같이 생긴 스위치 일곱 개가 한 카드에 늘어서 있고, 설명이
/// "조회만 가능합니다" · "대신 기록할 수 있습니다" 두 문장뿐이었습니다. 정작
/// 사용자가 궁금한 것은 **켜면 저 사람이 무엇을 할 수 있게 되는가**입니다.
/// 그래서 항목마다 그 한 줄을 붙였고, 위험도가 다른 항목을 한 카드에 섞지
/// 않았습니다 — 보기 → 제안 → 대신 하기 순서로 아래로 갈수록 무거워집니다.
///
/// 저장 시점도 불분명했습니다. 스위치는 만지는 즉시 반영되는 것처럼 보이지만
/// 실제로는 [저장]을 눌러야 PUT이 나갑니다. 이제 바꾼 줄에는 '변경됨'이 붙고,
/// 하단 막대가 늘 그 사실을 말하며, 저장하지 않고 나가려 하면 되묻습니다.
///
/// 마지막으로 **체중 대리 입력이 목록에 없다**는 것 자체가 정보입니다. 꺼 둔
/// 것이 아니라 서버 스코프에 그런 권한이 아예 없습니다. 빈자리로 두면 아무도
/// 알 수 없으니 잠긴 카드로 명시합니다.
class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key, required this.mentorshipId});
  final int mentorshipId;

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

// =============================================================================
// 항목 사전
// =============================================================================

/// 켰을 때 상대가 할 수 있는 일. 라벨(`scopeLabel`)이 "무엇에 대한 권한인가"라면
/// 이쪽은 "그래서 저 사람이 무엇을 하는가"입니다. 후자가 없으면 판단이 안 됩니다.
const _scopeDetail = <String, String>{
  'diet:read': '내가 먹은 끼니와 칼로리·영양소를 봅니다.',
  'diet:write': '내 이름으로 끼니를 기록하고 고칩니다.',
  'workout:read': '내가 한 운동과 소모 칼로리를 봅니다.',
  'workout:write': '내 이름으로 운동을 기록하고 고칩니다.',
  'weight:read': '내가 직접 적은 체중과 그 변화를 봅니다.',
  'photo:read': '식사 사진 원본을 엽니다. 배경까지 그대로 보입니다.',
  'goal:propose': '목표를 제안합니다. 바뀌려면 내가 수락해야 합니다.',
};

const _scopeIcon = <String, IconData>{
  'diet:read': Icons.restaurant_rounded,
  'diet:write': Icons.edit_note_rounded,
  'workout:read': Icons.directions_run_rounded,
  'workout:write': Icons.fitness_center_rounded,
  'weight:read': Icons.monitor_weight_outlined,
  'photo:read': Icons.photo_library_outlined,
  'goal:propose': Icons.flag_outlined,
};

class _ScopeGroup {
  const _ScopeGroup({
    required this.title,
    required this.hint,
    required this.icon,
    required this.scopes,
    this.risky = false,
  });

  final String title;
  final String hint;
  final IconData icon;
  final List<String> scopes;

  /// 켜져 있으면 카드 자체가 경고색을 머금습니다.
  final bool risky;
}

const _groups = <_ScopeGroup>[
  _ScopeGroup(
    title: '볼 수 있는 것',
    hint: '읽기만 합니다. 고치거나 지우지 못합니다.',
    icon: Icons.visibility_outlined,
    scopes: ['diet:read', 'workout:read', 'weight:read', 'photo:read'],
  ),
  _ScopeGroup(
    title: '제안할 수 있는 것',
    hint: '제안일 뿐입니다. 적용은 내가 수락해야 합니다.',
    icon: Icons.campaign_outlined,
    scopes: ['goal:propose'],
  ),
  _ScopeGroup(
    title: '대신 할 수 있는 것',
    hint: '내 기록에 남습니다. 누가 남겼는지는 항상 함께 표시됩니다.',
    icon: Icons.drive_file_rename_outline_rounded,
    scopes: ['diet:write', 'workout:write'],
    risky: true,
  ),
];

bool _isWrite(String scope) => scope.endsWith(':write');

// =============================================================================
// 화면
// =============================================================================

class _PermissionsScreenState extends State<PermissionsScreen>
    with DataListener<PermissionsScreen> {
  Mentorship? _m;

  /// 서버가 알고 있는 상태. 화면의 스위치(_granted)와 비교해 "안 저장된 변경"을
  /// 찾아냅니다.
  final _server = <String, bool>{};
  final _granted = <String, bool>{};

  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// [DataBus]가 부릅니다 — 다른 화면에서 연결이나 권한이 바뀌었을 때.
  @override
  Future<void> reload() => _load();

  bool get _dirty => scopeLabel.keys
      .any((s) => (_granted[s] ?? false) != (_server[s] ?? false));

  int get _changed => scopeLabel.keys
      .where((s) => (_granted[s] ?? false) != (_server[s] ?? false))
      .length;

  Future<void> _load() async {
    // 의존성은 첫 await 전에 잡아 둡니다.
    final scope = AppScope.of(context);
    try {
      final list = (await scope.api.get('/mentorships') as List)
          .map((e) => Mentorship.fromJson(e as Map<String, dynamic>))
          .toList();
      final found = list.where((m) => m.id == widget.mentorshipId).firstOrNull;
      if (!mounted) return;
      setState(() {
        // 편집 중이라면 사용자의 손을 서버 값으로 덮어쓰지 않습니다. 스위치를
        // 만지는 동안 다른 화면의 갱신이 끼어들어 되돌아가면 최악입니다.
        final editing = _dirty;
        _m = found;
        _server
          ..clear()
          ..addEntries(scopeLabel.keys
              .map((s) => MapEntry(s, found?.permissions[s] ?? false)));
        if (!editing) {
          _granted
            ..clear()
            ..addAll(_server);
        } else {
          for (final s in scopeLabel.keys) {
            _granted.putIfAbsent(s, () => _server[s] ?? false);
          }
        }
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showToast(context, e.message, tone: ToastTone.error);
    } on OfflineException {
      if (!mounted) return;
      setState(() => _loading = false);
      showToast(context, '네트워크에 연결할 수 없습니다', tone: ToastTone.error);
    }
  }

  void _set(String scope, bool value) {
    setState(() => _granted[scope] = value);
  }

  void _reset() {
    setState(() {
      _granted
        ..clear()
        ..addAll(_server);
    });
    showToast(context, '바꾸기 전으로 되돌렸습니다');
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final api = context.api;
    try {
      await api.put('/mentorships/${widget.mentorshipId}/permissions',
          body: {'permissions': _granted});
      if (!mounted) return;
      // 저장에 성공한 순간부터 이 값이 서버의 진실입니다.
      setState(() => _server
        ..clear()
        ..addAll(_granted));
      showToast(context, '권한을 저장했습니다', tone: ToastTone.success);
      // 권한이 바뀌면 멘티 목록·더보기 카드가 지금 값으로 다시 그려져야 합니다.
      context.data.bump();
      context.pop();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, tone: ToastTone.error);
    } on OfflineException {
      if (mounted) {
        showToast(context, '네트워크에 연결할 수 없어 저장하지 못했습니다',
            tone: ToastTone.error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmLeave() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('저장하지 않고 나갈까요?'),
        content: const Text('바꾼 스위치는 저장을 눌러야 반영됩니다. 지금 나가면 그대로 사라집니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('계속 편집'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('나가기'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final m = _m;

    return PopScope(
      // 저장하지 않은 변경이 있으면 뒤로 가기를 한 번 붙잡습니다. 프로그램에서
      // 부르는 pop(저장 후)은 이 관문을 지나지 않습니다.
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(m == null ? '권한' : '${m.mentorName ?? ""} 권한',
              style:
                  const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
        ),
        body: _loading && m == null
            ? const _PermissionsSkeleton()
            : m == null
                ? ScreenBody(children: [
                    EmptyState(
                      '연결이 끊겼거나, 불러오지 못했습니다.',
                      icon: Icons.link_off_rounded,
                      title: '연결을 찾을 수 없습니다',
                      action: '다시 시도',
                      onAction: _load,
                    ),
                  ])
                : _body(m),
        bottomNavigationBar: m == null ? null : _saveBar(),
      ),
    );
  }

  Widget _body(Mentorship m) {
    final c = context.c;
    final all = scopeLabel.keys.toList();
    final on = all.where((s) => _granted[s] == true).length;
    final writeOn =
        all.where((s) => _isWrite(s) && _granted[s] == true).length;

    final known = <String>{for (final g in _groups) ...g.scopes};
    final others = all.where((s) => !known.contains(s)).toList();

    return ScreenBody(
      onRefresh: _load,
      // 하단에 저장 막대가 고정되어 있으므로 탭바용 여백은 필요 없습니다.
      padding: const EdgeInsets.fromLTRB(
          Dim.screenH, Dim.s8, Dim.screenH, Dim.s24),
      children: [
        if (_dirty)
          NoticeBanner(
            '아직 저장하지 않았습니다. 저장을 눌러야 상대에게 반영됩니다.',
            icon: Icons.edit_outlined,
            action: '되돌리기',
            onAction: _reset,
          ),

        _Summary(
          mentorship: m,
          on: on,
          total: all.length,
          writeOn: writeOn,
        ),

        for (final g in _groups)
          if (g.scopes.any(scopeLabel.containsKey))
            _GroupCard(
              group: g,
              scopes: g.scopes.where(scopeLabel.containsKey).toList(),
              granted: _granted,
              server: _server,
              onChanged: _set,
            ),

        // 사전에 새 스코프가 생겨도 화면에서 사라지지 않도록 남겨 둔 자리입니다.
        if (others.isNotEmpty)
          _GroupCard(
            group: const _ScopeGroup(
              title: '그 외',
              hint: '새로 생긴 항목입니다.',
              icon: Icons.tune_rounded,
              scopes: [],
            ),
            scopes: others,
            granted: _granted,
            server: _server,
            onChanged: _set,
          ),

        const _WeightLock(),

        SikpanCard(
          title: '끄면 어떻게 되나',
          icon: Icons.history_rounded,
          padding: const EdgeInsets.fromLTRB(
              Dim.s16, Dim.s16, Dim.s16, Dim.s4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '저장하는 즉시 열람이 차단됩니다. 이미 남은 대리 기록은 지워지지 않고, '
                '누가 언제 무엇을 했는지는 변경 이력에 그대로 남습니다.',
                style: TextStyle(fontSize: 13, color: c.ink2, height: 1.5),
              ),
              const SizedBox(height: Dim.s8),
              ListRow(
                showDivider: false,
                chevron: true,
                onTap: () => context.push('/audit'),
                content: const Text('변경 이력 보기',
                    style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 저장 막대.
  ///
  /// 화면 어디를 보고 있든 "지금 저장됐는지"가 보여야 해서 스크롤 밖에 고정합니다.
  /// 바꾼 것이 없으면 버튼을 잠가 둡니다 — 눌러도 같은 값을 다시 보낼 뿐이라,
  /// 잠긴 버튼이 오히려 "이미 저장된 상태"라는 사실을 알려 줍니다.
  Widget _saveBar() {
    final c = context.c;
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.line)),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(
            Dim.screenH, Dim.s12, Dim.screenH, Dim.s12),
        child: Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Icon(
                    _dirty
                        ? Icons.error_outline_rounded
                        : Icons.check_circle_outline_rounded,
                    size: 16,
                    color: _dirty ? c.warn : c.ink3,
                  ),
                  const SizedBox(width: Dim.s6),
                  Expanded(
                    child: Text(
                      _dirty ? '바꾼 항목 $_changed개 · 저장해야 반영됩니다' : '모두 저장되어 있습니다',
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.3,
                        color: _dirty ? c.warn : c.ink3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Dim.s12),
            FilledButton(
              onPressed: (_busy || !_dirty) ? null : _save,
              child: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('저장'),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// 히어로 — 이 연결이 지금 얼마나 열려 있는가
// =============================================================================

class _Summary extends StatelessWidget {
  const _Summary({
    required this.mentorship,
    required this.on,
    required this.total,
    required this.writeOn,
  });

  final Mentorship mentorship;
  final int on;
  final int total;
  final int writeOn;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final name = (mentorship.mentorName ?? '').trim();
    final initial = name.isEmpty ? '?' : name.characters.first;
    final role = mentorship.type == 'coach' ? '코치' : '친구';

    return SikpanCard(
      hero: true,
      padding: const EdgeInsets.fromLTRB(Dim.s20, Dim.s20, Dim.s20, Dim.s20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.accentSoft,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  initial,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: c.isDark ? c.accent : c.accentDeep,
                  ),
                ),
              ),
              const SizedBox(width: Dim.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name.isEmpty ? '이름 없음' : name,
                        style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.3)),
                    const SizedBox(height: Dim.s2),
                    Text('$role · 내가 켠 항목만 볼 수 있습니다',
                        style: TextStyle(fontSize: 12.5, color: c.ink3)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Dim.s20),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              AnimatedCount(
                on.toDouble(),
                style: TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1.2,
                  height: 1.0,
                  color: c.ink,
                ),
              ),
              const SizedBox(width: Dim.s6),
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text('/ $total 항목 열림',
                    style: TextStyle(fontSize: 13.5, color: c.ink2)),
              ),
            ],
          ),
          const SizedBox(height: Dim.s12),
          Meter(
            value: on.toDouble(),
            target: total.toDouble(),
            warnOver: false,
            color: writeOn > 0 ? c.warn : c.accent,
          ),
          const SizedBox(height: Dim.s16),
          Wrap(
            spacing: Dim.s6,
            runSpacing: Dim.s6,
            children: [
              if (on == 0)
                const SikpanBadge('아무것도 열려 있지 않음')
              else if (writeOn == 0)
                const SikpanBadge('보기만 허용', tone: BadgeTone.accent)
              else
                SikpanBadge('대리 기록 $writeOn개 허용', tone: BadgeTone.warn),
              const SikpanBadge('체중 대리 입력 없음', tone: BadgeTone.accent),
            ],
          ),
          const SizedBox(height: Dim.s16),
          Divider(height: 1, color: c.lineSoft),
          const SizedBox(height: Dim.s12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline_rounded, size: 15, color: c.ink3),
              const SizedBox(width: Dim.s8),
              Expanded(
                child: Text(
                  '스위치는 만지는 즉시 저장되지 않습니다. 아래 저장을 눌러야 반영됩니다.',
                  style:
                      TextStyle(fontSize: 12.5, height: 1.4, color: c.ink3),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// 항목 묶음
// =============================================================================

class _GroupCard extends StatelessWidget {
  const _GroupCard({
    required this.group,
    required this.scopes,
    required this.granted,
    required this.server,
    required this.onChanged,
  });

  final _ScopeGroup group;
  final List<String> scopes;
  final Map<String, bool> granted;
  final Map<String, bool> server;
  final void Function(String scope, bool value) onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final anyOn = scopes.any((s) => granted[s] == true);

    return SikpanCard(
      title: group.title,
      subtitle: group.hint,
      icon: group.icon,
      tone: group.risky && anyOn ? c.warn : null,
      padding:
          const EdgeInsets.fromLTRB(Dim.s16, Dim.s16, Dim.s16, Dim.s4),
      child: Column(
        children: [
          for (var i = 0; i < scopes.length; i++)
            _ScopeTile(
              scope: scopes[i],
              value: granted[scopes[i]] ?? false,
              changed:
                  (granted[scopes[i]] ?? false) != (server[scopes[i]] ?? false),
              last: i == scopes.length - 1,
              onChanged: (v) => onChanged(scopes[i], v),
            ),
        ],
      ),
    );
  }
}

/// 항목 한 줄.
///
/// 줄 전체가 누를 수 있는 영역입니다. 스위치라는 작은 과녁만 노리게 하면 손이
/// 자주 빗나갑니다. 스위치 자체는 [IgnorePointer]로 감싸 두 번 토글되는 일을
/// 막고, 대신 [Pressable]이 눌린 티와 햅틱을 냅니다.
class _ScopeTile extends StatelessWidget {
  const _ScopeTile({
    required this.scope,
    required this.value,
    required this.changed,
    required this.onChanged,
    required this.last,
  });

  final String scope;
  final bool value;
  final bool changed;
  final ValueChanged<bool> onChanged;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final write = _isWrite(scope);
    final tint = write ? c.warn : c.accent;

    return Column(
      children: [
        Pressable(
          scale: 0.985,
          onTap: () => onChanged(!value),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Dim.s12),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: Motion.fast,
                  curve: Motion.curve,
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: value
                        ? tint.withValues(alpha: c.isDark ? 0.20 : 0.12)
                        : c.surface2,
                    borderRadius: BorderRadius.circular(Dim.radiusSm),
                  ),
                  child: Icon(
                    _scopeIcon[scope] ?? Icons.toggle_on_outlined,
                    size: 17,
                    color: value ? tint : c.ink3,
                  ),
                ),
                const SizedBox(width: Dim.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              scopeLabel[scope] ?? scope,
                              style: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w600),
                            ),
                          ),
                          if (changed) ...[
                            const SizedBox(width: Dim.s6),
                            const SikpanBadge('변경됨', tone: BadgeTone.warn),
                          ],
                        ],
                      ),
                      const SizedBox(height: Dim.s2),
                      Text(
                        _scopeDetail[scope] ??
                            (write ? '내 대신 기록합니다.' : '조회만 합니다.'),
                        style: TextStyle(
                            fontSize: 12.5, height: 1.35, color: c.ink3),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Dim.s8),
                IgnorePointer(
                  child: Switch.adaptive(value: value, onChanged: onChanged),
                ),
              ],
            ),
          ),
        ),
        if (!last) Divider(height: 1, color: c.lineSoft),
      ],
    );
  }
}

// =============================================================================
// 만들지 않은 권한
// =============================================================================

/// 체중 대리 입력.
///
/// 이 앱의 안전장치라서 카드 하나를 통째로 씁니다. "꺼져 있는 항목"으로 보이면
/// 언제든 켤 수 있는 것으로 오해받으므로, 스위치 자리에 자물쇠를 둡니다.
class _WeightLock extends StatelessWidget {
  const _WeightLock();

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SikpanCard(
      title: '체중 대리 입력',
      subtitle: '목록에 없습니다',
      icon: Icons.lock_outline_rounded,
      tone: c.accent,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.accent.withValues(alpha: c.isDark ? 0.20 : 0.12),
              borderRadius: BorderRadius.circular(Dim.radiusSm),
            ),
            child: Icon(Icons.lock_rounded, size: 17, color: c.accent),
          ),
          const SizedBox(width: Dim.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '누구도 내 체중을 대신 적을 수 없습니다.',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: c.ink),
                ),
                const SizedBox(height: Dim.s4),
                Text(
                  '꺼 둔 것이 아니라, 앱에도 서버에도 그런 권한 자체를 만들지 않았습니다. '
                  '체중은 코치도 가족도 아닌 나만 적습니다.',
                  style:
                      TextStyle(fontSize: 12.5, height: 1.45, color: c.ink2),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// 로딩
// =============================================================================

/// 스피너 대신 올 자리를 미리 그립니다. 스위치가 몇 줄 오는지까지 보이면
/// 도착하는 순간 화면이 튀지 않습니다.
class _PermissionsSkeleton extends StatelessWidget {
  const _PermissionsSkeleton();

  @override
  Widget build(BuildContext context) {
    return const ScreenBody(
      animate: false,
      padding:
          EdgeInsets.fromLTRB(Dim.screenH, Dim.s8, Dim.screenH, Dim.s24),
      children: [
        SikpanCard(
          hero: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Skeleton(width: 44, height: 44, radius: 99),
                  SizedBox(width: Dim.s12),
                  Skeleton(width: 120, height: 16),
                ],
              ),
              SizedBox(height: Dim.s20),
              Skeleton(width: 90, height: 30),
              SizedBox(height: Dim.s16),
              Skeleton(height: 8, radius: 99),
            ],
          ),
        ),
        SikpanCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Skeleton(width: 100),
              SizedBox(height: Dim.s20),
              Skeleton(height: 34, radius: Dim.radiusSm),
              SizedBox(height: Dim.s16),
              Skeleton(height: 34, radius: Dim.radiusSm),
              SizedBox(height: Dim.s16),
              Skeleton(height: 34, radius: Dim.radiusSm),
            ],
          ),
        ),
        SikpanCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Skeleton(width: 100),
              SizedBox(height: Dim.s20),
              Skeleton(height: 34, radius: Dim.radiusSm),
            ],
          ),
        ),
      ],
    );
  }
}
