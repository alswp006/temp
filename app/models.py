"""Database models.

Two invariants run through this schema and are load-bearing for the product:

1. Every user-owned record carries ``logged_by`` — who actually wrote it. A
   coach writing a mentee's workout is a first-class case, not an edge case,
   and the UI must be able to say "코치 김OO가 기록함".
2. Every third-party write leaves an :class:`AuditLog` row the mentee can read.
"""

from __future__ import annotations

import enum
from datetime import date as Date
from datetime import datetime, timezone

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    Date as SADate,
    DateTime as SADateTime,
    Float,
    ForeignKey,
    Index,
    Integer,
    JSON,
    String,
    Text,
    TypeDecorator,
    UniqueConstraint,
    func,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


class UTCDateTime(TypeDecorator):
    """Timezone-aware datetimes that survive SQLite.

    Postgres stores ``timestamptz`` and hands back aware datetimes; SQLite has
    no timezone type and silently returns naive ones. Comparing the two raises
    ``TypeError`` at runtime, in whichever code path happens to mix them — so
    normalise at the boundary instead: everything goes in as UTC and comes back
    as UTC-aware, on every backend.
    """

    impl = SADateTime(timezone=True)
    cache_ok = True

    def process_bind_param(self, value: datetime | None, dialect):
        if value is None:
            return None
        if value.tzinfo is None:
            value = value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc)

    def process_result_value(self, value: datetime | None, dialect):
        if value is None:
            return None
        if value.tzinfo is None:
            return value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc)


class EnumStr(TypeDecorator):
    """Store a Python enum as its ``value`` string, and hand back the *enum*.

    A plain ``String`` column annotated ``Mapped[SomeEnum]`` writes fine (our
    enums subclass ``str``) but reads back as a bare ``str`` — so ``.value``
    raises and ``is SomeEnum.X`` is silently False. Round-tripping through the
    enum class here keeps every read site honest.

    Deliberately not ``sqlalchemy.Enum``: no native DB enum type means adding a
    member is a code change, not a migration.
    """

    impl = String
    cache_ok = True

    def __init__(self, enum_cls, length: int = 32, **kw):
        self.enum_cls = enum_cls
        super().__init__(length=length, **kw)

    def process_bind_param(self, value, dialect):
        if value is None:
            return None
        if isinstance(value, self.enum_cls):
            return value.value
        return self.enum_cls(value).value

    def process_result_value(self, value, dialect):
        if value is None:
            return None
        return self.enum_cls(value)


# Alias so the column declarations below read naturally.
DateTime = UTCDateTime


class Base(DeclarativeBase):
    type_annotation_map = {dict: JSON, list: JSON}


def _utcnow_col() -> Mapped[datetime]:
    return mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)


# --------------------------------------------------------------------------
# Enumerations
# --------------------------------------------------------------------------


class MealType(str, enum.Enum):
    BREAKFAST = "breakfast"
    LUNCH = "lunch"
    DINNER = "dinner"
    SNACK = "snack"


class FoodCategory(str, enum.Enum):
    """Fixed six-way split from the spec. Calibration multipliers key on this."""

    RICE = "rice"          # 밥
    SOUP = "soup"          # 국·찌개
    MAIN = "main"          # 주찬
    SIDE = "side"          # 부찬
    KIMCHI = "kimchi"      # 김치
    DESSERT = "dessert"    # 후식


class MealStatus(str, enum.Enum):
    PENDING = "pending"
    ANALYZING = "analyzing"
    READY = "ready"
    FAILED = "failed"


class EntrySource(str, enum.Enum):
    PHOTO = "photo"
    MEAL_SET = "meal_set"
    MANUAL = "manual"
    VOICE = "voice"
    TEXT = "text"


class GoalType(str, enum.Enum):
    LOSE = "lose"
    MAINTAIN = "maintain"
    GAIN = "gain"


class Sex(str, enum.Enum):
    MALE = "male"
    FEMALE = "female"
    UNSPECIFIED = "unspecified"


class MembershipRole(str, enum.Enum):
    OWNER = "owner"
    MEMBER = "member"


class MentorType(str, enum.Enum):
    COACH = "coach"   # 유료. 시트 단위 과금
    PEER = "peer"     # 무료, 최대 2명


