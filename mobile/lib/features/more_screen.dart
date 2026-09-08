import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../app_state.dart';
import '../theme/tokens.dart';
import '../ui/labels.dart';
import '../ui/widgets.dart';

/// 더보기.
///
/// 성격이 다른 것들이 모이는 자리입니다. 이전에는 그 사실이 그대로 드러나
/// 있었습니다 — 멘토·식당·프로필·목표·알림·로그아웃이 같은 흰 카드로 일곱 장
/// 쌓여 있어서, 무엇을 하러 들어왔든 처음부터 끝까지 훑어야 했습니다.
///
/// 그래서 두 가지를 바꿨습니다.
///
/// * **구역을 나눕니다.** 카드 위에 [SectionHeader]를 세워 "사람 / 식당 / 나 /
///   계정"으로 묶습니다. 카드 제목보다 한 단계 위의 글자가 있으면 스크롤 중에도
///   지금 어느 구역인지 알 수 있습니다.
/// * **목표를 맨 위로 올립니다.** 오늘 화면의 '목표 설정' 버튼이 이 화면으로
///   오는데, 목표 카드가 셋째 칸에 있으면 도착하자마자 찾아 헤매게 됩니다.
///   히어로 카드 하나만 화면의 주인공이 되고 나머지는 보조로 물러납니다.
///
/// 위험한 것(로그아웃)은 맨 아래에, 위험한 색으로 둡니다. 손가락이 스크롤하다
/// 우연히 닿는 자리에 있으면 안 되기 때문입니다.
class MoreScreen extends StatefulWidget {
  const MoreScreen({super.key});

  @override
  State<MoreScreen> createState() => _MoreScreenState();
}

class _MoreScreenState extends State<MoreScreen> with DataListener<MoreScreen> {
  User? _me;
  List<Canteen> _canteens = const [];
  List<Mentorship> _mentorships = const [];
  List<MenteeCard> _dashboard = const [];
  List<AppNotification> _notifications = const [];
  Target? _target;
  bool _loading = true;
  bool _targetBusy = false;

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

  /// [DataBus]가 부릅니다 — 목표·프로필·연결·식당이 바뀐 직후.
  @override
  Future<void> reload() => _load();

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

    // 여섯 개를 한꺼번에 던집니다. 순차로 기다리면 지하철에서 왕복 6번이
    // 그대로 더해져 화면이 몇 초씩 비어 있게 됩니다. 서로 의존하지 않으므로
    // 기다릴 이유가 없습니다.
    final results = await Future.wait([
      _try(() async =>
          User.fromJson(await api.get('/auth/me') as Map<String, dynamic>)),
      _try(() async => (await api.get('/canteens') as List)
          .map((e) => Canteen.fromJson(e as Map<String, dynamic>))
          .toList()),
      _try(() async => (await api.get('/mentorships') as List)
          .map((e) => Mentorship.fromJson(e as Map<String, dynamic>))
          .toList()),
      _try(() async => (await api.get('/mentorships/dashboard') as List)
          .map((e) => MenteeCard.fromJson(e as Map<String, dynamic>))
          .toList()),
      _try(() async =>
          (await api.get('/notifications', query: {'limit': 8}) as List)
              .map((e) => AppNotification.fromJson(e as Map<String, dynamic>))
              .toList()),
      _try(() async {
        final json = await api.get('/targets/current');
        return json == null
            ? null
            : Target.fromJson(json as Map<String, dynamic>);
      }),
    ]);

    final me = results[0] as User?;
    final canteens = results[1] as List<Canteen>?;
    final mentorships = results[2] as List<Mentorship>?;
    final dashboard = results[3] as List<MenteeCard>?;
    final notifications = results[4] as List<AppNotification>?;
    final target = results[5] as Target?;

    if (!mounted) return;
    if (me != null) await context.session.updateUser(me);
    if (!mounted) return;

