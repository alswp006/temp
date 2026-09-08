import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../app_state.dart';
import '../theme/tokens.dart';
import '../ui/labels.dart';
import '../ui/widgets.dart';

/// 누가 내 기록을 건드렸는지.
///
/// 대리 기록을 허용하는 제품에서 이 화면은 부가 기능이 아니라 전제 조건입니다.
/// 그런데 예전에는 "홍길동님이 식사를(를) 고침" 같은 문장이 같은 굵기로 쌓여
/// 있을 뿐이라, **누가·무엇을·언제**라는 세 가지가 한 덩어리로 뭉개졌습니다.
///
/// 이제 셋을 각각 다른 수단으로 냅니다. 행위자는 색이 붙은 이니셜 원으로,
/// 행동은 색과 아이콘을 가진 알약으로, 시각은 날짜별로 묶은 뒤 줄 오른쪽에
/// 시간만 남깁니다. 훑어보다가 "어제 저 사람이 뭘 지웠지"가 바로 걸립니다.
class AuditScreen extends StatefulWidget {
  const AuditScreen({super.key});

  @override
  State<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends State<AuditScreen>
    with DataListener<AuditScreen> {
  List<AuditEntry> _rows = const [];
  bool _loading = true;

  /// 비어 있는 것과 못 불러온 것은 다른 상황입니다. 같은 빈 화면으로 보여 주면
  /// 사용자는 "정말 없는 건가"를 확인할 방법이 없습니다.
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 대리 기록도 결국 데이터 변경이라, [DataBus]가 울리면 같이 갱신합니다.
  @override
  Future<void> reload() => _load();

  Future<void> _load() async {
    // 의존성은 첫 await 전에 잡아 둡니다.
    final scope = AppScope.of(context);
    try {
      final list = (await scope.api.get('/audit-log') as List)
          .map((e) => AuditEntry.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() {
        _rows = list;
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

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('변경 이력',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
            Text('누가 내 기록을 건드렸는지',
                style: TextStyle(fontSize: 12, color: c.ink3)),
          ],
        ),
        toolbarHeight: 64,
      ),
      body: _loading && _rows.isEmpty
          ? const _AuditSkeleton()
          : ScreenBody(onRefresh: _load, children: _body(context)),
    );
  }

  List<Widget> _body(BuildContext context) {
    final c = context.c;

    if (_rows.isEmpty) {
      return [
        SikpanCard(
          hero: true,
          padding: const EdgeInsets.fromLTRB(Dim.s20, Dim.s24, Dim.s20, Dim.s24),
          child: _failed
              ? EmptyState(
                  '연결을 확인하고 다시 시도해 주세요.',
                  icon: Icons.cloud_off_rounded,
                  title: '불러오지 못했습니다',
                  action: '다시 시도',
                  onAction: _load,
                )
              : EmptyState(
                  '멘토가 내 식단이나 운동을 대신 기록하면\n누가·무엇을·언제 했는지 여기에 남습니다.',
                  icon: Icons.verified_user_outlined,
                  title: '아직 대리 기록이 없습니다',
                  action: '새로고침',
                  onAction: _load,
                ),
        ),
      ];
    }

    final groups = _groupByDay(_rows);
    final actors = _countBy(_rows, (e) => e.actorName ?? _unknownActor);
    final actions = _countBy(_rows, (e) => e.action);
    final latest = groups.first.entries.first.createdAt;
    final todayCount =
        _isSameDay(groups.first.day, _todayStart()) ? groups.first.entries.length : 0;

    return [
      // --- 요약 (히어로) ---------------------------------------------------
      //
      // 목록만 있으면 "많은지 적은지"를 세어야 압니다. 총량·행위자 수·최근
      // 시각을 위에 두면, 아래 목록은 확인용이 됩니다.
      SikpanCard(
        hero: true,
        padding: const EdgeInsets.fromLTRB(Dim.s20, Dim.s24, Dim.s20, Dim.s20),
        child: Column(
          children: [
            AnimatedCount(
              _rows.length.toDouble(),
              style: TextStyle(
                fontSize: 44,
                fontWeight: FontWeight.w800,
                letterSpacing: -1.8,
                height: 1.05,
                color: c.ink,
              ),
              format: (v) => '${v.round()}건',
            ),
            const SizedBox(height: Dim.s4),
            Text('멘토가 대신 남긴 기록',
                style: TextStyle(fontSize: 13, color: c.ink3)),
            const SizedBox(height: Dim.s20),
            StatRow(children: [
              StatBlock(value: '${actors.length}명', label: '행위자'),
              StatBlock(value: _ago(latest), label: '최근'),
              StatBlock(value: '$todayCount건', label: '오늘'),
            ]),
            const SizedBox(height: Dim.s20),
            Divider(height: 1, color: c.lineSoft),
            const SizedBox(height: Dim.s16),
            Wrap(
              spacing: Dim.s6,
              runSpacing: Dim.s6,
              alignment: WrapAlignment.center,
              children: [
                for (final e in actions.entries)
                  _ActionPill(action: e.key, count: e.value),
              ],
            ),
          ],
        ),
      ),

      // --- 행위자별 --------------------------------------------------------
      //
      // 사람이 둘 이상일 때만 의미가 있습니다. 한 명뿐인데 100% 막대를 그리면
      // 화면만 길어집니다.
      if (actors.length >= 2)
        SikpanCard(
          title: '행위자별',
          subtitle: '누가 얼마나 손댔는지',
          icon: Icons.groups_outlined,
          child: Column(
            children: [
              for (final e in actors.entries)
                _ActorShare(
                  name: e.key,
                  count: e.value,
                  total: _rows.length,
                ),
            ],
          ),
        ),

      // --- 날짜별 타임라인 --------------------------------------------------
      //
      // 줄마다 '8월 13일 오후 12:02'를 반복하면 같은 글자가 세로로 쌓여 시각
      // 차이가 오히려 안 보입니다. 날짜는 구역 제목으로 한 번만 쓰고, 줄에는
      // 시간만 남깁니다.
      for (final g in groups)
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader('${_dayLabel(g.day)} · ${g.entries.length}건'),
            SikpanCard(
              padding: const EdgeInsets.fromLTRB(
                  Dim.s16, Dim.s4, Dim.s16, Dim.s4),
              child: Column(
                children: [
                  for (var i = 0; i < g.entries.length; i++)
                    _AuditRow(
                      entry: g.entries[i],
                      showDivider: i != g.entries.length - 1,
                    ),
                ],
              ),
            ),
          ],
        ),

      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Dim.s4),
        child: Text(
          '권한을 꺼도 지금까지 남은 이력은 그대로 남습니다.',
          style: TextStyle(fontSize: 12, color: c.ink3, height: 1.5),
        ),
      ),
    ];
  }
}