class MentorshipStatus(str, enum.Enum):
    PENDING = "pending"
    ACTIVE = "active"
    DECLINED = "declined"
    ENDED = "ended"


class Scope(str, enum.Enum):
    """Permission scopes a mentee may grant a mentor.

    There is deliberately no ``WEIGHT_WRITE``. Weight is the one thing nobody
    can record on your behalf — see :mod:`app.services.permissions`.
    """

    DIET_READ = "diet:read"
    DIET_WRITE = "diet:write"
    WORKOUT_READ = "workout:read"
    WORKOUT_WRITE = "workout:write"
    WEIGHT_READ = "weight:read"
    PHOTO_READ = "photo:read"
    GOAL_PROPOSE = "goal:propose"


class BattleMode(str, enum.Enum):
    LEAGUE = "league"
    DUEL = "duel"
    TEAM = "team"


class BattleStatus(str, enum.Enum):
    OPEN = "open"
    RUNNING = "running"
    FINISHED = "finished"


class JobStatus(str, enum.Enum):
    QUEUED = "queued"
    RUNNING = "running"
    DONE = "done"
    FAILED = "failed"


class PlanTier(str, enum.Enum):
    FREE = "free"
    PLUS = "plus"
    COACH = "coach"
    COACH_PRO = "coach_pro"


# --------------------------------------------------------------------------
# Identity
# --------------------------------------------------------------------------


class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(primary_key=True)
    email: Mapped[str] = mapped_column(String(320), unique=True, index=True)
    nickname: Mapped[str] = mapped_column(String(40))
    sex: Mapped[Sex] = mapped_column(EnumStr(Sex, 16), default=Sex.UNSPECIFIED)
    height_cm: Mapped[float | None] = mapped_column(Float)
    birth_year: Mapped[int | None] = mapped_column(Integer)
    goal_type: Mapped[GoalType] = mapped_column(EnumStr(GoalType, 16), default=GoalType.MAINTAIN)
    activity_factor: Mapped[float] = mapped_column(Float, default=1.45)
    timezone: Mapped[str] = mapped_column(String(64), default="Asia/Seoul")
    plan: Mapped[PlanTier] = mapped_column(EnumStr(PlanTier, 16), default=PlanTier.FREE)
    # Bound by sending an ingest token to the bot; see app/integrations/telegram.py.
    telegram_chat_id: Mapped[str | None] = mapped_column(
        String(32), unique=True, index=True
    )
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = _utcnow_col()

    memberships: Mapped[list["Membership"]] = relationship(
        back_populates="user", cascade="all, delete-orphan"
    )


class LoginCode(Base):
    """Single-use magic-link code. Stored hashed; the plaintext only ever
    leaves through email (or the dev response)."""

    __tablename__ = "login_codes"

    id: Mapped[int] = mapped_column(primary_key=True)
    email: Mapped[str] = mapped_column(String(320), index=True)
    code_hash: Mapped[str] = mapped_column(String(255))
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    consumed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = _utcnow_col()


class ApiToken(Base):
    """Long-lived ingest token for the iOS Shortcut / Telegram bridge.

    Shown once at creation, stored as an argon2 hash. ``prefix`` is the
    non-secret leading segment so we can look up a candidate row cheaply
    instead of hashing against every token in the table.
    """

    __tablename__ = "api_tokens"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    name: Mapped[str] = mapped_column(String(80))
    prefix: Mapped[str] = mapped_column(String(16), index=True)
    token_hash: Mapped[str] = mapped_column(String(255))
    last_used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = _utcnow_col()


# --------------------------------------------------------------------------
# Canteens ("내 식사 세트"의 출처) and menu plans
# --------------------------------------------------------------------------


class Canteen(Base):
    """A place with a repeating menu: 생활관/구내식당/학식/집밥 루틴/단골집."""

    __tablename__ = "canteens"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(80))
    owner_user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    join_code: Mapped[str] = mapped_column(String(12), unique=True, index=True)
    is_public: Mapped[bool] = mapped_column(Boolean, default=False)
    timezone: Mapped[str] = mapped_column(String(64), default="Asia/Seoul")
    created_at: Mapped[datetime] = _utcnow_col()

    memberships: Mapped[list["Membership"]] = relationship(
        back_populates="canteen", cascade="all, delete-orphan"
    )


