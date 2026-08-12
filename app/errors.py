"""Typed application errors mapped to HTTP responses in :mod:`app.main`."""

from __future__ import annotations


class AppError(Exception):
    status_code = 400
    code = "bad_request"

    def __init__(self, message: str, *, detail: dict | None = None):
        super().__init__(message)
        self.message = message
        self.detail = detail or {}

    def to_dict(self) -> dict:
        payload = {"error": self.code, "message": self.message}
        if self.detail:
            payload["detail"] = self.detail
        return payload


class NotFound(AppError):
    status_code = 404
    code = "not_found"


class Unauthorized(AppError):
    status_code = 401
    code = "unauthorized"


class Forbidden(AppError):
    status_code = 403
    code = "forbidden"


class Conflict(AppError):
    status_code = 409
    code = "conflict"


class ValidationError(AppError):
    status_code = 422
    code = "validation_error"


class RateLimited(AppError):
    status_code = 429
    code = "rate_limited"


class UpstreamError(AppError):
    status_code = 502
    code = "upstream_error"


class SafetyGuardError(ValidationError):
    """Raised when a coach-set goal would breach the BMR floor or the weekly
    loss cap. These are not negotiable — see docs/ROADMAP.md §3.3."""

    code = "safety_guard"