    // 고른 식당이 서버 목록에 없으면 선택을 버립니다. 선택은 기기에만 남으므로,
    // 식당이 지워지거나 권한을 잃으면 사진 업로드가 계속 403으로 실패하는데
    // 목록이 비어 있으면 화면에 '선택 안 함' 칩조차 없어 손으로 지울 수도
    // 없습니다.
    final selected = context.session.canteenId;
    if (canteens != null &&
        selected != null &&
        !canteens.any((c) => c.id == selected)) {
      await context.session.selectCanteen(null);
      if (!mounted) return;
    }

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

  /// 서버를 바꾸는 동작 한 번을 감쌉니다.
  ///
  /// 세 가지를 한 자리에 모아 둡니다 — 실패는 빨간 토스트로, 성공은 초록
  /// 토스트로, 그리고 성공했으면 [DataBus]를 울립니다. 울리지 않으면 방금 정한
  /// 목표가 오늘 화면의 링에 반영되지 않습니다.
  Future<bool> _run(Future<void> Function() body, {String? success}) async {
    try {
      await body();
      if (!mounted) return false;
      if (success != null) {
        showToast(context, success, tone: ToastTone.success);
      }
      context.data.bump();
      return true;
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, tone: ToastTone.error);
      return false;
    } on OfflineException {
      if (mounted) {
        showToast(context, '네트워크에 연결할 수 없습니다', tone: ToastTone.error);
      }
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = _me;

    // 첫 로드는 뼈대로 받습니다. 가운데 스피너는 내용이 도착하는 순간 화면을
    // 통째로 튀게 만듭니다.
    if (_loading && me == null) return const _MoreSkeleton();
    if (me == null) {
      return ScreenBody(children: [
        EmptyState(
          '연결을 확인하고 다시 시도해 주세요.',
          icon: Icons.cloud_off_rounded,
          title: '불러오지 못했습니다',
          action: '다시 시도',
          onAction: _load,
        ),
      ]);
    }

    return ScreenBody(
      onRefresh: _load,
      children: [
        _Section(title: '프로필·목표', children: [
          _targetCard(),
          _ProfileCard(me: me),
        ]),
        _Section(title: '함께 하는 사람', children: [
          if (_dashboard.isNotEmpty) _coachCard(),
          _connectionCard(me),
        ]),
        _Section(title: '내 식당', children: [
          _canteenCard(),
          _canteenJoinCard(),
        ]),
        if (_notifications.isNotEmpty)
          _Section(title: '알림', children: [_notificationCard()]),
        _Section(title: '계정', children: [
          _accountCard(me),
          _signOutCard(),
        ]),
        _footer(),
      ],
    );
  }

  // --- 목표 (히어로) --------------------------------------------------------
  //
  // 목표는 이 화면에서 가장 자주 고치러 오는 값이고, 오늘 화면이 링을 채우는
  // 근거이기도 합니다. 숫자 세 개를 나란히 놓는 대신 목표 kcal 하나를 크게
  // 세우고, 추정 TDEE 대비 위치를 막대로 붙여 "이게 공격적인 목표인가"를 읽지
  // 않고도 알 수 있게 했습니다.

