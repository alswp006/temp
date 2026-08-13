/// 서버 응답 모델.
///
/// 필드 이름은 `app/schemas.py`와 1:1로 맞춰져 있습니다. 코드 생성 대신 손으로
/// 쓴 이유는, 스키마가 작고 안정적인 데다 생성기를 붙이면 빌드 단계가 하나 더
/// 늘기 때문입니다.
library;

double _d(Object? v) => (v as num?)?.toDouble() ?? 0;
double? _dn(Object? v) => (v as num?)?.toDouble();
int _i(Object? v) => (v as num?)?.toInt() ?? 0;

class User {
  User({
    required this.id,
    required this.email,
    required this.nickname,
    required this.sex,
    required this.heightCm,
    required this.birthYear,
    required this.goalType,
    required this.timezone,
    required this.plan,
  });

  final int id;
  final String email;
  final String nickname;
  final String sex;
  final double? heightCm;
  final int? birthYear;
  final String goalType;
  final String timezone;
  final String plan;

  factory User.fromJson(Map<String, dynamic> j) => User(
        id: _i(j['id']),
        email: j['email'] as String? ?? '',
        nickname: j['nickname'] as String? ?? '',
        sex: j['sex'] as String? ?? 'unspecified',
        heightCm: _dn(j['height_cm']),
        birthYear: (j['birth_year'] as num?)?.toInt(),
        goalType: j['goal_type'] as String? ?? 'maintain',
        timezone: j['timezone'] as String? ?? 'Asia/Seoul',
        plan: j['plan'] as String? ?? 'free',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'nickname': nickname,
        'sex': sex,
        'height_cm': heightCm,
        'birth_year': birthYear,
        'goal_type': goalType,
        'timezone': timezone,
        'plan': plan,
      };
}

class MealItem {
  MealItem({
    required this.id,
    required this.name,
    required this.category,
    required this.portionRatio,
    required this.finalG,
    required this.kcal,
    required this.proteinG,
    required this.carbG,
    required this.fatG,
    required this.confidence,
    required this.editedByUser,
  });

  final int id;
  final String name;
  final String category;
  final double portionRatio;
  final double finalG;
  final double kcal;
  final double proteinG;
  final double carbG;
  final double fatG;
  final double confidence;
  final bool editedByUser;

  factory MealItem.fromJson(Map<String, dynamic> j) => MealItem(
        id: _i(j['id']),
        name: j['name'] as String? ?? '',
        category: j['category'] as String? ?? 'main',
        portionRatio: _d(j['portion_ratio']),
        finalG: _d(j['final_g']),
        kcal: _d(j['kcal']),
        proteinG: _d(j['protein_g']),
        carbG: _d(j['carb_g']),
        fatG: _d(j['fat_g']),
        confidence: _d(j['confidence']),
        editedByUser: j['edited_by_user'] == true,
      );
}

class Meal {
  Meal({
    required this.id,
    required this.mealType,
    required this.status,
    required this.localDate,
    required this.shotAt,
    required this.kcal,
    required this.proteinG,
    required this.carbG,
    required this.fatG,
    required this.callsUsed,
    required this.cacheHit,
    required this.openMode,
    required this.error,
    required this.loggedByName,
    required this.photoPath,
    required this.items,
  });

  final int id;
  final String mealType;
  final String status;
  final String localDate;
  final DateTime shotAt;
  final double kcal;
  final double proteinG;
  final double carbG;
  final double fatG;
  final int callsUsed;
  final bool cacheHit;
  final bool openMode;
  final String? error;
  final String? loggedByName;
  final String? photoPath;
  final List<MealItem> items;

  bool get isReady => status == 'ready';
  bool get isFailed => status == 'failed';
  bool get isPending => status == 'pending' || status == 'analyzing';

