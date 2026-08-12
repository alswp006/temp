"""Request/response models.

Kept in one module because they are small, mutually referential, and read
better as a single contract document than as a dozen files.
"""

from __future__ import annotations

from datetime import date as Date
from datetime import datetime

from pydantic import BaseModel, ConfigDict, EmailStr, Field, field_validator

from app.models import (
    BattleMode,
    EntrySource,
    FoodCategory,
    GoalType,
    MealStatus,
    MealType,
    MentorshipStatus,
    MentorType,
    Scope,
    Sex,
)


class ORMModel(BaseModel):
    model_config = ConfigDict(from_attributes=True)


# --------------------------------------------------------------------------
# Auth & profile
# --------------------------------------------------------------------------


class LoginRequest(BaseModel):
    email: EmailStr
    nickname: str | None = Field(default=None, max_length=40)


class LoginRequestResponse(BaseModel):
    sent: bool
    # Present only when SIKPAN_EXPOSE_LOGIN_CODE is on (dev).
    dev_code: str | None = None


class LoginVerify(BaseModel):
    email: EmailStr
    code: str = Field(min_length=4, max_length=8)


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    user: "UserOut"


class UserOut(ORMModel):
    id: int
    email: str
    nickname: str
    sex: Sex
    height_cm: float | None
    birth_year: int | None
    goal_type: GoalType
    activity_factor: float
    timezone: str
    plan: str


class UserUpdate(BaseModel):
    nickname: str | None = Field(default=None, max_length=40)
    sex: Sex | None = None
    height_cm: float | None = Field(default=None, gt=80, lt=250)
    birth_year: int | None = Field(default=None, gt=1900, lt=2030)
    goal_type: GoalType | None = None
    activity_factor: float | None = Field(default=None, ge=1.1, le=2.2)
    timezone: str | None = None


class ApiTokenCreate(BaseModel):
    name: str = Field(max_length=80)


class ApiTokenOut(ORMModel):
    id: int
    name: str
    prefix: str
    created_at: datetime
    last_used_at: datetime | None


class ApiTokenCreated(BaseModel):
    token: str  # shown exactly once
    info: ApiTokenOut


# --------------------------------------------------------------------------
# Canteens & menus
# --------------------------------------------------------------------------


class CanteenCreate(BaseModel):
    name: str = Field(max_length=80)
    is_public: bool = False
    timezone: str = "Asia/Seoul"


class CanteenOut(ORMModel):
    id: int
    name: str
    join_code: str
    is_public: bool
    timezone: str
    owner_user_id: int


class CanteenJoin(BaseModel):
    join_code: str


class MenuItemIn(BaseModel):
    name: str
    category: FoodCategory | None = None
    standard_g: float | None = Field(default=None, gt=0, le=2000)
    kcal_per_serving: float | None = Field(default=None, ge=0, le=5000)
    food_id: int | None = None


class MenuItemOut(ORMModel):
    id: int
    name: str
    category: FoodCategory
    standard_g: float
    kcal_per_serving: float | None
    food_id: int | None
    position: int


class MenuPlanIn(BaseModel):
    date: Date
    meal_type: MealType
    items: list[MenuItemIn]


class MenuPlanOut(ORMModel):
    id: int
    canteen_id: int
    date: Date
    meal_type: MealType
    source: str
    verified: bool
    created_by: int | None
    items: list[MenuItemOut] = []


class MenuDraftApply(BaseModel):
    """The (possibly edited) draft returned by the board parser."""

    slots: list[MenuPlanIn]
    source: str = "photo"
    photo_path: str | None = None


class MenuReportIn(BaseModel):
    note: str | None = Field(default=None, max_length=500)


# --------------------------------------------------------------------------
# Meals
# --------------------------------------------------------------------------


class MealItemOut(ORMModel):
    id: int
    name: str
    category: FoodCategory
    portion_ratio: float
    final_g: float
    kcal: float
    carb_g: float
    protein_g: float
    fat_g: float
    confidence: float
    edited_by_user: bool
    food_id: int | None
    menu_item_id: int | None