  Widget _targetCard() {
    final c = context.c;
    final t = _target;
    final tdee = t?.estTdee ?? 0;

    return SikpanCard(
      hero: true,
      title: '이번 주 목표',
      subtitle: t == null
          ? '아직 정하지 않았습니다'
          : (t.pinned ? '직접 고정한 값' : '몸 정보로 자동 계산한 값'),
      icon: Icons.flag_rounded,
      trailing: t == null
          ? null
          : SikpanBadge(t.pinned ? '고정' : '자동',
              tone: t.pinned ? BadgeTone.accent : BadgeTone.neutral),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (t == null)
            const EmptyState(
              '키·출생연도를 채운 뒤 계산하면\n오늘 화면이 남은 양을 알려줍니다.',
              icon: Icons.flag_outlined,
              title: '목표가 없습니다',
            )
          else ...[
            Center(
              child: Column(
                children: [
                  AnimatedCount(
                    t.targetKcal,
                    style: TextStyle(
                      fontSize: 44,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1.8,
                      height: 1.0,
                      color: c.ink,
                    ),
                    format: (v) => Fmt.kcal(v),
                  ),
                  const SizedBox(height: Dim.s4),
                  Text('하루 kcal',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: c.ink2)),
                ],
              ),
            ),
            const SizedBox(height: Dim.s20),
            StatRow(children: [
              StatBlock(
                value: Fmt.g(t.targetProteinG),
                label: '단백질 목표',
                color: c.protein,
                dot: true,
              ),
              StatBlock(
                value: tdee > 0 ? Fmt.kcal(tdee) : '–',
                label: '추정 TDEE',
                hint: tdee > 0 ? '유지 칼로리' : '기록이 쌓이면 나옵니다',
              ),
            ]),
            if (tdee > 0) ...[
              const SizedBox(height: Dim.s20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('추정 TDEE 대비',
                      style: TextStyle(fontSize: 12, color: c.ink3)),
                  Text(Fmt.pct(t.targetKcal / tdee),
                      style: TextStyle(
                          fontSize: 12,
                          color: c.ink3,
                          fontFeatures: const [FontFeature.tabularFigures()])),
                ],
              ),
              const SizedBox(height: Dim.s8),
              Meter(value: t.targetKcal, target: tdee, warnOver: false),
            ],
          ],
          const SizedBox(height: Dim.s20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _targetBusy ? null : _refreshTarget,
                  icon: _targetBusy
                      ? SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: c.ink3),
                        )
                      : const Icon(Icons.refresh_rounded, size: 17),
                  label: Text(t == null ? '계산하기' : '다시 계산'),
                ),
              ),
              const SizedBox(width: Dim.s8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _targetBusy ? null : _pinTarget,
                  icon: const Icon(Icons.tune_rounded, size: 17),
                  label: const Text('직접 정하기'),
                ),
              ),
            ],
          ),
          const SizedBox(height: Dim.s12),
          Text('공식이 뱉은 값은 초기값일 뿐입니다. 다만 기초대사량 아래로는 내려가지 않습니다.',
              style: TextStyle(fontSize: 12, height: 1.45, color: c.ink3)),
        ],
      ),
    );
  }

  Future<void> _refreshTarget() async {
    setState(() => _targetBusy = true);
    await _run(
      () async => context.api.post('/targets/refresh'),
      success: '목표를 다시 계산했습니다',
    );
    if (mounted) setState(() => _targetBusy = false);
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
    setState(() => _targetBusy = true);
    try {
      await context.api.put('/targets/current', body: {
        'target_kcal': kcal,
        'pinned': true,
        if (confirmAggressive) 'confirm_aggressive': true,
      });
      if (!mounted) return;
      showToast(context, '목표를 고정했습니다', tone: ToastTone.success);
      context.data.bump();
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
        showToast(context, e.message, tone: ToastTone.error);
      }
    } on OfflineException {
      if (mounted) {
        showToast(context, '네트워크에 연결할 수 없습니다', tone: ToastTone.error);
      }
    } finally {
      if (mounted) setState(() => _targetBusy = false);
    }
  }

  // --- 코치 대시보드 -------------------------------------------------------

  Widget _coachCard() {
    final c = context.c;
    return SikpanCard(
      title: '내가 보고 있는 사람',
      subtitle: '멘티 ${_dashboard.length}명',
      icon: Icons.supervisor_account_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < _dashboard.length; i++)
            _MenteeRow(
              card: _dashboard[i],
              last: i == _dashboard.length - 1,
              onTap: () => context.push('/mentee/${_dashboard[i].userId}'),
            ),
          const SizedBox(height: Dim.s12),
          Text('미기록이 길어져도 자동 독촉 알림은 보내지 않습니다.',
              style: TextStyle(fontSize: 12, color: c.ink3)),
        ],
      ),
    );
  }

  // --- 멘토·멘티 -----------------------------------------------------------

  Widget _connectionCard(User me) {
    final c = context.c;
    final asMentee = _mentorships.where((m) => m.menteeId == me.id).toList();
    final asMentor = _mentorships.where((m) => m.mentorId == me.id).toList();
    final empty = asMentee.isEmpty && asMentor.isEmpty;

    return SikpanCard(
      title: '연결',
      subtitle: '허용한 항목만 상대에게 보입니다',
      icon: Icons.link_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (empty)
            const EmptyState(
              '초대 링크를 보내면 서로의 기록을 볼 수 있습니다.\n무엇을 보여줄지는 항목별로 고릅니다.',
              icon: Icons.person_add_alt_1_outlined,
              title: '아직 연결된 사람이 없습니다',
            ),
          if (asMentee.isNotEmpty) ...[
            _groupLabel('나를 봐주는 사람'),
            for (var i = 0; i < asMentee.length; i++)
              ListRow(
                showDivider: i != asMentee.length - 1,
                content: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(asMentee[i].mentorName ?? '?',
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700)),
                    const SizedBox(height: Dim.s2),
                    Text(
                      asMentee[i]
                          .permissions
                          .entries
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
                      onPressed: () =>
                          context.push('/permissions/${asMentee[i].id}'),
                      child: const Text('권한'),
                    ),
                    IconButton(
                      onPressed: () => _endMentorship(asMentee[i]),
                      icon: Icon(Icons.link_off_rounded,
                          size: 19, color: c.danger),
                      tooltip: '연결 해제',
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              ),
            const SizedBox(height: Dim.s16),
          ],
          if (asMentor.isNotEmpty) ...[
            _groupLabel('내가 봐주는 사람'),
            for (var i = 0; i < asMentor.length; i++)
              ListRow(
                showDivider: i != asMentor.length - 1,
                leading: Icon(
                  asMentor[i].menteeName == null
                      ? Icons.hourglass_empty_rounded
                      : Icons.person_rounded,
                  size: 18,
                  color: asMentor[i].menteeName == null ? c.ink3 : c.accent,
                ),
                content: Text(asMentor[i].menteeName ?? '수락 대기 중',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color:
                            asMentor[i].menteeName == null ? c.ink3 : c.ink)),
                trailing: asMentor[i].menteeName == null
                    ? const SikpanBadge('대기', tone: BadgeTone.warn)
                    : null,
              ),
            const SizedBox(height: Dim.s16),
          ],
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _createInvite('peer'),
                  icon: const Icon(Icons.people_outline_rounded, size: 17),
                  label: const Text('친구 초대'),
                ),
              ),
              const SizedBox(width: Dim.s8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _createInvite('coach'),
                  icon: const Icon(Icons.school_outlined, size: 17),
                  label: const Text('코치로 초대'),
                ),
              ),
            ],
          ),
          const SizedBox(height: Dim.s12),
          _FieldAction(
            controller: _inviteCode,
            hint: '받은 초대 코드',
            actionLabel: '열기',
            filled: true,
            onAction: _openInvite,
          ),
        ],
      ),
    );
  }

  Widget _groupLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: Dim.s4),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
            color: context.c.ink3,
          ),
        ),
      );

  void _openInvite() {
    final code = _inviteCode.text.trim();
    if (code.isEmpty) {
      showToast(context, '초대 코드를 입력해 주세요', tone: ToastTone.error);
      return;
    }
    context.push('/invite/$code');
  }

  Future<void> _createInvite(String type) async {
    try {
      final res = await context.api.post('/mentorships/invite',
          body: {'type': type}) as Map<String, dynamic>;
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
              const SizedBox(height: Dim.s12),
              SelectableText(code,
                  style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2)),
              const SizedBox(height: Dim.s6),
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
      if (mounted) context.data.bump();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, tone: ToastTone.error);
    } on OfflineException {
      if (mounted) {
        showToast(context, '네트워크에 연결할 수 없습니다', tone: ToastTone.error);
      }
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
    await _run(
      () async => context.api.delete('/mentorships/${m.id}'),
      success: '연결을 해제했습니다',
    );
  }

  // --- 내 식당 -------------------------------------------------------------

  Widget _canteenCard() {
    final selected = context.session.canteenId;

    return SikpanCard(
      title: '식당 선택',
      subtitle: '고른 식당의 식단표가 있으면 오차가 크게 줄어듭니다',
      icon: Icons.restaurant_menu_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_canteens.isEmpty)
            const EmptyState(
              '아래에서 새로 만들거나\n받은 초대 코드로 참가하세요.',
              icon: Icons.storefront_outlined,
              title: '아직 식당이 없습니다',
            )
          else
            Wrap(
              spacing: Dim.s8,
              runSpacing: Dim.s8,
              children: [
                SikpanChip(
                  label: '선택 안 함',
                  selected: selected == null,
                  onTap: () => _selectCanteen(null),
                ),
                for (final canteen in _canteens)
                  SikpanChip(
                    label: canteen.name,
                    icon: selected == canteen.id
                        ? Icons.check_rounded
                        : Icons.storefront_outlined,
                    selected: selected == canteen.id,
                    onTap: () => _selectCanteen(canteen.id),
                  ),
              ],
            ),
          if (selected != null) ...[
            const SizedBox(height: Dim.s16),
            OutlinedButton.icon(
              onPressed: () => context.push('/menu/$selected'),
              icon: const Icon(Icons.calendar_month_rounded, size: 17),
              label: const Text('이번 주 식단표 보기 / 올리기'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _canteenJoinCard() {
    return SikpanCard(
      title: '식당 만들기 · 참가',
      icon: Icons.add_business_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _FieldAction(
            controller: _canteenName,
            hint: '새 식당 이름',
            actionLabel: '만들기',
            filled: true,
            onAction: _createCanteen,
          ),
          const SizedBox(height: Dim.s12),
          _FieldAction(
            controller: _canteenCode,
            hint: '식당 초대 코드',
            actionLabel: '참가',
            onAction: _joinCanteen,
          ),
        ],
      ),
    );
  }

  Future<void> _selectCanteen(int? id) async {
    await context.session.selectCanteen(id);
    if (!mounted) return;
    setState(() {});
    // 어느 식당을 고르느냐에 따라 다른 화면의 식단표 매칭이 달라집니다.
    context.data.bump();
  }

  Future<void> _createCanteen() async {
    final name = _canteenName.text.trim();
    if (name.isEmpty) {
      showToast(context, '식당 이름을 입력해 주세요', tone: ToastTone.error);
      return;
    }
    final scope = AppScope.of(context);
    await _run(
      () async {
        final json = await scope.api.post('/canteens', body: {'name': name});
        final canteen = Canteen.fromJson(json as Map<String, dynamic>);
        _canteenName.clear();
        await scope.session.selectCanteen(canteen.id);
      },
      success: '$name 식당을 만들었습니다',
    );
  }

  Future<void> _joinCanteen() async {
    final code = _canteenCode.text.trim();
    if (code.isEmpty) {
      showToast(context, '초대 코드를 입력해 주세요', tone: ToastTone.error);
      return;
    }
    final scope = AppScope.of(context);
    await _run(
      () async {
        final json =
            await scope.api.post('/canteens/join', body: {'join_code': code});
        final canteen = Canteen.fromJson(json as Map<String, dynamic>);
        _canteenCode.clear();
        await scope.session.selectCanteen(canteen.id);
      },
      success: '식당에 참가했습니다',
    );
  }

  // --- 알림 ----------------------------------------------------------------

  Widget _notificationCard() {
    final c = context.c;
    return SikpanCard(
      title: '최근 알림',
      icon: Icons.notifications_none_rounded,
      child: Column(
        children: [
          for (var i = 0; i < _notifications.length; i++)
            ListRow(
              showDivider: i != _notifications.length - 1,
              leading: Container(
                width: 6,
                height: 6,
                decoration:
                    BoxDecoration(color: c.accent, shape: BoxShape.circle),
              ),
              content: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_notifications[i].title,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  if (_notifications[i].body != null) ...[
                    const SizedBox(height: Dim.s2),
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

  // --- 계정 ----------------------------------------------------------------

  Widget _accountCard(User me) {
    final c = context.c;
    const planLabel = <String, String>{
      'free': '무료',
      'pro': '프로',
      'coach': '코치',
    };

    return SikpanCard(
      padding: const EdgeInsets.symmetric(horizontal: Dim.s16, vertical: Dim.s4),
      child: Column(
        children: [
          ListRow(
            leading: Icon(Icons.mail_outline_rounded, size: 19, color: c.ink3),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(me.email,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: Dim.s2),
                Text('로그인 계정',
                    style: TextStyle(fontSize: 12, color: c.ink3)),
              ],
            ),
            trailing: SikpanBadge(
              planLabel[me.plan] ?? me.plan,
              tone: me.plan == 'free' ? BadgeTone.neutral : BadgeTone.accent,
            ),
          ),
          ListRow(
            showDivider: false,
            chevron: true,
            leading: Icon(Icons.history_rounded, size: 19, color: c.ink3),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('내 기록 변경 이력',
                    style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: Dim.s2),
                Text('누가 무엇을 고쳤는지 남습니다',
                    style: TextStyle(fontSize: 12, color: c.ink3)),
              ],
            ),
            onTap: () => context.push('/audit'),
          ),
        ],
      ),
    );
  }

  /// 위험 구역.
  ///
  /// 스크롤의 맨 끝, 붉은 카드 안에 혼자 둡니다. 다른 버튼들 사이에 회색으로
  /// 끼어 있으면 손가락이 지나가다 닿습니다.
  Widget _signOutCard() {
    final c = context.c;
    return SikpanCard(
      tone: c.danger,
      title: '로그아웃',
      subtitle: '이 기기에서 토큰을 지웁니다. 기록은 서버에 그대로 남습니다.',
      icon: Icons.logout_rounded,
      child: OutlinedButton(
        onPressed: _signOut,
        style: OutlinedButton.styleFrom(
          foregroundColor: c.danger,
          side: BorderSide(color: c.danger.withValues(alpha: 0.5)),
        ),
        child: const Text('로그아웃'),
      ),
    );
  }

  Future<void> _signOut() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('로그아웃할까요?'),
        content: const Text('기록은 서버에 남습니다. 다시 로그인하면 그대로 보입니다.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.c.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('로그아웃'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final router = GoRouter.of(context);
    final session = context.session;
    // 해제가 먼저입니다. signOut 뒤에는 토큰이 없어 서버가 받아 주지 않고,
    // 그러면 이 기기를 넘겨받은 사람에게 내 알림이 계속 갑니다.
    await context.pushClient.unregister();
    await session.signOut();
    router.go('/login');
  }

  Widget _footer() => Padding(
        padding: const EdgeInsets.only(top: Dim.s4),
        child: Text('식판 v0.1',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: context.c.ink3)),
      );
}

extension _StringX on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

// =============================================================================
// 조각들
// =============================================================================

/// 구역 하나 — 머리글 + 카드들.
///
/// [ScreenBody]의 자식 하나로 들어가므로 머리글과 그 아래 카드가 같은 리듬으로
/// 함께 들어옵니다. 머리글만 먼저 떠 있고 카드가 뒤늦게 따라붙으면 화면이
/// 조립되는 게 아니라 덜컹거리는 것처럼 보입니다.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 구역 사이는 카드 사이보다 넓어야 "묶음이 바뀌었다"가 읽힙니다.
        Padding(
          padding: const EdgeInsets.only(top: Dim.s8),
          child: SectionHeader(title),
        ),
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: Dim.gap),
          children[i],
        ],
      ],
    );
  }
}

