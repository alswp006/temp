"""Application settings.

Everything is environment-driven so the same image runs on a laptop, a home
server behind a Cloudflare tunnel, and a managed cloud host.
"""

from __future__ import annotations

import os
import secrets
from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic import Field, field_validator, model_validator
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
    # 코드 요청 빈도. 이메일별은 DB(login_codes)로 세고, 출발지별은 프로세스
    # 메모리로 셉니다 — 자세한 것은 app/core/ratelimit.py.
    login_code_per_email_per_hour: int = 5
    login_code_per_ip_per_hour: int = 20
    # 로그인 코드를 API 응답에 실어 보냅니다. SMTP 없이 로그인하려고 둔
    # 개발 편의 기능인데, 기본값이 True였기 때문에 compose를 쓰지 않고
    # uvicorn으로 직접 띄운 배포는 OTP를 그대로 응답에 노출하고 있었습니다.
    # 기본값은 끔. 켜려면 EXPOSE_LOGIN_CODE=true를 명시하십시오
    # (프로덕션에서는 명시해도 거부합니다 — 아래 _harden 참고).
    # 서버 로그에는 프로덕션이 아닌 한 항상 찍히므로, `make dev`는 그대로
    # 터미널에서 코드를 보고 로그인할 수 있습니다.
    expose_login_code: bool = False

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

    @model_validator(mode="after")
    def _harden(self) -> "Settings":
        """프로덕션에서 조용히 위험해지는 기본값을 여기서 막습니다.

        기본값 하나하나가 각자 안전한 것보다, 위험한 조합을 한곳에서 거절하는
        편이 놓치기 어렵습니다.
        """
        if self.env == "prod":
            if self.expose_login_code:
                raise ValueError(
                    "EXPOSE_LOGIN_CODE는 프로덕션에서 켤 수 없습니다. "
                    "로그인 코드가 API 응답에 그대로 실려 나갑니다."
                )
            if "SECRET_KEY" not in os.environ:
                # 기본값은 프로세스마다 새로 만들어집니다. 재시작하면 모든
                # 토큰이 무효가 되고, 워커를 여러 개 띄우면 워커마다 키가 달라
                # 무작위로 401이 납니다.
                raise ValueError(
                    "프로덕션에서는 SECRET_KEY를 환경변수로 고정해야 합니다."
                )
        elif self.env == "test":
            # 테스트에는 메일 서버가 없습니다.
            self.expose_login_code = True
        return self

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