class MealOut(ORMModel):
    id: int
    user_id: int
    canteen_id: int | None
    shot_at: datetime
    local_date: Date
    meal_type: MealType
    status: MealStatus
    source: EntrySource
    logged_by: int
    calls_used: int
    cache_hit: bool
    open_mode: bool
    note: str | None
    error: str | None
    photo_path: str | None
    items: list[MealItemOut] = []
    kcal: float = 0
    protein_g: float = 0
    carb_g: float = 0
    fat_g: float = 0
    # Set by the API layer when the record was written by someone else.
    logged_by_name: str | None = None


class MealItemIn(BaseModel):
    name: str
    category: FoodCategory | None = None
    final_g: float = Field(gt=0, le=3000)
    food_id: int | None = None


class ManualMealIn(BaseModel):
    shot_at: datetime | None = None
    meal_type: MealType | None = None
    canteen_id: int | None = None
    note: str | None = None
    items: list[MealItemIn]


class MealUpdate(BaseModel):
    """Fix what the auto-inference got wrong.

    A 23:30 photo is inferred as 간식, which is right most of the time and
    wrong for a late dinner — and being wrong costs the menu-plan match, which
    is the whole accuracy advantage. Correcting the slot re-runs analysis.
    """

    meal_type: MealType | None = None
    canteen_id: int | None = None
    note: str | None = None
    reanalyze: bool = True


class MealItemUpdate(BaseModel):
    name: str | None = None
    final_g: float | None = Field(default=None, gt=0, le=3000)
    food_id: int | None = None
    category: FoodCategory | None = None


class NaturalEditIn(BaseModel):
    """'밥 150으로' / '국 안 먹음' 같은 한 줄 수정."""

    text: str = Field(min_length=1, max_length=200)


# --------------------------------------------------------------------------
# Meal sets
# --------------------------------------------------------------------------


class MealSetOut(ORMModel):
    id: int
    name: str
    use_count: int
    last_used_at: datetime | None
    default_meal_type: MealType | None
    payload: dict


class MealSetFromMeal(BaseModel):
    meal_id: int
    name: str = Field(max_length=80)


class MealSetManual(BaseModel):
    name: str = Field(max_length=80)
    items: list[MealItemIn]


class MealSetApply(BaseModel):
    at: datetime | None = None
    meal_type: MealType | None = None
    scale: float = Field(default=1.0, gt=0, le=5)


# --------------------------------------------------------------------------
# Workouts
# --------------------------------------------------------------------------


class WorkoutSetIn(BaseModel):
    exercise: str
    set_no: int = 1
    weight_kg: float | None = Field(default=None, ge=0, le=1000)
    reps: int | None = Field(default=None, ge=0, le=1000)
    duration_s: int | None = Field(default=None, ge=0, le=86400)
    rpe: float | None = Field(default=None, ge=0, le=10)


class WorkoutSetOut(ORMModel):
    id: int
    exercise_id: int | None
    exercise_name: str
    set_no: int
    weight_kg: float | None
    reps: int | None
    duration_s: int | None
    rpe: float | None


class WorkoutIn(BaseModel):
    user_id: int | None = None  # coach writing for a mentee
    performed_at: datetime | None = None
    session_note: str | None = None
    sets: list[WorkoutSetIn]


class WorkoutTextIn(BaseModel):
    user_id: int | None = None
    performed_at: datetime | None = None
    text: str = Field(min_length=1, max_length=2000)
    session_note: str | None = None


class WorkoutOut(ORMModel):
    id: int
    user_id: int
    performed_at: datetime
    local_date: Date
    session_note: str | None
    logged_by: int
    source: EntrySource
    unmatched: list = []
    sets: list[WorkoutSetOut] = []
    logged_by_name: str | None = None
    burn_kcal: float | None = None


class ExerciseConfirm(BaseModel):
    exercise_id: int


# --------------------------------------------------------------------------
# Weight, targets, calibration
# --------------------------------------------------------------------------


class WeightIn(BaseModel):
    date: Date | None = None
    raw_kg: float = Field(gt=20, lt=400)


