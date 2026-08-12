"""Vision provider contract and payload types.

The whole product rests on one prompt-design decision: **we never ask the model
for grams.** We ask for ``portion_ratio`` — how much was served relative to the
menu's standard portion. Models are far better at "about 1.2× a normal scoop"
than at "252 grams", and the grams follow from arithmetic we control.
"""

from __future__ import annotations

import abc
from dataclasses import dataclass, field
from datetime import date as Date

from pydantic import BaseModel, Field, field_validator

from app.models import FoodCategory, MealType

# --------------------------------------------------------------------------
# Inputs
# --------------------------------------------------------------------------


@dataclass(slots=True)
class MenuCandidate:
    """One option the model may choose from. This is the whole trick: the
    model answers a multiple-choice question, not an open one."""

    menu_id: int
    name: str
    category: FoodCategory
    standard_g: float


@dataclass(slots=True)
class ImagePayload:
    data: bytes
    media_type: str = "image/jpeg"


@dataclass(slots=True)
class TrayRequest:
    image: ImagePayload
    candidates: list[MenuCandidate] = field(default_factory=list)
    meal_type: MealType | None = None
    hint: str | None = None
    # Which of the K parallel calls this is. Real providers ignore it; the
    # stub uses it to produce the per-call variance the median is meant to
    # smooth out, so the aggregation path is exercised offline and in CI.
    nonce: int = 0

    @property
    def open_mode(self) -> bool:
        """No menu plan for this slot: fall back to open recognition and mark
        the result as low-confidence in the UI."""
        return not self.candidates


@dataclass(slots=True)
class MenuBoardRequest:
    image: ImagePayload
    week_of: Date | None = None
    hint: str | None = None


@dataclass(slots=True)
class WorkoutNoteRequest:
    """A photo of a trainer's notebook / whiteboard / other app's screen, or a
    transcribed voice line."""

    image: ImagePayload | None = None
    text: str | None = None
    known_exercises: list[str] = field(default_factory=list)


# --------------------------------------------------------------------------
# Outputs
# --------------------------------------------------------------------------


class DetectedItem(BaseModel):
    menu_id: int | None = None
    free_text: str | None = None
    portion_ratio: float | None = None
    estimated_g: float | None = None
    confidence: float = 0.5

    @field_validator("portion_ratio")
    @classmethod
    def _sane_ratio(cls, v: float | None) -> float | None:
        if v is None:
            return None
        return max(0.0, min(4.0, v))

    @field_validator("confidence")
    @classmethod
    def _sane_confidence(cls, v: float) -> float:
        return max(0.0, min(1.0, v))


class TrayAnalysis(BaseModel):
    items: list[DetectedItem] = Field(default_factory=list)
    tray_detected: bool = False
    notes: str = ""


class ParsedMenuItem(BaseModel):
    name: str
    category: FoodCategory = FoodCategory.SIDE
    standard_g: float | None = None
    kcal: float | None = None


class ParsedMenuSlot(BaseModel):
    date: Date
    meal_type: MealType
    items: list[ParsedMenuItem] = Field(default_factory=list)


class MenuBoardParse(BaseModel):
    slots: list[ParsedMenuSlot] = Field(default_factory=list)
    notes: str = ""


class ParsedWorkoutSet(BaseModel):
    exercise: str
    set_no: int = 1
    weight_kg: float | None = None
    reps: int | None = None
    duration_s: int | None = None
    rpe: float | None = None


class WorkoutParse(BaseModel):
    sets: list[ParsedWorkoutSet] = Field(default_factory=list)
    unmatched: list[str] = Field(default_factory=list)
    notes: str = ""


# --------------------------------------------------------------------------
# Provider
# --------------------------------------------------------------------------


class VisionProvider(abc.ABC):
    """Providers are swappable at runtime via ``SIKPAN_VISION_PROVIDER``.

    Keeping this an abstract base rather than a bare Protocol buys us a shared
    ``name`` and a single place to document the contract each method must meet.
    """

    name: str = "base"

    @abc.abstractmethod
    async def analyze_tray(self, req: TrayRequest) -> TrayAnalysis:
        """Identify which candidates are on the tray and how much of each."""

    @abc.abstractmethod
    async def parse_menu_board(self, req: MenuBoardRequest) -> MenuBoardParse:
        """Parse a weekly menu board photo into date/meal/item rows."""

    @abc.abstractmethod
    async def parse_workout_note(self, req: WorkoutNoteRequest) -> WorkoutParse:
        """Parse a handwritten set log (or one spoken sentence) into sets."""

    async def aclose(self) -> None:  # pragma: no cover - default no-op
        return None
