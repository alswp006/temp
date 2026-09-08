import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../app_state.dart';
import '../theme/tokens.dart';
import '../ui/labels.dart';
import '../ui/widgets.dart';

/// 배틀.
///
/// 이 화면은 참여 중인 배틀이 없으면 거의 비어 있습니다. 예전에는 그 자리에
/// "참여 중인 배틀이 없습니다." 회색 한 줄만 있어서, 배틀이 무엇인지도 모른 채
/// 화면이 고장난 것처럼 보였습니다. 빈 상태에서 규칙을 한 줄로 알려 주고 바로
/// 다음 행동으로 보내는 것이 이 화면의 가장 중요한 일입니다.
///
/// 리더보드가 있을 때는 반대로 순위가 즉시 읽혀야 합니다. 숫자만 세로로 쌓으면
/// 1등과 꼴찌의 차이가 "12"와 "9"라는 글자 차이로만 남습니다. 1·2·3위에 메달을
/// 주고, 점수를 1위 대비 길이로 그리고, 내 줄을 색으로 띄웁니다.
class BattleScreen extends StatefulWidget {
  const BattleScreen({super.key});

  @override
  State<BattleScreen> createState() => _BattleScreenState();
}

class _BattleScreenState extends State<BattleScreen>
    with DataListener<BattleScreen> {
  final _name = TextEditingController();
  final _code = TextEditingController();
  final _codeFocus = FocusNode();

  List<(Battle, List<LeaderboardRow>)> _battles = const [];
  bool _loading = true;
  bool _failed = false;
  bool _creating = false;
  bool _joining = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  /// [DataBus]가 부릅니다 — 배틀을 만들거나 참가한 직후.
  @override
  Future<void> reload() => _load();

  Future<void> _load() async {
    final api = context.api;
    try {
      final list = (await api.get('/battles') as List)
          .map((e) => Battle.fromJson(e as Map<String, dynamic>))
          .toList();

      // 리더보드는 배틀마다 하나씩이지만 서로 무관합니다. 순차로 돌면
      // 배틀 다섯 개에 왕복 여섯 번이 직렬로 쌓입니다.
      final boards = await Future.wait(list.map((battle) async =>
          (await api.get('/battles/${battle.id}/leaderboard') as List)
              .map((e) => LeaderboardRow.fromJson(e as Map<String, dynamic>))
              .toList()));
      final loaded = [
        for (var i = 0; i < list.length; i++) (list[i], boards[i]),
      ];
      if (!mounted) return;
      setState(() {
        _battles = loaded;
        _loading = false;
        _failed = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
      showToast(context, e.message, tone: ToastTone.error);
    } on OfflineException {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty || _creating) return;
    setState(() => _creating = true);
    try {
      await context.api.post('/battles', body: {'name': name, 'weeks': 1});
      if (!mounted) return;
      _name.clear();
      FocusScope.of(context).unfocus();
      showToast(context, '배틀을 만들었습니다', tone: ToastTone.success);
      // 만든 배틀은 이 화면 말고 다른 곳에서도 세어집니다. 알리면 이 화면의
      // reload()도 함께 돌아갑니다.
      context.data.bump();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, tone: ToastTone.error);
    } on OfflineException {
      if (mounted) {
        showToast(context, '네트워크에 연결할 수 없습니다', tone: ToastTone.error);
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _join() async {
    final code = _code.text.trim();
    if (code.isEmpty || _joining) return;
    setState(() => _joining = true);
    try {
      await context.api.post('/battles/join', body: {'join_code': code});
      if (!mounted) return;
      _code.clear();
      FocusScope.of(context).unfocus();
      showToast(context, '배틀에 참가했습니다', tone: ToastTone.success);
      context.data.bump();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message, tone: ToastTone.error);
    } on OfflineException {
      if (mounted) {
        showToast(context, '네트워크에 연결할 수 없습니다', tone: ToastTone.error);
      }
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  Future<void> _copyCode(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    showToast(context, '초대 코드 $code를 복사했습니다', tone: ToastTone.success);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _battles.isEmpty) return const _BattleSkeleton();

    final meId = context.session.user?.id;

    return ScreenBody(
      onRefresh: _load,
      children: [
        if (_battles.isEmpty)
          if (_failed)
            EmptyState(
              '연결을 확인하고 다시 시도해 주세요.',
              icon: Icons.cloud_off_rounded,
              title: '불러오지 못했습니다',
              action: '다시 시도',
              onAction: _load,
            )
          else
            _Intro(onJoin: _codeFocus.requestFocus),

        for (var i = 0; i < _battles.length; i++)
          _BattleCard(
            battle: _battles[i].$1,
            board: _battles[i].$2,
            hero: i == 0,
            meId: meId,
            onCopy: _copyCode,
          ),

        if (_battles.isNotEmpty) const _ScoreNote(),

        _CreateJoin(
          name: _name,
          code: _code,
          codeFocus: _codeFocus,
          creating: _creating,
          joining: _joining,
          onCreate: _create,
          onJoin: _join,
        ),
      ],
    );
  }
}

// =============================================================================
// 빈 상태
// =============================================================================

/// 배틀이 하나도 없을 때의 주인공.
///
/// 규칙을 여기서 말해 두면, 나중에 순위표를 봤을 때 "왜 저 사람이 1등이지"를
/// 묻지 않게 됩니다. 체중을 점수에 넣지 않는다는 것이 이 기능의 성격을 그대로
/// 설명하므로 첫 화면에서 밝힙니다.
class _Intro extends StatelessWidget {
  const _Intro({required this.onJoin});

  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    return SikpanCard(
      hero: true,
      padding: const EdgeInsets.fromLTRB(Dim.s20, Dim.s16, Dim.s20, Dim.s20),
      child: EmptyState(
        '기록한 날마다 1점씩 쌓입니다.\n체중 수치는 점수에 들어가지 않습니다 —\n많이 뺀 사람이 아니라 꾸준한 사람이 이깁니다.',
        icon: Icons.emoji_events_outlined,
        title: '참여 중인 배틀이 없습니다',
        action: '초대 코드 입력',
        onAction: onJoin,
      ),
    );
  }
}

/// 순위표 아래 붙는 규칙 한 줄. 카드로 만들면 순위보다 커 보이므로 각주로 둡니다.
class _ScoreNote extends StatelessWidget {
  const _ScoreNote();

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Dim.s4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 14, color: c.ink3),
          const SizedBox(width: Dim.s6),
          Expanded(
            child: Text(
              '점수는 기록했다는 사실로 쌓입니다. 체중 수치는 점수에 들어가지 않습니다.',
              style: TextStyle(fontSize: 12, height: 1.4, color: c.ink3),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// 배틀 카드
// =============================================================================

class _BattleCard extends StatelessWidget {
  const _BattleCard({
    required this.battle,
    required this.board,
    required this.hero,
    required this.meId,
    required this.onCopy,
  });

  final Battle battle;
  final List<LeaderboardRow> board;

  /// 첫 배틀이 화면의 주인공입니다.
  final bool hero;

  final int? meId;
  final void Function(String code) onCopy;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final myIndex =
        meId == null ? -1 : board.indexWhere((r) => r.userId == meId);
    final me = myIndex >= 0 ? board[myIndex] : null;
    final top = board.fold<int>(0, (m, r) => r.points > m ? r.points : m);
    final remain = _remaining(battle.endDate);

    return SikpanCard(
      hero: hero,
      icon: Icons.emoji_events_rounded,
      title: battle.name,
      subtitle:
          '${Fmt.date(battle.startDate)} – ${Fmt.date(battle.endDate)} · ${board.length}명',
      trailing: Pressable(
        onTap: () => onCopy(battle.joinCode),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SikpanBadge('코드 ${battle.joinCode}', tone: BadgeTone.accent),
            const SizedBox(width: Dim.s4),
            Icon(Icons.copy_rounded, size: 14, color: c.ink3),
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StatRow(children: [
            StatBlock(
              value: me != null ? '${myIndex + 1}위' : '–',
              label: '내 순위',
              hint: board.isEmpty ? null : '${board.length}명 중',
              color: myIndex == 0 ? c.accent : null,
            ),
            StatBlock(
              value: '${me?.points ?? 0}점',
              label: '내 점수',
              hint: (me?.streak ?? 0) > 0 ? '🔥 ${me!.streak}일 연속' : null,
            ),
            StatBlock(
              value: remain,
              label: '남은 기간',
              hint: '${Fmt.date(battle.endDate)}까지',
            ),
          ]),
          const SizedBox(height: Dim.s20),
          Divider(height: 1, color: c.lineSoft),
          if (board.isEmpty)
            EmptyState(
              '초대 코드 ${battle.joinCode}를 보내면\n들어온 사람부터 순위표에 올라갑니다.',
              icon: Icons.group_add_outlined,
              title: '아직 참가자가 없습니다',
              action: '코드 복사',
              onAction: () => onCopy(battle.joinCode),
            )
          else ...[
            const SizedBox(height: Dim.s8),
            for (var i = 0; i < board.length; i++)
              _BoardRow(
                rank: i + 1,
                row: board[i],
                top: top,
                isMe: meId != null && board[i].userId == meId,
                last: i == board.length - 1,
              ),
          ],
        ],
      ),
    );
  }
}

/// 남은 기간. 'D-3'은 숫자 하나로 "아직 만회할 수 있나"를 알려줍니다.
String _remaining(String endIso) {
  if (endIso.isEmpty) return '–';
  // 날짜만 온 경우 로컬 자정으로 읽습니다 — UTC로 읽으면 하루가 밀립니다.
  final end =
      DateTime.tryParse(endIso.length == 10 ? '${endIso}T00:00:00' : endIso)
          ?.toLocal();
  if (end == null) return '–';
  final now = DateTime.now();
  final days = DateTime(end.year, end.month, end.day)
      .difference(DateTime(now.year, now.month, now.day))
      .inDays;
  if (days < 0) return '종료';
  if (days == 0) return '오늘까지';
  return 'D-$days';
}

// =============================================================================
// 순위 한 줄
// =============================================================================

/// 참가자 한 명.
///
/// 점수를 1위 대비 길이로 함께 그립니다. "12점"과 "9점"은 글자로는 비슷해
/// 보이지만 막대로는 따라잡을 수 있는 거리인지가 바로 보입니다. 내 줄은 배경을
/// 깔아 스크롤 중에도 눈이 먼저 찾도록 했습니다.
class _BoardRow extends StatelessWidget {
  const _BoardRow({
    required this.rank,
    required this.row,
    required this.top,
    required this.isMe,
    required this.last,
  });

  final int rank;
  final LeaderboardRow row;
  final int top;
  final bool isMe;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final medal = switch (rank) {
      1 => (c.accent, Colors.white, true),
      2 => (c.accentSoft, c.accent, true),
      3 => (c.warn.withValues(alpha: c.isDark ? 0.20 : 0.14), c.warn, true),
      _ => (Colors.transparent, c.ink3, false),
    };
    final barColor = switch (rank) {
      1 => c.accent,
      2 => c.accent.withValues(alpha: 0.65),
      3 => c.warn,
      _ => c.ink3.withValues(alpha: 0.55),
    };
    final tail = row.streak > 0
        ? '🔥${row.streak} · ${row.loggedDays}일'
        : '${row.loggedDays}일';

    return Column(
      children: [
        Container(
          padding: EdgeInsets.symmetric(
              horizontal: isMe ? Dim.s8 : 0, vertical: Dim.s8 + 2),
          decoration: isMe
              ? BoxDecoration(
                  color: c.accentSoft,
                  borderRadius: BorderRadius.circular(Dim.radiusSm),
                )
              : null,
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: medal.$1,
                      shape: BoxShape.circle,
                      border: medal.$3
                          ? null
                          : Border.all(color: c.line),
                    ),
                    child: Text(
                      '$rank',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: medal.$2,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(width: Dim.s12),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            row.nickname,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight:
                                  rank <= 3 || isMe ? FontWeight.w700 : FontWeight.w600,
                              color: c.ink,
                            ),
                          ),
                        ),
                        if (isMe) ...[
                          const SizedBox(width: Dim.s6),
                          const SikpanBadge('나', tone: BadgeTone.accent),
                        ],
                        if (row.team != null) ...[
                          const SizedBox(width: Dim.s6),
                          SikpanBadge(row.team!),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: Dim.s8),
                  AnimatedCount(
                    row.points.toDouble(),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                      color: rank == 1 ? c.accent : c.ink,
                    ),
                    format: (v) => '${v.round()}점',
                  ),
                ],
              ),
              const SizedBox(height: Dim.s8),
              Row(
                children: [
                  const SizedBox(width: 26 + Dim.s12),
                  Expanded(
                    child: Meter(
                      value: row.points.toDouble(),
                      target: top > 0 ? top.toDouble() : null,
                      warnOver: false,
                      height: 5,
                      color: barColor,
                    ),
                  ),
                  const SizedBox(width: Dim.s8),
                  SizedBox(
                    width: 66,
                    child: Text(
                      tail,
                      textAlign: TextAlign.right,
                      style: TextStyle(fontSize: 11.5, color: c.ink3),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (!last) Divider(height: 1, color: c.lineSoft),
      ],
    );
  }
}

// =============================================================================
// 만들기 / 참가
// =============================================================================

class _CreateJoin extends StatelessWidget {
  const _CreateJoin({
    required this.name,
    required this.code,
    required this.codeFocus,
    required this.creating,
    required this.joining,
    required this.onCreate,
    required this.onJoin,
  });

  final TextEditingController name;
  final TextEditingController code;
  final FocusNode codeFocus;
  final bool creating;
  final bool joining;
  final VoidCallback onCreate;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SikpanCard(
      title: '새로 만들기 / 참가',
      subtitle: '한 배틀은 1주 동안 이어집니다',
      icon: Icons.add_circle_outline_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label(context, '이름을 정해 새 배틀을 만들기'),
          const SizedBox(height: Dim.s8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: name,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => onCreate(),
                  decoration: const InputDecoration(hintText: '배틀 이름'),
                ),
              ),
              const SizedBox(width: Dim.s8),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: name,
                builder: (_, value, __) => FilledButton(
                  onPressed:
                      value.text.trim().isEmpty || creating ? null : onCreate,
                  child: creating
                      ? const _Spinner(color: Colors.white)
                      : const Text('생성'),
                ),
              ),
            ],
          ),
          const SizedBox(height: Dim.s20),
          Divider(height: 1, color: c.lineSoft),
          const SizedBox(height: Dim.s20),
          _label(context, '받은 초대 코드로 참가하기'),
          const SizedBox(height: Dim.s8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: code,
                  focusNode: codeFocus,
                  autocorrect: false,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => onJoin(),
                  decoration: const InputDecoration(hintText: '초대 코드'),
                ),
              ),
              const SizedBox(width: Dim.s8),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: code,
                builder: (_, value, __) => OutlinedButton(
                  onPressed:
                      value.text.trim().isEmpty || joining ? null : onJoin,
                  child: joining ? _Spinner(color: c.ink) : const Text('참가'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _label(BuildContext context, String text) => Text(
        text,
        style: TextStyle(
            fontSize: 12.5, fontWeight: FontWeight.w600, color: context.c.ink3),
      );
}

/// 버튼 안에서 도는 표시. 글자와 자리를 맞춰 눌러도 버튼이 줄어들지 않습니다.
class _Spinner extends StatelessWidget {
  const _Spinner({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2, color: color),
    );
  }
}