// =============================================================================
// 로딩
// =============================================================================

/// 가운데 스피너는 레이아웃을 알려주지 않아 내용이 도착할 때 화면이 통째로
/// 튑니다. 올 자리를 미리 그려 둡니다.
class _AuditSkeleton extends StatelessWidget {
  const _AuditSkeleton();

  @override
  Widget build(BuildContext context) {
    return const ScreenBody(
      animate: false,
      children: [
        SikpanCard(
          hero: true,
          padding: EdgeInsets.fromLTRB(Dim.s20, Dim.s24, Dim.s20, Dim.s20),
          child: Column(
            children: [
              Skeleton(width: 120, height: 40),
              SizedBox(height: Dim.s20),
              Skeleton(height: 44, radius: Dim.radiusSm),
            ],
          ),
        ),
        SikpanCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Skeleton(width: 90, height: 12),
              SizedBox(height: Dim.s20),
              Skeleton(height: 40, radius: Dim.radiusSm),
              SizedBox(height: Dim.s12),
              Skeleton(height: 40, radius: Dim.radiusSm),
              SizedBox(height: Dim.s12),
              Skeleton(height: 40, radius: Dim.radiusSm),
            ],
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// 한 줄
// =============================================================================

class _AuditRow extends StatelessWidget {
  const _AuditRow({required this.entry, required this.showDivider});

  final AuditEntry entry;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final actor = entry.actorName ?? _unknownActor;
    final ent = _entityMeta(entry.entity);

    return ListRow(
      showDivider: showDivider,
      leading: _ActorAvatar(name: actor),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  actor,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: Dim.s8),
              _ActionPill(action: entry.action),
            ],
          ),
          const SizedBox(height: Dim.s4),
          Row(
            children: [
              Icon(ent.icon, size: 13, color: c.ink3),
              const SizedBox(width: Dim.s6),
              Flexible(
                child: Text(
                  ent.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: c.ink2),
                ),
              ),
            ],
          ),
        ],
      ),
      trailing: Text(
        Fmt.time(entry.createdAt),
        style: TextStyle(
          fontSize: 12,
          color: c.ink3,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// 행동 알약.
///
/// 색만으로 구분하면 색각 이상에서 '고침'과 '지움'이 같아 보입니다. 아이콘을
/// 함께 실어 형태로도 갈라 둡니다.
class _ActionPill extends StatelessWidget {
  const _ActionPill({required this.action, this.count});

  final String action;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final m = _actionMeta(context, action);
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: Dim.s8, vertical: Dim.s4),
      decoration: BoxDecoration(
        color: m.color.withValues(alpha: c.isDark ? 0.18 : 0.11),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(m.icon, size: 12.5, color: m.color),
          const SizedBox(width: Dim.s4),
          Text(
            count == null ? m.label : '${m.label} $count',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.1,
              color: m.color,
            ),
          ),
        ],
      ),
    );
  }
}

