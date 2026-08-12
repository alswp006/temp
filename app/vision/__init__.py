"""Vision provider registry.

One process-wide provider instance, chosen by config. Tests swap it out with
:func:`set_provider`.
"""

from __future__ import annotations

import logging

from app.config import settings
from app.vision.base import VisionProvider
from app.vision.stub import StubVisionProvider

log = logging.getLogger(__name__)

_provider: VisionProvider | None = None


def build_provider(kind: str | None = None) -> VisionProvider:
    kind = (kind or settings.vision_provider).lower()
    if kind == "anthropic":
        from app.vision.anthropic_provider import AnthropicVisionProvider

        return AnthropicVisionProvider()
    if kind == "gemini":
        from app.vision.gemini_provider import GeminiVisionProvider

        return GeminiVisionProvider()
    return StubVisionProvider()


def get_provider() -> VisionProvider:
    global _provider
    if _provider is None:
        try:
            _provider = build_provider()
        except Exception as exc:  # noqa: BLE001
            # A missing key must not take the API down: the rest of the app
            # (manual entry, meal sets, coach dashboard) still works, and the
            # photo path fails per-request with a readable error.
            log.warning("비전 프로바이더 초기화 실패, stub으로 대체합니다: %s", exc)
            _provider = StubVisionProvider()
        log.info("vision provider = %s", _provider.name)
    return _provider


def set_provider(provider: VisionProvider | None) -> None:
    global _provider
    _provider = provider


async def close_provider() -> None:
    global _provider
    if _provider is not None:
        await _provider.aclose()
        _provider = None


__all__ = ["build_provider", "get_provider", "set_provider", "close_provider"]
