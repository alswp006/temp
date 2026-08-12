"""Application settings.

Everything is environment-driven so the same image runs on a laptop, a home
server behind a Cloudflare tunnel, and a managed cloud host.
"""

from __future__ import annotations

import secrets
from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

REPO_ROOT = Path(__file__).resolve().parent.parent


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env", env_file_encoding="utf-8", extra="ignore"
    )

    # --- core -------------------------------------------------------------
    env: Literal["dev", "test", "prod"] = "dev"
    app_name: str = "식판"
    base_url: str = "http://localhost:8000"
    secret_key: str = Field(default_factory=lambda: secrets.token_urlsafe(48))

    # --- database ---------------------------------------------------------
    # sqlite+aiosqlite for single-user Phase 1; postgresql+asyncpg for the rest.
    database_url: str = "sqlite+aiosqlite:///./sikpan.db"

    # --- auth -------------------------------------------------------------
    access_token_ttl_minutes: int = 60 * 24 * 14
    login_code_ttl_minutes: int = 15
    login_code_max_attempts: int = 5
    # In dev the magic-link code is returned in the API response so you can
    # log in without an SMTP server. Never enable this in prod.
    expose_login_code: bool = True

    # --- storage ----------------------------------------------------------
    media_root: Path = REPO_ROOT / "var" / "media"
    max_upload_bytes: int = 12 * 1024 * 1024
    photo_max_edge: int = 1568
    # Privacy: drop the original bytes once analysis finishes.
    discard_photo_after_analysis: bool = False

    # --- vision -----------------------------------------------------------
    vision_provider: Literal["stub", "anthropic", "gemini"] = "stub"
    anthropic_api_key: str | None = None
    anthropic_model: str = "claude-opus-5"
    anthropic_effort: Literal["low", "medium", "high", "xhigh", "max"] = "low"
    gemini_api_key: str | None = None
    gemini_model: str = "gemini-2.0-flash"
    vision_timeout_s: float = 60.0

    # --- recognition call policy -----------------------------------------
    # K for the first analysis of a (canteen, date, meal) slot.
    recognition_k_cold: int = 5
    # K when a baseline interpretation already exists for the slot.
    recognition_k_warm: int = 1
    # Extra calls when the warm result disagrees with the baseline.
    recognition_k_escalate: int = 3
    # portion_ratio distance above which a warm result counts as disagreement.
    recognition_agreement_tolerance: float = 0.35
    recognition_min_confidence: float = 0.55

    # --- targets ----------------------------------------------------------
    weight_trend_alpha: float = 0.1
    tdee_clamp_ratio: float = 0.15
    protein_g_per_kg: float = 1.8

    # --- jobs -------------------------------------------------------------
    worker_poll_interval_s: float = 1.0
    worker_batch_size: int = 4
    job_max_attempts: int = 4
    # Run the worker inside the API process. Fine for Phase 1/2; in prod run
    # `python -m app.jobs.worker` as its own process and set this to False.
    run_worker_in_process: bool = True

    # --- integrations -----------------------------------------------------
    telegram_bot_token: str | None = None
    telegram_webhook_secret: str | None = None

    @field_validator("media_root", mode="after")
    @classmethod
    def _ensure_media_root(cls, v: Path) -> Path:
        v.mkdir(parents=True, exist_ok=True)
        return v

    @property
    def is_sqlite(self) -> bool:
        return self.database_url.startswith("sqlite")


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