  factory Meal.fromJson(Map<String, dynamic> j) => Meal(
        id: _i(j['id']),
        mealType: j['meal_type'] as String? ?? 'lunch',
        status: j['status'] as String? ?? 'pending',
        localDate: j['local_date'] as String? ?? '',
        shotAt:
            DateTime.tryParse(j['shot_at'] as String? ?? '')?.toLocal() ??
                DateTime.now(),
        kcal: _d(j['kcal']),
        proteinG: _d(j['protein_g']),
        carbG: _d(j['carb_g']),
        fatG: _d(j['fat_g']),
        callsUsed: _i(j['calls_used']),
        cacheHit: j['cache_hit'] == true,
        openMode: j['open_mode'] == true,
        error: j['error'] as String?,
        loggedByName: j['logged_by_name'] as String?,
        photoPath: j['photo_path'] as String?,
        items: ((j['items'] as List?) ?? const [])
            .map((e) => MealItem.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class DaySummary {
  DaySummary({
    required this.date,
    required this.kcal,
    required this.carbG,
    required this.proteinG,
    required this.fatG,
    required this.meals,
    required this.workouts,
    required this.targetKcal,
    required this.targetProteinG,
    required this.remainingKcal,
  });

  final String date;
  final double kcal;
  final double carbG;
  final double proteinG;
  final double fatG;
  final int meals;
  final int workouts;
  final double? targetKcal;
  final double? targetProteinG;
  final double? remainingKcal;

  factory DaySummary.fromJson(Map<String, dynamic> j) => DaySummary(
        date: j['date'] as String? ?? '',
        kcal: _d(j['kcal']),
        carbG: _d(j['carb_g']),
        proteinG: _d(j['protein_g']),
        fatG: _d(j['fat_g']),
        meals: _i(j['meals']),
        workouts: _i(j['workouts']),
        targetKcal: _dn(j['target_kcal']),
        targetProteinG: _dn(j['target_protein_g']),
        remainingKcal: _dn(j['remaining_kcal']),
      );
}

class QuickSet {
  QuickSet({required this.id, required this.name, required this.useCount});
  final int id;
  final String name;
  final int useCount;

  factory QuickSet.fromJson(Map<String, dynamic> j) => QuickSet(
        id: _i(j['id']),
        name: j['name'] as String? ?? '',
        useCount: _i(j['use_count']),
      );
}

class TodayView {
  TodayView({
    required this.summary,
    required this.meals,
    required this.quickSets,
    required this.pending,
  });

  final DaySummary summary;
  final List<Meal> meals;
  final List<QuickSet> quickSets;
  final int pending;

  factory TodayView.fromJson(Map<String, dynamic> j) => TodayView(
        summary:
            DaySummary.fromJson(j['summary'] as Map<String, dynamic>? ?? {}),
        meals: ((j['meals'] as List?) ?? const [])
            .map((e) => Meal.fromJson(e as Map<String, dynamic>))
            .toList(),
        quickSets: ((j['quick_sets'] as List?) ?? const [])
            .map((e) => QuickSet.fromJson(e as Map<String, dynamic>))
            .toList(),
        pending: _i(j['pending']),
      );
}

class WeeklyReport {
  WeeklyReport({
    required this.start,
    required this.end,
    required this.loggedDays,
    required this.totalEntries,
    required this.mealEntries,
    required this.workoutEntries,
    required this.avgKcal,
    required this.avgProteinG,
    required this.weightChangeKg,
    required this.estTdee,
    required this.targetKcal,
    required this.onTargetDays,
    required this.editRate,
    required this.menuCoverage,
    required this.delegatedRatio,
    required this.avgCallsPerMeal,
    required this.cacheHitRate,
    required this.days,
  });

  final String start;
  final String end;
  final int loggedDays;
  final int totalEntries;
  final int mealEntries;
  final int workoutEntries;
  final double avgKcal;
  final double avgProteinG;
  final double? weightChangeKg;
  final double? estTdee;
  final double? targetKcal;
  final int onTargetDays;
  final double editRate;
  final double menuCoverage;
  final double delegatedRatio;
  final double avgCallsPerMeal;
  final double cacheHitRate;
  final List<DaySummary> days;

  factory WeeklyReport.fromJson(Map<String, dynamic> j) => WeeklyReport(
        start: j['start'] as String? ?? '',
        end: j['end'] as String? ?? '',
        loggedDays: _i(j['logged_days']),
        totalEntries: _i(j['total_entries']),
        mealEntries: _i(j['meal_entries']),
        workoutEntries: _i(j['workout_entries']),
        avgKcal: _d(j['avg_kcal']),
        avgProteinG: _d(j['avg_protein_g']),
        weightChangeKg: _dn(j['weight_change_kg']),
        estTdee: _dn(j['est_tdee']),
        targetKcal: _dn(j['target_kcal']),
        onTargetDays: _i(j['on_target_days']),
        editRate: _d(j['edit_rate']),
        menuCoverage: _d(j['menu_coverage']),
        delegatedRatio: _d(j['delegated_ratio']),
        avgCallsPerMeal: _d(j['avg_calls_per_meal']),
        cacheHitRate: _d(j['cache_hit_rate']),
        days: ((j['days'] as List?) ?? const [])
            .map((e) => DaySummary.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class Canteen {
  Canteen({required this.id, required this.name, required this.joinCode});
  final int id;
  final String name;
  final String joinCode;

  factory Canteen.fromJson(Map<String, dynamic> j) => Canteen(
        id: _i(j['id']),
        name: j['name'] as String? ?? '',
        joinCode: j['join_code'] as String? ?? '',
      );
}

class MenuItem {
  MenuItem({
    required this.name,
    required this.category,
    required this.standardG,
    this.kcalPerServing,
    this.matchedFoodId,
  });

  final String name;
  final String category;
  final double standardG;
  final double? kcalPerServing;
  final int? matchedFoodId;

  factory MenuItem.fromJson(Map<String, dynamic> j) => MenuItem(
        name: j['name'] as String? ?? '',
        category: j['category'] as String? ?? 'main',
        standardG: _d(j['standard_g']),
        kcalPerServing: _dn(j['kcal_per_serving']),
        matchedFoodId: (j['matched_food_id'] as num?)?.toInt() ??
            (j['food_id'] as num?)?.toInt(),
      );

  Map<String, dynamic> toApplyJson() => {
        'name': name,
        'category': category,
        'standard_g': standardG,
        'kcal_per_serving': kcalPerServing,
        'food_id': matchedFoodId,
      };
}

class MenuPlan {
  MenuPlan({
    required this.id,
    required this.date,
    required this.mealType,
    required this.verified,
    required this.items,
  });

  final int id;
  final String date;
  final String mealType;
  final bool verified;
  final List<MenuItem> items;

  factory MenuPlan.fromJson(Map<String, dynamic> j) => MenuPlan(
        id: _i(j['id']),
        date: j['date'] as String? ?? '',
        mealType: j['meal_type'] as String? ?? 'lunch',
        verified: j['verified'] == true,
        items: ((j['items'] as List?) ?? const [])
            .map((e) => MenuItem.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class MenuDraftSlot {
  MenuDraftSlot({
    required this.date,
    required this.mealType,
    required this.items,
  });

  final String date;
  final String mealType;
  final List<MenuItem> items;

  factory MenuDraftSlot.fromJson(Map<String, dynamic> j) => MenuDraftSlot(
        date: j['date'] as String? ?? '',
        mealType: j['meal_type'] as String? ?? 'lunch',
        items: ((j['items'] as List?) ?? const [])
            .map((e) => MenuItem.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toApplyJson() => {
        'date': date,
        'meal_type': mealType,
        'items': items.map((i) => i.toApplyJson()).toList(),
      };
}

class Mentorship {
  Mentorship({
    required this.id,
    required this.mentorId,
    required this.menteeId,
    required this.type,
    required this.mentorName,
    required this.menteeName,
    required this.permissions,
  });

  final int id;
  final int mentorId;
  final int? menteeId;
  final String type;
  final String? mentorName;
  final String? menteeName;
  final Map<String, bool> permissions;

  factory Mentorship.fromJson(Map<String, dynamic> j) => Mentorship(
        id: _i(j['id']),
        mentorId: _i(j['mentor_id']),
        menteeId: (j['mentee_id'] as num?)?.toInt(),
        type: j['type'] as String? ?? 'peer',
        mentorName: j['mentor_name'] as String?,
        menteeName: j['mentee_name'] as String?,
        permissions: ((j['permissions'] as Map?) ?? const {})
            .map((k, v) => MapEntry('$k', v == true)),
      );
}

class InviteScope {
  InviteScope({
    required this.scope,
    required this.recommended,
    required this.isWrite,
  });
  final String scope;
  final bool recommended;
  final bool isWrite;

  factory InviteScope.fromJson(Map<String, dynamic> j) => InviteScope(
        scope: j['scope'] as String? ?? '',
        recommended: j['recommended'] == true,
        isWrite: j['is_write'] == true,
      );
}

class InvitePreview {
  InvitePreview({
    required this.mentorName,
    required this.type,
    required this.scopes,
    required this.notice,
  });

  final String? mentorName;
  final String type;
  final List<InviteScope> scopes;
  final String notice;

  factory InvitePreview.fromJson(Map<String, dynamic> j) => InvitePreview(
        mentorName: j['mentor_name'] as String?,
        type: j['type'] as String? ?? 'peer',
        scopes: ((j['scopes'] as List?) ?? const [])
            .map((e) => InviteScope.fromJson(e as Map<String, dynamic>))
            .toList(),
        notice: j['notice'] as String? ?? '',
      );
}

class MenteeCard {
  MenteeCard({
    required this.userId,
    required this.nickname,
    required this.staleDays,
    required this.weekCompletion,
    required this.mealsToday,
    required this.workoutsToday,
    required this.weightToday,
  });

  final int userId;
  final String nickname;
  final int staleDays;
  final double weekCompletion;
  final int? mealsToday;
  final int? workoutsToday;
  final bool? weightToday;

  factory MenteeCard.fromJson(Map<String, dynamic> j) => MenteeCard(
        userId: _i(j['user_id']),
        nickname: j['nickname'] as String? ?? '',
        staleDays: _i(j['stale_days']),
        weekCompletion: _d(j['week_completion']),
        mealsToday: (j['meals_today'] as num?)?.toInt(),
        workoutsToday: (j['workouts_today'] as num?)?.toInt(),
        weightToday: j['weight_today'] == null
            ? null
            : (j['weight_today'] is bool
                ? j['weight_today'] as bool
                : (j['weight_today'] as num) > 0),
      );
}

class Battle {
  Battle({
    required this.id,
    required this.name,
    required this.joinCode,
    required this.startDate,
    required this.endDate,
  });

  final int id;
  final String name;
  final String joinCode;
  final String startDate;
  final String endDate;

  factory Battle.fromJson(Map<String, dynamic> j) => Battle(
        id: _i(j['id']),
        name: j['name'] as String? ?? '',
        joinCode: j['join_code'] as String? ?? '',
        startDate: j['start_date'] as String? ?? '',
        endDate: j['end_date'] as String? ?? '',
      );
}

class LeaderboardRow {
  LeaderboardRow({
    required this.userId,
    required this.nickname,
    required this.team,
    required this.points,
    required this.loggedDays,
    required this.streak,
  });

  final int userId;
  final String nickname;
  final String? team;
  final int points;
  final int loggedDays;
  final int streak;

  factory LeaderboardRow.fromJson(Map<String, dynamic> j) => LeaderboardRow(
        userId: _i(j['user_id']),
        nickname: j['nickname'] as String? ?? '',
        team: j['team'] as String?,
        points: _i(j['points']),
        loggedDays: _i(j['logged_days']),
        streak: _i(j['streak']),
      );
}

class Target {
  Target({
    required this.id,
    required this.targetKcal,
    required this.targetProteinG,
    required this.estTdee,
    required this.pinned,
  });

  final int id;
  final double targetKcal;
  final double targetProteinG;
  final double? estTdee;
  final bool pinned;

  factory Target.fromJson(Map<String, dynamic> j) => Target(
        id: _i(j['id']),
        targetKcal: _d(j['target_kcal']),
        targetProteinG: _d(j['target_protein_g']),
        estTdee: _dn(j['est_tdee']),
        pinned: j['pinned'] == true,
      );
}

class WorkoutSet {
  WorkoutSet({
    required this.exerciseName,
    required this.weightKg,
    required this.reps,
  });

  final String exerciseName;
  final double? weightKg;
  final int? reps;

  factory WorkoutSet.fromJson(Map<String, dynamic> j) => WorkoutSet(
        exerciseName: j['exercise_name'] as String? ?? '',
        weightKg: _dn(j['weight_kg']),
        reps: (j['reps'] as num?)?.toInt(),
      );
}

class Workout {
  Workout({required this.id, required this.sets, required this.unmatched});
  final int id;
  final List<WorkoutSet> sets;
  final List<String> unmatched;

  factory Workout.fromJson(Map<String, dynamic> j) => Workout(
        id: _i(j['id']),
        sets: ((j['sets'] as List?) ?? const [])
            .map((e) => WorkoutSet.fromJson(e as Map<String, dynamic>))
            .toList(),
        unmatched: ((j['unmatched'] as List?) ?? const [])
            .map((e) => '$e')
            .toList(),
      );
}

class AppNotification {
  AppNotification({required this.title, required this.body});
  final String title;
  final String? body;

  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
        title: j['title'] as String? ?? '',
        body: j['body'] as String?,
      );
}

class AuditEntry {
  AuditEntry({
    required this.actorName,
    required this.action,
    required this.entity,
    required this.createdAt,
  });

  final String? actorName;
  final String action;
  final String entity;
  final DateTime createdAt;

  factory AuditEntry.fromJson(Map<String, dynamic> j) => AuditEntry(
        actorName: j['actor_name'] as String?,
        action: j['action'] as String? ?? '',
        entity: j['entity'] as String? ?? '',
        createdAt:
            DateTime.tryParse(j['created_at'] as String? ?? '')?.toLocal() ??
                DateTime.now(),
      );
}

class EditResult {
  EditResult({required this.action, required this.message});
  final String action;
  final String message;

  bool get changed => action != 'none';

  factory EditResult.fromJson(Map<String, dynamic> j) => EditResult(
        action: j['action'] as String? ?? 'none',
        message: j['message'] as String? ?? '',
      );
}