/// 이니셜 원.
///
/// 이름을 읽지 않아도 색과 글자 모양으로 "또 저 사람"이 잡힙니다. 색은 이름에서
/// 결정론적으로 뽑아 매번 같은 사람이 같은 색을 갖습니다.
class _ActorAvatar extends StatelessWidget {
  const _ActorAvatar({required this.name, this.size = 38});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final color = _actorColor(context, name);
    final trimmed = name.trim();
    final initial = trimmed.isEmpty ? '?' : trimmed[0].toUpperCase();

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: c.isDark ? 0.20 : 0.13),
        shape: BoxShape.circle,
      ),
      child: Text(
        initial,
        style: TextStyle(
          fontSize: size * 0.42,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

/// 행위자별 비중 한 줄.
class _ActorShare extends StatelessWidget {
  const _ActorShare({
    required this.name,
    required this.count,
    required this.total,
  });

  final String name;
  final int count;
  final int total;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final color = _actorColor(context, name);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Dim.s8),
      child: Row(
        children: [
          _ActorAvatar(name: name, size: 30),
          const SizedBox(width: Dim.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                    ),
                    Text(
                      '$count건',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: c.ink2,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Dim.s6),
                Meter(
                  value: count.toDouble(),
                  target: total.toDouble(),
                  warnOver: false,
                  height: 6,
                  color: color,
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
// 라벨·색·묶음
// =============================================================================

const _unknownActor = '알 수 없는 사용자';

/// 행동. 라벨은 예전 것을 그대로 두고 아이콘과 색만 붙였습니다.
({String label, IconData icon, Color color}) _actionMeta(
    BuildContext context, String action) {
  final c = context.c;
  return switch (action) {
    'create' => (label: '만듦', icon: Icons.add_rounded, color: c.accent),
    'update' => (label: '고침', icon: Icons.edit_outlined, color: c.warn),
    'delete' => (
        label: '지움',
        icon: Icons.delete_outline_rounded,
        color: c.danger
      ),
    'grant' => (label: '권한 부여', icon: Icons.key_rounded, color: c.protein),
    _ => (label: action, icon: Icons.bolt_rounded, color: c.ink2),
  };
}

/// 대상.
({String label, IconData icon}) _entityMeta(String entity) {
  return switch (entity) {
    'meal' => (label: '식사', icon: Icons.restaurant_rounded),
    'workout' => (label: '운동', icon: Icons.fitness_center_rounded),
    'mentorship' => (label: '연결', icon: Icons.link_rounded),
    'mentorship_permissions' => (label: '연결 권한', icon: Icons.shield_outlined),
    'target' => (label: '목표', icon: Icons.flag_outlined),
    _ => (label: entity, icon: Icons.description_outlined),
  };
}

/// 이름 → 색. 실행할 때마다 달라지면 "그 사람은 보라색"이라는 기억이 깨지므로
/// `hashCode` 대신 직접 셈합니다.
Color _actorColor(BuildContext context, String name) {
  final c = context.c;
  if (name.isEmpty || name == _unknownActor) return c.ink3;
  final palette = [c.accent, c.protein, c.carb, c.fat, c.warn];
  var h = 0;
  for (final u in name.codeUnits) {
    h = (h * 31 + u) & 0x7fffffff;
  }
  return palette[h % palette.length];
}

class _DayGroup {
  _DayGroup(this.day, this.entries);
  final DateTime day;
  final List<AuditEntry> entries;
}

DateTime _todayStart() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

bool _isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 최신순으로 세운 뒤 날짜별로 묶습니다. 서버 순서에 기대지 않습니다 — 순서가
/// 어긋나면 같은 날이 두 덩어리로 갈라져 보입니다.
List<_DayGroup> _groupByDay(List<AuditEntry> rows) {
  final sorted = [...rows]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  final out = <_DayGroup>[];
  for (final e in sorted) {
    if (out.isEmpty || !_isSameDay(out.last.day, e.createdAt)) {
      out.add(_DayGroup(
        DateTime(e.createdAt.year, e.createdAt.month, e.createdAt.day),
        [e],
      ));
    } else {
      out.last.entries.add(e);
    }
  }
  return out;
}

/// 많은 순으로 센 결과.
Map<String, int> _countBy(
    List<AuditEntry> rows, String Function(AuditEntry) key) {
  final counts = <String, int>{};
  for (final e in rows) {
    final k = key(e);
    counts[k] = (counts[k] ?? 0) + 1;
  }
  final sorted = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return {for (final e in sorted) e.key: e.value};
}

String _dayLabel(DateTime day) {
  final today = _todayStart();
  final diff = today.difference(day).inDays;
  if (diff == 0) return '오늘';
  if (diff == 1) return '어제';
  const wd = ['월', '화', '수', '목', '금', '토', '일'];
  return '${day.month}월 ${day.day}일 (${wd[day.weekday - 1]})';
}

/// '3시간 전'. 요약에서는 정확한 시각보다 "얼마나 최근인가"가 먼저입니다.
String _ago(DateTime dt) {
  final d = DateTime.now().difference(dt);
  if (d.isNegative || d.inMinutes < 1) return '방금';
  if (d.inMinutes < 60) return '${d.inMinutes}분 전';
  if (d.inHours < 24) return '${d.inHours}시간 전';
  if (d.inDays < 7) return '${d.inDays}일 전';
  return '${d.inDays ~/ 7}주 전';
}