// =============================================================================
// 로딩
// =============================================================================

/// 처음 뜰 때의 뼈대. 가운데 스피너 하나였을 때는 내용이 도착하는 순간 화면이
/// 통째로 튀었습니다.
class _BattleSkeleton extends StatelessWidget {
  const _BattleSkeleton();

  @override
  Widget build(BuildContext context) {
    return const ScreenBody(animate: false, children: [
      SikpanCard(
        hero: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Skeleton(width: 130, height: 18),
            SizedBox(height: Dim.s8),
            Skeleton(width: 180, height: 11),
            SizedBox(height: Dim.s20),
            Skeleton(height: 46, radius: Dim.radiusSm),
            SizedBox(height: Dim.s20),
            Skeleton(height: 34, radius: Dim.radiusSm),
            SizedBox(height: Dim.s12),
            Skeleton(height: 34, radius: Dim.radiusSm),
            SizedBox(height: Dim.s12),
            Skeleton(height: 34, radius: Dim.radiusSm),
          ],
        ),
      ),
      SikpanCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Skeleton(width: 110),
            SizedBox(height: Dim.s20),
            Skeleton(height: 46, radius: Dim.radiusSm),
            SizedBox(height: Dim.s12),
            Skeleton(height: 46, radius: Dim.radiusSm),
          ],
        ),
      ),
    ]);
  }
}