/// 입력칸 하나 + 버튼 하나.
///
/// 이 화면에만 세 번 나옵니다(식당 만들기·참가·초대 코드). 매번 손으로 Row를
/// 짜면 버튼 높이가 조금씩 달라져 폼이 삐뚤어 보입니다.
class _FieldAction extends StatelessWidget {
  const _FieldAction({
    required this.controller,
    required this.hint,
    required this.actionLabel,
    required this.onAction,
    this.filled = false,
  });

  final TextEditingController controller;
  final String hint;
  final String actionLabel;
  final VoidCallback onAction;

  /// 그 줄에서 주된 행동이면 채운 버튼으로.
  final bool filled;

  @override
  Widget build(BuildContext context) {
    // 입력칸 높이(위아래 여백 15 + 본문 22)에 버튼을 맞춥니다.
    const size = Size(0, 52);
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => onAction(),
            decoration: InputDecoration(hintText: hint),
          ),
        ),
        const SizedBox(width: Dim.s8),
        if (filled)
          FilledButton(
            onPressed: onAction,
            style: FilledButton.styleFrom(minimumSize: size),
            child: Text(actionLabel),
          )
        else
          OutlinedButton(
            onPressed: onAction,
            style: OutlinedButton.styleFrom(minimumSize: size),
            child: Text(actionLabel),
          ),
      ],
    );
  }
}

