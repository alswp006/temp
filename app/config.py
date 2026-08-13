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

    # --- mail -------------------------------------------------------------
    # Without these the login code only reaches the log, which means nobody
    # outside the machine running the server can sign in. This is the single
    # thing that has to be configured before a real user exists.
    smtp_host: str | None = None
    smtp_port: int = 587
    smtp_user: str | None = None
    smtp_password: str | None = None
    smtp_starttls: bool = True
    smtp_ssl: bool = False
    mail_from: str = "식판 <no-reply@sikpan.app>"
    mail_timeout_seconds: float = 15.0

    # --- push -------------------------------------------------------------
    # FCM은 iOS(APNs 경유)와 안드로이드를 한 경로로 처리합니다. 서비스 계정
    # JSON 경로만 주면 되고, 없으면 푸시는 조용히 비활성입니다 — 알림은
    # 여전히 DB에 쌓이고 앱을 열면 보입니다.
    push_provider: Literal["fcm", "noop"] = "noop"
    fcm_credentials_file: Path | None = None
    fcm_project_id: str | None = None
    push_timeout_seconds: float = 10.0

    # --- 관측 -------------------------------------------------------------
    # DSN이 없으면 통째로 비활성입니다. 실기기에서 뭐가 깨지는지 모르는 채로
    # 운영하지 않기 위한 최소 장치입니다.
    sentry_dsn: str | None = None
    sentry_traces_sample_rate: float = 0.0
    sentry_send_default_pii: bool = False
    release: str = "0.1.0"

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