class WeightOut(ORMModel):
    date: Date
    raw_kg: float
    trend_kg: float


class TargetOut(ORMModel):
    id: int
    week_start: Date
    est_tdee: float | None
    target_kcal: float
    target_protein_g: float
    method: str
    set_by: int | None
    accepted_at: datetime | None
    pinned: bool


class TargetProposal(BaseModel):
    """A coach proposes; the mentee accepts. Nothing takes effect until then."""

    user_id: int
    target_kcal: float = Field(gt=0, le=10000)
    target_protein_g: float = Field(gt=0, le=500)
    note: str | None = None
    confirm_aggressive: bool = False


class TargetOverride(BaseModel):
    target_kcal: float = Field(gt=0, le=10000)
    target_protein_g: float | None = Field(default=None, gt=0, le=500)
    pinned: bool = True
    confirm_aggressive: bool = False


class CalibrationIn(BaseModel):
    category: FoodCategory
    estimated_g: float = Field(gt=0, le=3000)
    actual_g: float = Field(gt=0, le=3000)
    meal_item_id: int | None = None


# --------------------------------------------------------------------------
# Mentorship
# --------------------------------------------------------------------------


class MentorshipInvite(BaseModel):
    type: MentorType = MentorType.PEER


class MentorshipInviteOut(BaseModel):
    invite_code: str
    invite_url: str
    type: MentorType


class MentorshipAccept(BaseModel):
    invite_code: str
    permissions: dict[Scope, bool] = Field(default_factory=dict)


class PermissionUpdate(BaseModel):
    permissions: dict[Scope, bool]


class MentorshipOut(ORMModel):
    id: int
    mentor_id: int
    mentee_id: int | None
    type: MentorType
    status: MentorshipStatus
    invited_at: datetime
    accepted_at: datetime | None
    mentor_name: str | None = None
    mentee_name: str | None = None
    permissions: dict[str, bool] = {}


class CommentIn(BaseModel):
    target_user_id: int
    entity: str = "day"
    entity_id: int | None = None
    on_date: Date | None = None
    body: str = Field(min_length=1, max_length=1000)


class CommentOut(ORMModel):
    id: int
    author_id: int
    target_user_id: int
    entity: str
    entity_id: int | None
    on_date: Date | None
    body: str
    created_at: datetime
    author_name: str | None = None


# --------------------------------------------------------------------------
# Battles
# --------------------------------------------------------------------------


class BattleCreate(BaseModel):
    name: str = Field(max_length=80)
    mode: BattleMode = BattleMode.LEAGUE
    canteen_id: int | None = None
    start_date: Date | None = None
    weeks: int = Field(default=1, ge=1, le=8)

    @field_validator("weeks")
    @classmethod
    def _cap(cls, v: int) -> int:
        return min(v, 8)


class BattleOut(ORMModel):
    id: int
    name: str
    mode: BattleMode
    start_date: Date
    end_date: Date
    join_code: str
    status: str
    owner_user_id: int
    canteen_id: int | None


class BattleJoin(BaseModel):
    join_code: str
    team: str | None = None


class LeaderboardEntry(BaseModel):
    user_id: int
    nickname: str
    team: str | None
    points: int
    logged_days: int
    streak: int


# --------------------------------------------------------------------------
# Misc
# --------------------------------------------------------------------------


class FoodOut(ORMModel):
    id: int
    name: str
    category: FoodCategory
    kcal_100g: float
    carb_100g: float
    protein_100g: float
    fat_100g: float
    default_serving_g: float


class FoodMatchOut(BaseModel):
    food: FoodOut
    score: float


class NotificationOut(ORMModel):
    id: int
    kind: str
    title: str
    body: str | None
    payload: dict
    read_at: datetime | None
    created_at: datetime


class AuditLogOut(ORMModel):
    id: int
    actor_user_id: int
    action: str
    entity: str
    entity_id: int | None
    before: dict | None
    after: dict | None
    created_at: datetime
    actor_name: str | None = None


class Ok(BaseModel):
    ok: bool = True


TokenResponse.model_rebuild()