/// 멘티 한 줄.
///
/// 주간 달성률이 '주 43%'라는 글자 하나로만 있었습니다. 막대를 붙이면 여러 명을
/// 훑을 때 숫자를 읽지 않고도 누가 처져 있는지 보입니다.
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
      chevron: true,
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
                  style: TextStyle(
                      fontSize: 12.5,
                      color: c.ink2,
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ],
          ),
          const SizedBox(height: Dim.s6),
          Meter(
            value: card.weekCompletion,
            target: 1,
            warnOver: false,
            height: 5,
            color: stale ? c.warn : c.accent,
          ),
          const SizedBox(height: Dim.s6),
          Text(bits.isEmpty ? '공유된 항목 없음' : bits.join(' · '),
              style: TextStyle(fontSize: 12.5, color: c.ink2)),
          if (stale) ...[
            const SizedBox(height: Dim.s2),
            Text('${card.staleDays}일째 기록 없음',
                style: TextStyle(fontSize: 11.5, color: c.warn)),
          ],
        ],
      ),
    );
  }
}

/// 프로필.
///
/// 키·나이는 기초대사량 하한 계산에 쓰이므로 설명을 붙여 둡니다. 목표(감량·유지·
/// 증량)도 여기 있습니다 — 위의 목표 카드가 이 값을 근거로 계산하기 때문에,
/// 두 카드를 붙여 두면 "왜 이 숫자가 나왔는지"가 한 화면에서 이어집니다.
class _ProfileCard extends StatefulWidget {
  const _ProfileCard({required this.me});
  final User me;

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
      showToast(context, '저장했습니다', tone: ToastTone.success);
      // 목표 계산의 입력이 바뀌었으므로 목표 카드도 다시 불러와야 합니다.
      context.data.bump();
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

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SikpanCard(
      title: '프로필',
      subtitle: widget.me.nickname.isEmpty ? null : '${widget.me.nickname}님',
      icon: Icons.person_outline_rounded,
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
              const SizedBox(width: Dim.s12),
              Expanded(
                child: TextField(
                  controller: _birth,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '출생연도'),
                ),
              ),
            ],
          ),
          const SizedBox(height: Dim.s12),
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
              const SizedBox(width: Dim.s12),
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
          const SizedBox(height: Dim.s16),
          FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: _busy
                ? SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: c.ink3),
                  )
                : const Icon(Icons.check_rounded, size: 18),
            label: Text(_busy ? '저장 중' : '저장'),
          ),
          const SizedBox(height: Dim.s12),
          Text('키·나이는 기초대사량 하한 계산에 쓰입니다. 위의 목표도 이 값으로 계산합니다.',
              style: TextStyle(fontSize: 12, height: 1.45, color: c.ink3)),
        ],
      ),
    );
  }
}

/// 더보기가 처음 뜰 때의 뼈대.
class _MoreSkeleton extends StatelessWidget {
  const _MoreSkeleton();

  @override
  Widget build(BuildContext context) {
    return const ScreenBody(animate: false, children: [
      SikpanCard(
        hero: true,
        child: Column(
          children: [
            Skeleton(width: 150, height: 42),
            SizedBox(height: Dim.s20),
            Skeleton(height: 8, radius: 99),
            SizedBox(height: Dim.s20),
            Skeleton(height: 48, radius: Dim.radiusSm),
          ],
        ),
      ),
      SikpanCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Skeleton(width: 110),
            SizedBox(height: Dim.s20),
            Skeleton(height: 48, radius: Dim.radiusSm),
            SizedBox(height: Dim.s12),
            Skeleton(height: 48, radius: Dim.radiusSm),
          ],
        ),
      ),
      SikpanCard(child: Skeleton(height: 84, radius: Dim.radiusSm)),
    ]);
  }
}
