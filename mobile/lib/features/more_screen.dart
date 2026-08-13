import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../app_state.dart';
import '../theme/tokens.dart';
import '../ui/labels.dart';
import '../ui/widgets.dart';

class MoreScreen extends StatefulWidget {
  const MoreScreen({super.key});

  @override
  State<MoreScreen> createState() => _MoreScreenState();
}

class _MoreScreenState extends State<MoreScreen> {
  User? _me;
  List<Canteen> _canteens = const [];
  List<Mentorship> _mentorships = const [];
  List<MenteeCard> _dashboard = const [];
  List<AppNotification> _notifications = const [];
  Target? _target;
  bool _loading = true;

  final _canteenName = TextEditingController();
  final _canteenCode = TextEditingController();
  final _inviteCode = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _canteenName.dispose();
    _canteenCode.dispose();
    _inviteCode.dispose();
    super.dispose();
  }

  Future<T?> _try<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on ApiException {
      return null;
    } on OfflineException {
      return null;
    }
  }

  Future<void> _load() async {
    final api = context.api;
    final me = await _try(() async =>
        User.fromJson(await api.get('/auth/me') as Map<String, dynamic>));
    final canteens = await _try(() async => (await api.get('/canteens') as List)
        .map((e) => Canteen.fromJson(e as Map<String, dynamic>))
        .toList());
    final mentorships = await _try(() async =>
        (await api.get('/mentorships') as List)
            .map((e) => Mentorship.fromJson(e as Map<String, dynamic>))
            .toList());
    final dashboard = await _try(() async =>
        (await api.get('/mentorships/dashboard') as List)
            .map((e) => MenteeCard.fromJson(e as Map<String, dynamic>))
            .toList());
    final notifications = await _try(() async =>
        (await api.get('/notifications', query: {'limit': 8}) as List)
            .map((e) => AppNotification.fromJson(e as Map<String, dynamic>))
            .toList());
    final target = await _try(() async {
      final json = await api.get('/targets/current');
      return json == null
          ? null
          : Target.fromJson(json as Map<String, dynamic>);
    });

    if (!mounted) return;
    if (me != null) await context.session.updateUser(me);
    if (!mounted) return;
    setState(() {
      _me = me;
      _canteens = canteens ?? const [];
      _mentorships = mentorships ?? const [];
      _dashboard = dashboard ?? const [];
      _notifications = notifications ?? const [];
      _target = target;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final me = _me;
    if (me == null) {
      return ScreenBody(children: [
        const EmptyState('불러오지 못했습니다.'),
        OutlinedButton(onPressed: _load, child: const Text('다시 시도')),
      ]);
    }

    return ScreenBody(
      onRefresh: _load,
      children: [
        if (_dashboard.isNotEmpty) _coachDashboard(),
        _mentorshipCard(me),
        _canteenCard(),
        _ProfileCard(me: me, onSaved: _load),
        _targetCard(),
        if (_notifications.isNotEmpty) _notificationCard(),
        _footer(me),
      ],
    );
  }

  // --- 코치 대시보드 -------------------------------------------------------

  Widget _coachDashboard() {
    final c = context.c;
    return SikpanCard(
      title: '멘티 ${_dashboard.length}명',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < _dashboard.length; i++)
            _MenteeRow(
              card: _dashboard[i],
              last: i == _dashboard.length - 1,
              onTap: () => context.push('/mentee/${_dashboard[i].userId}'),
            ),
          const SizedBox(height: 10),
          Text('미기록이 길어져도 자동 독촉 알림은 보내지 않습니다.',
              style: TextStyle(fontSize: 12, color: c.ink3)),
        ],
      ),
    );
  }

  // --- 멘토·멘티 -----------------------------------------------------------

  Widget _mentorshipCard(User me) {
    final c = context.c;
    final asMentee = _mentorships.where((m) => m.menteeId == me.id).toList();
    final asMentor = _mentorships.where((m) => m.mentorId == me.id).toList();

    return SikpanCard(
      title: '함께 하는 사람',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (asMentee.isNotEmpty) ...[
            Text('나를 봐주는 사람',
                style: TextStyle(fontSize: 11.5, color: c.ink3)),
            const SizedBox(height: 4),
            for (final m in asMentee)
              ListRow(
                content: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.mentorName ?? '?',
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                      m.permissions.entries
                              .where((e) => e.value)
                              .map((e) => scopeLabel[e.key] ?? e.key)
                              .join(', ')
                              .ifEmpty('허용된 항목 없음'),
                      style: TextStyle(fontSize: 12.5, color: c.ink2),
                    ),
                  ],
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: () => context.push('/permissions/${m.id}'),
                      child: const Text('권한'),
                    ),
                    IconButton(
                      onPressed: () => _endMentorship(m),
                      icon: Icon(Icons.link_off, size: 19, color: c.danger),
                      tooltip: '연결 해제',
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 10),
          ],
          if (asMentor.isNotEmpty) ...[
            Text('내가 봐주는 사람',
                style: TextStyle(fontSize: 11.5, color: c.ink3)),
            const SizedBox(height: 4),
            for (final m in asMentor)
              ListRow(
                content: Text(m.menteeName ?? '수락 대기 중',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: m.menteeName == null ? c.ink3 : c.ink)),
              ),
            const SizedBox(height: 10),
          ],
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _createInvite('peer'),
                  child: const Text('친구 초대'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _createInvite('coach'),
                  child: const Text('코치로 초대'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _inviteCode,
                  decoration: const InputDecoration(hintText: '받은 초대 코드'),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () {
                  final code = _inviteCode.text.trim();
                  if (code.isNotEmpty) context.push('/invite/$code');
                },
                child: const Text('열기'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _createInvite(String type) async {
    try {
      final res = await context.api
          .post('/mentorships/invite', body: {'type': type}) as Map<String, dynamic>;
      final url = res['invite_url'] as String? ?? '';
      final code = res['invite_code'] as String? ?? '';
      await Clipboard.setData(ClipboardData(text: url));
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(type == 'coach' ? '코치 초대' : '친구 초대'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('링크를 복사했습니다. 상대에게 보내 주세요.'),
              const SizedBox(height: 12),
              SelectableText(code,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: 2)),
              const SizedBox(height: 6),
              SelectableText(url,
                  style: TextStyle(fontSize: 12, color: context.c.ink3)),
            ],
          ),
          actions: [
            FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('확인')),
          ],
        ),
      );
      await _load();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message);
    }
  }

  Future<void> _endMentorship(Mentorship m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${m.mentorName}과의 연결을 해제할까요?'),
        content: const Text('해제하면 즉시 열람이 차단됩니다.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.c.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('해제'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.api.delete('/mentorships/${m.id}');
      await _load();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message);
    }
  }

  // --- 내 식당 -------------------------------------------------------------

  Widget _canteenCard() {
    final c = context.c;
    final selected = context.session.canteenId;

    return SikpanCard(
      title: '내 식당',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_canteens.isEmpty)
            Text('아직 식당이 없습니다.',
                style: TextStyle(fontSize: 13, color: c.ink3))
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                SikpanChip(
                  label: '선택 안 함',
                  selected: selected == null,
                  onTap: () async {
                    await context.session.selectCanteen(null);
                    if (mounted) setState(() {});
                  },
                ),
                for (final canteen in _canteens)
                  SikpanChip(
                    label: canteen.name,
                    selected: selected == canteen.id,
                    onTap: () async {
                      await context.session.selectCanteen(canteen.id);
                      if (mounted) setState(() {});
                    },
                  ),
              ],
            ),
          if (selected != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => context.push('/menu/$selected'),
              child: const Text('이번 주 식단표 보기 / 올리기'),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _canteenName,
                  decoration: const InputDecoration(hintText: '새 식당 이름'),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _createCanteen, child: const Text('만들기')),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _canteenCode,
                  decoration: const InputDecoration(hintText: '식당 초대 코드'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: _joinCanteen, child: const Text('참가')),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _createCanteen() async {
    final name = _canteenName.text.trim();
    if (name.isEmpty) return;
    final scope = AppScope.of(context);
    try {
      final json =
          await scope.api.post('/canteens', body: {'name': name});
      final canteen = Canteen.fromJson(json as Map<String, dynamic>);
      _canteenName.clear();
      await scope.session.selectCanteen(canteen.id);
      await _load();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message);
    }
  }

  Future<void> _joinCanteen() async {
    final code = _canteenCode.text.trim();
    if (code.isEmpty) return;
    final scope = AppScope.of(context);
    try {
      final json =
          await scope.api.post('/canteens/join', body: {'join_code': code});
      final canteen = Canteen.fromJson(json as Map<String, dynamic>);
      _canteenCode.clear();
      await scope.session.selectCanteen(canteen.id);
      await _load();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message);
    }
  }

  // --- 목표 ----------------------------------------------------------------

  Widget _targetCard() {
    final c = context.c;
    final t = _target;
    return SikpanCard(
      title: '이번 주 목표',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (t == null)
            Text('아직 목표가 없습니다.',
                style: TextStyle(fontSize: 13, color: c.ink3))
          else
            StatRow(children: [
              StatBlock(value: Fmt.kcal(t.targetKcal), label: 'kcal'),
              StatBlock(value: Fmt.g(t.targetProteinG), label: '단백질'),
              StatBlock(
                  value: t.estTdee != null ? Fmt.kcal(t.estTdee) : '–',
                  label: '추정 TDEE'),
            ]),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _refreshTarget,
                  child: const Text('다시 계산'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: _pinTarget,
                  child: const Text('직접 정하기'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text('공식이 뱉은 값은 초기값일 뿐입니다. 다만 기초대사량 아래로는 내려가지 않습니다.',
              style: TextStyle(fontSize: 12, height: 1.45, color: c.ink3)),
        ],
      ),
    );
  }

  Future<void> _refreshTarget() async {
    try {
      await context.api.post('/targets/refresh');
      if (!mounted) return;
      showToast(context, '목표를 다시 계산했습니다');
      await _load();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message);
    }
  }

  Future<void> _pinTarget() async {
    final controller = TextEditingController(
        text: (_target?.targetKcal ?? 2000).round().toString());
    final kcal = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('목표 kcal'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(suffixText: 'kcal'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('취소')),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, double.tryParse(controller.text)),
            child: const Text('고정'),
          ),
        ],
      ),
    );
    if (kcal == null || kcal <= 0 || !mounted) return;
    await _putTarget(kcal, confirmAggressive: false);
  }

  Future<void> _putTarget(double kcal, {required bool confirmAggressive}) async {
    try {
      await context.api.put('/targets/current', body: {
        'target_kcal': kcal,
        'pinned': true,
        if (confirmAggressive) 'confirm_aggressive': true,
      });
      if (!mounted) return;
      showToast(context, '목표를 고정했습니다');
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      // 서버의 두 안전장치: 기초대사량 하한은 거부, 주 1% 초과 감량은 재확인.
      if (e.requiresConfirmation) {
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('정말 이 목표로 할까요?'),
            content: Text(e.message),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('취소')),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('그래도 진행'),
              ),
            ],
          ),
        );
        if (ok == true && mounted) {
          await _putTarget(kcal, confirmAggressive: true);
        }
      } else {
        showToast(context, e.message);
      }
    }
  }

  // --- 알림·푸터 -----------------------------------------------------------

  Widget _notificationCard() {
    final c = context.c;
    return SikpanCard(
      title: '알림',
      child: Column(
        children: [
          for (var i = 0; i < _notifications.length; i++)
            ListRow(
              showDivider: i != _notifications.length - 1,
              content: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_notifications[i].title,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  if (_notifications[i].body != null) ...[
                    const SizedBox(height: 2),
                    Text(_notifications[i].body!,
                        style: TextStyle(fontSize: 12.5, color: c.ink2)),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _footer(User me) {
    final c = context.c;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton(
          onPressed: () => context.push('/audit'),
          child: const Text('내 기록 변경 이력 보기'),
        ),
        const SizedBox(height: 10),
        OutlinedButton(
          onPressed: () async {
            final router = GoRouter.of(context);
            await context.session.signOut();
            router.go('/login');
          },
          style: OutlinedButton.styleFrom(
              foregroundColor: c.danger,
              side: BorderSide(color: c.danger.withValues(alpha: 0.5))),
          child: const Text('로그아웃'),
        ),
        const SizedBox(height: 14),
        Text('${me.email} · 식판 v0.1',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: c.ink3)),
      ],
    );
  }
}

extension _StringX on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

class _MenteeRow extends StatelessWidget {
  const _MenteeRow({
    required this.card,
    required this.last,
    required this.onTap,
  });

  final MenteeCard card;
  final bool last;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final stale = card.staleDays >= 3;
    final bits = [
      if (card.mealsToday != null) '끼니 ${card.mealsToday}',
      if (card.workoutsToday != null) '운동 ${card.workoutsToday}',
      if (card.weightToday != null) card.weightToday! ? '체중 ✓' : '체중 –',
    ];

    return ListRow(
      onTap: onTap,
      showDivider: !last,
      leading: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          // 미기록이 길어지면 카드 색만 바뀝니다 — 알림은 보내지 않습니다.
          color: stale ? c.warn : c.accent,
          shape: BoxShape.circle,
        ),
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(card.nickname,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
              ),
              Text('주 ${Fmt.pct(card.weekCompletion)}',
                  style: TextStyle(fontSize: 12.5, color: c.ink2)),
            ],
          ),
          const SizedBox(height: 2),
          Text(bits.isEmpty ? '공유된 항목 없음' : bits.join(' · '),
              style: TextStyle(fontSize: 12.5, color: c.ink2)),
          if (stale) ...[
            const SizedBox(height: 2),
            Text('${card.staleDays}일째 기록 없음',
                style: TextStyle(fontSize: 11.5, color: c.warn)),
          ],
        ],
      ),
      trailing: Icon(Icons.chevron_right, size: 20, color: c.ink3),
    );
  }
}