class Membership(Base):
    __tablename__ = "memberships"
    __table_args__ = (UniqueConstraint("user_id", "canteen_id", name="uq_membership"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    canteen_id: Mapped[int] = mapped_column(
        ForeignKey("canteens.id", ondelete="CASCADE"), index=True
    )
    role: Mapped[MembershipRole] = mapped_column(EnumStr(MembershipRole, 16), default=MembershipRole.MEMBER)
    joined_at: Mapped[datetime] = _utcnow_col()

    user: Mapped[User] = relationship(back_populates="memberships")
    canteen: Mapped[Canteen] = relationship(back_populates="memberships")


class MenuPlan(Base):
    """One canteen + date + meal slot. The candidate list that turns photo
    recognition from an open problem into a multiple-choice one."""

    __tablename__ = "menu_plans"
    __table_args__ = (
        UniqueConstraint("canteen_id", "date", "meal_type", name="uq_menu_plan_slot"),
        Index("ix_menu_plan_lookup", "canteen_id", "date", "meal_type"),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    canteen_id: Mapped[int] = mapped_column(ForeignKey("canteens.id", ondelete="CASCADE"))
    date: Mapped[Date] = mapped_column(SADate)
    meal_type: Mapped[MealType] = mapped_column(EnumStr(MealType, 16))
    source: Mapped[str] = mapped_column(String(24), default="photo")  # photo | manual | import
    created_by: Mapped[int | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL"))
    verified: Mapped[bool] = mapped_column(Boolean, default=False)
    photo_path: Mapped[str | None] = mapped_column(String(512))
    created_at: Mapped[datetime] = _utcnow_col()

    items: Mapped[list["MenuItem"]] = relationship(
        back_populates="plan",
        cascade="all, delete-orphan",
        order_by="MenuItem.position",
        lazy="selectin",
    )


class MenuItem(Base):
    __tablename__ = "menu_items"

    id: Mapped[int] = mapped_column(primary_key=True)
    menu_plan_id: Mapped[int] = mapped_column(
        ForeignKey("menu_plans.id", ondelete="CASCADE"), index=True
    )
    name: Mapped[str] = mapped_column(String(120))
    category: Mapped[FoodCategory] = mapped_column(EnumStr(FoodCategory, 16), default=FoodCategory.SIDE)
    standard_g: Mapped[float] = mapped_column(Float, default=100.0)
    kcal_per_serving: Mapped[float | None] = mapped_column(Float)
    food_id: Mapped[int | None] = mapped_column(ForeignKey("foods.id", ondelete="SET NULL"))
    position: Mapped[int] = mapped_column(Integer, default=0)

    plan: Mapped[MenuPlan] = relationship(back_populates="items")
    food: Mapped["Food | None"] = relationship()


class MenuReport(Base):
    """'메뉴 틀림' 신고. 2명 이상 동의하면 재파싱한다."""

    __tablename__ = "menu_reports"
    __table_args__ = (UniqueConstraint("menu_plan_id", "user_id", name="uq_menu_report"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    menu_plan_id: Mapped[int] = mapped_column(
        ForeignKey("menu_plans.id", ondelete="CASCADE"), index=True
    )
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    note: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = _utcnow_col()


# --------------------------------------------------------------------------
# Nutrition reference data
# --------------------------------------------------------------------------


class Food(Base):
    """Per-100g nutrition. Seeded from a bundled starter table; replaceable
    wholesale by the 식약처 식품영양성분 통합 DB importer."""

    __tablename__ = "foods"
    __table_args__ = (Index("ix_foods_name_norm", "name_norm"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    code: Mapped[str | None] = mapped_column(String(40), index=True)
    name: Mapped[str] = mapped_column(String(160))
    name_norm: Mapped[str] = mapped_column(String(160))
    category: Mapped[FoodCategory] = mapped_column(EnumStr(FoodCategory, 16), default=FoodCategory.SIDE)
    kcal_100g: Mapped[float] = mapped_column(Float)
    carb_100g: Mapped[float] = mapped_column(Float, default=0.0)
    protein_100g: Mapped[float] = mapped_column(Float, default=0.0)
    fat_100g: Mapped[float] = mapped_column(Float, default=0.0)
    sodium_mg_100g: Mapped[float | None] = mapped_column(Float)
    default_serving_g: Mapped[float] = mapped_column(Float, default=100.0)
    source: Mapped[str] = mapped_column(String(40), default="seed")

    aliases: Mapped[list["FoodAlias"]] = relationship(
        back_populates="food", cascade="all, delete-orphan"
    )


class FoodAlias(Base):
    __tablename__ = "food_aliases"
    __table_args__ = (Index("ix_food_alias_norm", "alias_norm"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    food_id: Mapped[int] = mapped_column(ForeignKey("foods.id", ondelete="CASCADE"))
    alias: Mapped[str] = mapped_column(String(160))
    alias_norm: Mapped[str] = mapped_column(String(160))

    food: Mapped[Food] = relationship(back_populates="aliases")


class Exercise(Base):
    __tablename__ = "exercises"
    __table_args__ = (Index("ix_exercise_name_norm", "name_norm"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(120))
    name_norm: Mapped[str] = mapped_column(String(120))
    body_part: Mapped[str] = mapped_column(String(40), default="etc")
    equipment: Mapped[str] = mapped_column(String(40), default="etc")
    met_value: Mapped[float] = mapped_column(Float, default=5.0)

    aliases: Mapped[list["ExerciseAlias"]] = relationship(
        back_populates="exercise", cascade="all, delete-orphan"
    )


class ExerciseAlias(Base):
    __tablename__ = "exercise_aliases"
    __table_args__ = (Index("ix_exercise_alias_norm", "alias_norm"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    exercise_id: Mapped[int] = mapped_column(ForeignKey("exercises.id", ondelete="CASCADE"))
    alias: Mapped[str] = mapped_column(String(120))
    alias_norm: Mapped[str] = mapped_column(String(120))
    # Learned aliases come from a user confirming an unmatched name.
    learned: Mapped[bool] = mapped_column(Boolean, default=False)

    exercise: Mapped[Exercise] = relationship(back_populates="aliases")


# --------------------------------------------------------------------------
# Meals
# --------------------------------------------------------------------------


class Meal(Base):
    __tablename__ = "meals"
    __table_args__ = (Index("ix_meals_user_date", "user_id", "local_date"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    canteen_id: Mapped[int | None] = mapped_column(ForeignKey("canteens.id", ondelete="SET NULL"))
    shot_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    local_date: Mapped[Date] = mapped_column(SADate, index=True)
    meal_type: Mapped[MealType] = mapped_column(EnumStr(MealType, 16))
    photo_path: Mapped[str | None] = mapped_column(String(512))
    status: Mapped[MealStatus] = mapped_column(EnumStr(MealStatus, 16), default=MealStatus.PENDING)
    source: Mapped[EntrySource] = mapped_column(EnumStr(EntrySource, 16), default=EntrySource.PHOTO)
    # Who physically created this record (mentee themself, or a coach).
    logged_by: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    calls_used: Mapped[int] = mapped_column(Integer, default=0)
    cache_hit: Mapped[bool] = mapped_column(Boolean, default=False)
    open_mode: Mapped[bool] = mapped_column(Boolean, default=False)  # 식단표 없이 인식
    note: Mapped[str | None] = mapped_column(Text)
    error: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = _utcnow_col()
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    items: Mapped[list["MealItem"]] = relationship(
        back_populates="meal", cascade="all, delete-orphan", lazy="selectin"
    )

    # --- derived totals ---------------------------------------------------
    @property
    def kcal(self) -> float:
        return round(sum(i.kcal for i in self.items), 1)

    @property
    def protein_g(self) -> float:
        return round(sum(i.protein_g for i in self.items), 1)

    @property
    def carb_g(self) -> float:
        return round(sum(i.carb_g for i in self.items), 1)

    @property
    def fat_g(self) -> float:
        return round(sum(i.fat_g for i in self.items), 1)


class MealItem(Base):
    __tablename__ = "meal_items"

    id: Mapped[int] = mapped_column(primary_key=True)
    meal_id: Mapped[int] = mapped_column(ForeignKey("meals.id", ondelete="CASCADE"), index=True)
    menu_item_id: Mapped[int | None] = mapped_column(
        ForeignKey("menu_items.id", ondelete="SET NULL")
    )
    food_id: Mapped[int | None] = mapped_column(ForeignKey("foods.id", ondelete="SET NULL"))
    name: Mapped[str] = mapped_column(String(160))
    category: Mapped[FoodCategory] = mapped_column(EnumStr(FoodCategory, 16), default=FoodCategory.SIDE)
    portion_ratio: Mapped[float] = mapped_column(Float, default=1.0)
    final_g: Mapped[float] = mapped_column(Float, default=0.0)
    kcal: Mapped[float] = mapped_column(Float, default=0.0)
    carb_g: Mapped[float] = mapped_column(Float, default=0.0)
    protein_g: Mapped[float] = mapped_column(Float, default=0.0)
    fat_g: Mapped[float] = mapped_column(Float, default=0.0)
    confidence: Mapped[float] = mapped_column(Float, default=1.0)
    edited_by_user: Mapped[bool] = mapped_column(Boolean, default=False)

    meal: Mapped[Meal] = relationship(back_populates="items")


class MealSet(Base):
    """'내 식사 세트' — 두 번째부터 1탭.

    ``payload`` holds a denormalised item list so a set survives the deletion
    of the meal it was created from.
    """

    __tablename__ = "meal_sets"
    __table_args__ = (UniqueConstraint("user_id", "name", name="uq_meal_set_name"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    name: Mapped[str] = mapped_column(String(80))
    source_meal_id: Mapped[int | None] = mapped_column(ForeignKey("meals.id", ondelete="SET NULL"))
    default_meal_type: Mapped[MealType | None] = mapped_column(EnumStr(MealType, 16))
    payload: Mapped[dict] = mapped_column(JSON, default=dict)
    use_count: Mapped[int] = mapped_column(Integer, default=0)
    last_used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = _utcnow_col()


class RecognitionBaseline(Base):
    """Phase-3 cost architecture, built in from day one.

    The first user to shoot a given (canteen, date, meal) slot pays K=5 calls
    and stores the resulting per-item portion interpretation here. Everyone
    after them pays K=1 and only escalates on disagreement.
    """

    __tablename__ = "recognition_baselines"
    __table_args__ = (
        UniqueConstraint(
            "canteen_id", "date", "meal_type", "menu_item_id", name="uq_baseline_item"
        ),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    canteen_id: Mapped[int] = mapped_column(ForeignKey("canteens.id", ondelete="CASCADE"))
    date: Mapped[Date] = mapped_column(SADate)
    meal_type: Mapped[MealType] = mapped_column(EnumStr(MealType, 16))
    menu_item_id: Mapped[int] = mapped_column(ForeignKey("menu_items.id", ondelete="CASCADE"))
    portion_ratio: Mapped[float] = mapped_column(Float)
    detect_rate: Mapped[float] = mapped_column(Float, default=1.0)
    sample_n: Mapped[int] = mapped_column(Integer, default=1)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class Calibration(Base):
    """Per-user, per-category multiplier learned from 2주 저울 캘리브레이션."""

    __tablename__ = "calibrations"
    __table_args__ = (UniqueConstraint("user_id", "category", name="uq_calibration"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    category: Mapped[FoodCategory] = mapped_column(EnumStr(FoodCategory, 16))
    multiplier: Mapped[float] = mapped_column(Float, default=1.0)
    sample_n: Mapped[int] = mapped_column(Integer, default=0)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class CalibrationSample(Base):
    """One (estimated_g, actual_g) pair from the scale-calibration period."""

    __tablename__ = "calibration_samples"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    meal_item_id: Mapped[int | None] = mapped_column(
        ForeignKey("meal_items.id", ondelete="SET NULL")
    )
    category: Mapped[FoodCategory] = mapped_column(EnumStr(FoodCategory, 16))
    estimated_g: Mapped[float] = mapped_column(Float)
    actual_g: Mapped[float] = mapped_column(Float)
    created_at: Mapped[datetime] = _utcnow_col()


# --------------------------------------------------------------------------
# Workouts
# --------------------------------------------------------------------------


class Workout(Base):
    __tablename__ = "workouts"
    __table_args__ = (Index("ix_workouts_user_date", "user_id", "local_date"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    performed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    local_date: Mapped[Date] = mapped_column(SADate, index=True)
    session_note: Mapped[str | None] = mapped_column(Text)
    logged_by: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    source: Mapped[EntrySource] = mapped_column(EnumStr(EntrySource, 16), default=EntrySource.MANUAL)
    photo_path: Mapped[str | None] = mapped_column(String(512))
    unmatched: Mapped[list] = mapped_column(JSON, default=list)
    created_at: Mapped[datetime] = _utcnow_col()

    sets: Mapped[list["WorkoutSet"]] = relationship(
        back_populates="workout",
        cascade="all, delete-orphan",
        order_by="WorkoutSet.id",
        lazy="selectin",
    )


class WorkoutSet(Base):
    __tablename__ = "workout_sets"

    id: Mapped[int] = mapped_column(primary_key=True)
    workout_id: Mapped[int] = mapped_column(
        ForeignKey("workouts.id", ondelete="CASCADE"), index=True
    )
    exercise_id: Mapped[int | None] = mapped_column(
        ForeignKey("exercises.id", ondelete="SET NULL")
    )
    exercise_name: Mapped[str] = mapped_column(String(120))
    set_no: Mapped[int] = mapped_column(Integer, default=1)
    weight_kg: Mapped[float | None] = mapped_column(Float)
    reps: Mapped[int | None] = mapped_column(Integer)
    duration_s: Mapped[int | None] = mapped_column(Integer)
    rpe: Mapped[float | None] = mapped_column(Float)

    workout: Mapped[Workout] = relationship(back_populates="sets")


# --------------------------------------------------------------------------
# Weight, targets
# --------------------------------------------------------------------------


class Weight(Base):
    """No ``logged_by``: weight is self-report only, by design."""

    __tablename__ = "weights"
    __table_args__ = (UniqueConstraint("user_id", "date", name="uq_weight_day"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    date: Mapped[Date] = mapped_column(SADate)
    raw_kg: Mapped[float] = mapped_column(Float)
    trend_kg: Mapped[float] = mapped_column(Float)
    created_at: Mapped[datetime] = _utcnow_col()


class Target(Base):
    __tablename__ = "targets"
    __table_args__ = (UniqueConstraint("user_id", "week_start", name="uq_target_week"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    week_start: Mapped[Date] = mapped_column(SADate)
    est_tdee: Mapped[float | None] = mapped_column(Float)
    target_kcal: Mapped[float] = mapped_column(Float)
    target_protein_g: Mapped[float] = mapped_column(Float)
    method: Mapped[str] = mapped_column(String(24), default="adaptive")  # adaptive|bmr|manual|coach
    set_by: Mapped[int | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL"))
    # A coach proposal is inert until the mentee accepts it.
    accepted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    pinned: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = _utcnow_col()


# --------------------------------------------------------------------------
# Mentorship
# --------------------------------------------------------------------------


class Mentorship(Base):
    __tablename__ = "mentorships"
    __table_args__ = (
        UniqueConstraint("mentor_id", "mentee_id", name="uq_mentorship_pair"),
        CheckConstraint("mentor_id != mentee_id", name="ck_mentorship_self"),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    mentor_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    # NULL while an invite is outstanding — the mentee is attached only when
    # they accept, after seeing the permission screen.
    mentee_id: Mapped[int | None] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    type: Mapped[MentorType] = mapped_column(EnumStr(MentorType, 16), default=MentorType.PEER)
    status: Mapped[MentorshipStatus] = mapped_column(EnumStr(MentorshipStatus, 16), default=MentorshipStatus.PENDING
    )
    invite_code: Mapped[str | None] = mapped_column(String(16), unique=True, index=True)
    invited_at: Mapped[datetime] = _utcnow_col()
    accepted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    permission_rows: Mapped[list["MentorshipPermission"]] = relationship(
        back_populates="mentorship", cascade="all, delete-orphan"
    )


class MentorshipPermission(Base):
    __tablename__ = "mentorship_permissions"
    __table_args__ = (UniqueConstraint("mentorship_id", "scope", name="uq_permission_scope"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    mentorship_id: Mapped[int] = mapped_column(
        ForeignKey("mentorships.id", ondelete="CASCADE"), index=True
    )
    scope: Mapped[Scope] = mapped_column(EnumStr(Scope, 32))
    allowed: Mapped[bool] = mapped_column(Boolean, default=False)

    mentorship: Mapped[Mentorship] = relationship(back_populates="permission_rows")


class Comment(Base):
    """코치 코멘트. 알림은 하루 1회로 묶어서 발송한다."""

    __tablename__ = "comments"

    id: Mapped[int] = mapped_column(primary_key=True)
    author_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    target_user_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    entity: Mapped[str] = mapped_column(String(24))  # meal | workout | day
    entity_id: Mapped[int | None] = mapped_column(Integer)
    on_date: Mapped[Date | None] = mapped_column(SADate)
    body: Mapped[str] = mapped_column(Text)
    created_at: Mapped[datetime] = _utcnow_col()


class AuditLog(Base):
    """Every third-party write. The mentee can always read their own log."""

    __tablename__ = "audit_logs"
    __table_args__ = (Index("ix_audit_target_created", "target_user_id", "created_at"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    actor_user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    target_user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    action: Mapped[str] = mapped_column(String(40))  # create | update | delete | grant | revoke
    entity: Mapped[str] = mapped_column(String(40))
    entity_id: Mapped[int | None] = mapped_column(Integer)
    before: Mapped[dict | None] = mapped_column(JSON)
    after: Mapped[dict | None] = mapped_column(JSON)
    created_at: Mapped[datetime] = _utcnow_col()


# --------------------------------------------------------------------------
# Battles
# --------------------------------------------------------------------------


class Battle(Base):
    __tablename__ = "battles"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(80))
    mode: Mapped[BattleMode] = mapped_column(EnumStr(BattleMode, 16), default=BattleMode.LEAGUE)
    owner_user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    canteen_id: Mapped[int | None] = mapped_column(ForeignKey("canteens.id", ondelete="SET NULL"))
    start_date: Mapped[Date] = mapped_column(SADate)
    end_date: Mapped[Date] = mapped_column(SADate)
    join_code: Mapped[str] = mapped_column(String(12), unique=True, index=True)
    status: Mapped[BattleStatus] = mapped_column(EnumStr(BattleStatus, 16), default=BattleStatus.OPEN)
    created_at: Mapped[datetime] = _utcnow_col()

    participants: Mapped[list["BattleParticipant"]] = relationship(
        back_populates="battle", cascade="all, delete-orphan"
    )


class BattleParticipant(Base):
    __tablename__ = "battle_participants"
    __table_args__ = (UniqueConstraint("battle_id", "user_id", name="uq_battle_participant"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    battle_id: Mapped[int] = mapped_column(ForeignKey("battles.id", ondelete="CASCADE"), index=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    team: Mapped[str | None] = mapped_column(String(24))
    joined_at: Mapped[datetime] = _utcnow_col()

    battle: Mapped[Battle] = relationship(back_populates="participants")


class DailyScore(Base):
    __tablename__ = "daily_scores"
    __table_args__ = (
        UniqueConstraint("battle_id", "user_id", "date", name="uq_daily_score"),
        Index("ix_daily_score_battle_date", "battle_id", "date"),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    battle_id: Mapped[int] = mapped_column(ForeignKey("battles.id", ondelete="CASCADE"))
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    date: Mapped[Date] = mapped_column(SADate)
    points: Mapped[int] = mapped_column(Integer, default=0)
    breakdown: Mapped[dict] = mapped_column(JSON, default=dict)
    computed_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


# --------------------------------------------------------------------------
# Infrastructure
# --------------------------------------------------------------------------


class Job(Base):
    """Durable job queue.

    A table rather than Redis: it works identically on SQLite and Postgres,
    survives restarts, and lets a meal's analysis be retried without losing
    the upload. Swap in RQ/Celery later behind the same handler interface.
    """

    __tablename__ = "jobs"
    __table_args__ = (Index("ix_jobs_claim", "status", "run_at"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    kind: Mapped[str] = mapped_column(String(48))
    payload: Mapped[dict] = mapped_column(JSON, default=dict)
    status: Mapped[JobStatus] = mapped_column(EnumStr(JobStatus, 16), default=JobStatus.QUEUED)
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    max_attempts: Mapped[int] = mapped_column(Integer, default=4)
    run_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    locked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    locked_by: Mapped[str | None] = mapped_column(String(64))
    last_error: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = _utcnow_col()
    finished_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class Notification(Base):
    __tablename__ = "notifications"
    __table_args__ = (Index("ix_notif_user_created", "user_id", "created_at"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    kind: Mapped[str] = mapped_column(String(40))
    title: Mapped[str] = mapped_column(String(160))
    body: Mapped[str | None] = mapped_column(Text)
    payload: Mapped[dict] = mapped_column(JSON, default=dict)
    read_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = _utcnow_col()
