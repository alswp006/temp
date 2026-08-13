import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../app_state.dart';
import '../theme/tokens.dart';
import '../ui/labels.dart';
import '../ui/widgets.dart';

class BattleScreen extends StatefulWidget {
  const BattleScreen({super.key});

  @override
  State<BattleScreen> createState() => _BattleScreenState();
}

class _BattleScreenState extends State<BattleScreen> {
  final _name = TextEditingController();
  final _code = TextEditingController();
  List<(Battle, List<LeaderboardRow>)> _battles = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

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
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showToast(context, e.message);
    } on OfflineException {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    try {
      await context.api.post('/battles', body: {'name': name, 'weeks': 1});
      _name.clear();
      await _load();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message);
    }
  }

  Future<void> _join() async {
    final code = _code.text.trim();
    if (code.isEmpty) return;
    try {
      await context.api.post('/battles/join', body: {'join_code': code});
      _code.clear();
      await _load();
    } on ApiException catch (e) {
      if (mounted) showToast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    if (_loading) return const Center(child: CircularProgressIndicator());

    return ScreenBody(
      onRefresh: _load,
      children: [
        if (_battles.isEmpty) const EmptyState('참여 중인 배틀이 없습니다.'),
        for (final (battle, board) in _battles)
          SikpanCard(
            title: battle.name,
            trailing: SikpanBadge('코드 ${battle.joinCode}'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${Fmt.date(battle.startDate)} – ${Fmt.date(battle.endDate)}',
                    style: TextStyle(fontSize: 12.5, color: c.ink3)),
                const SizedBox(height: 12),
                if (board.isEmpty)
                  const EmptyState('아직 참가자가 없습니다.')
                else
                  for (var i = 0; i < board.length; i++)
                    _BoardRow(
                        rank: i + 1,
                        row: board[i],
                        last: i == board.length - 1),
                const SizedBox(height: 10),
                Text('점수는 기록한 만큼 쌓입니다. 체중 수치는 점수에 들어가지 않습니다.',
                    style: TextStyle(fontSize: 12, color: c.ink3)),
              ],
            ),
          ),
        SikpanCard(
          title: '새로 만들기 / 참가',
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _name,
                      decoration: const InputDecoration(hintText: '배틀 이름'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _create, child: const Text('생성')),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _code,
                      decoration: const InputDecoration(hintText: '초대 코드'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(onPressed: _join, child: const Text('참가')),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _BoardRow extends StatelessWidget {
  const _BoardRow({required this.rank, required this.row, required this.last});
  final int rank;
  final LeaderboardRow row;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ListRow(
      showDivider: !last,
      leading: SizedBox(
        width: 24,
        child: Text('$rank',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: rank <= 3 ? c.accent : c.ink3)),
      ),
      content: Row(
        children: [
          Expanded(
            child: Text(row.nickname,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
          if (row.team != null) SikpanBadge(row.team!),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${row.points}',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: c.ink,
                  fontFeatures: const [FontFeature.tabularFigures()])),
          const SizedBox(width: 10),
          SizedBox(
            width: 44,
            child: Text(row.streak > 0 ? '🔥${row.streak}' : '${row.loggedDays}일',
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 12.5, color: c.ink3)),
          ),
        ],
      ),
    );
  }
}