/// 프로필. 키·나이는 기초대사량 하한 계산에 쓰이므로 설명을 붙여 둡니다.
class _ProfileCard extends StatefulWidget {
  const _ProfileCard({required this.me, required this.onSaved});
  final User me;
  final Future<void> Function() onSaved;

  @override
  State<_ProfileCard> createState() => _ProfileCardState();
}

class _ProfileCardState extends State<_ProfileCard> {
  late final TextEditingController _height =
      TextEditingController(text: widget.me.heightCm?.round().toString() ?? '');
  late final TextEditingController _birth =
      TextEditingController(text: widget.me.birthYear?.toString() ?? '');
  late String _goal = widget.me.goalType;
  late String _sex = widget.me.sex;
  bool _busy = false;

  @override
  void dispose() {
    _height.dispose();
    _birth.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await context.api.patch('/auth/me', body: {
        'height_cm': double.tryParse(_height.text.trim()),
        'birth_year': int.tryParse(_birth.text.trim()),
        'goal_type': _goal,
        'sex': _sex,
      });
      if (!mounted) return;
      showToast(context, '저장했습니다');
      await widget.onSaved();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SikpanCard(
      title: '프로필',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _height,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: '키', suffixText: 'cm'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _birth,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '출생연도'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _goal,
                  decoration: const InputDecoration(labelText: '목표'),
                  items: const [
                    DropdownMenuItem(value: 'lose', child: Text('감량')),
                    DropdownMenuItem(value: 'maintain', child: Text('유지')),
                    DropdownMenuItem(value: 'gain', child: Text('증량')),
                  ],
                  onChanged: (v) => setState(() => _goal = v ?? _goal),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _sex,
                  decoration: const InputDecoration(labelText: '성별'),
                  items: const [
                    DropdownMenuItem(
                        value: 'unspecified', child: Text('선택 안 함')),
                    DropdownMenuItem(value: 'male', child: Text('남성')),
                    DropdownMenuItem(value: 'female', child: Text('여성')),
                  ],
                  onChanged: (v) => setState(() => _sex = v ?? _sex),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          FilledButton(
              onPressed: _busy ? null : _save, child: const Text('저장')),
          const SizedBox(height: 10),
          Text('키·나이는 기초대사량 하한 계산에 쓰입니다.',
              style: TextStyle(fontSize: 12, color: c.ink3)),
        ],
      ),
    );
  }
}
