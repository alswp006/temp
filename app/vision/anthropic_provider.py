"""Claude vision provider.

Uses the official Anthropic SDK with structured outputs, so the model is
constrained to our JSON schema instead of being asked politely for JSON and
then regex-scraped.

Notes on the request shape:

* ``output_config.format`` (not the deprecated top-level ``output_format``).
* ``output_config.effort`` defaults to ``low`` — reading a food tray against a
  known candidate list is not a reasoning-heavy task, and this is a per-meal
  cost centre. Thinking is left at its default (adaptive) rather than disabled:
  on Claude Opus 5, disabling thinking has known failure modes and low effort
  already captures most of the saving.
* The system prompt is a frozen string carrying a cache breakpoint; everything
  request-specific lives in the user turn so the cached prefix stays stable.
"""

from __future__ import annotations

import base64
import json
import logging
from typing import Any

from app.config import settings
from app.errors import UpstreamError
from app.vision.base import (
    ImagePayload,
    MenuBoardParse,
    MenuBoardRequest,
    TrayAnalysis,
    TrayRequest,
    VisionProvider,
    WorkoutNoteRequest,
    WorkoutParse,
)
from app.vision.prompts import (
    MENU_BOARD_SCHEMA,
    MENU_BOARD_SYSTEM,
    TRAY_SCHEMA,
    TRAY_SYSTEM,
    WORKOUT_SCHEMA,
    WORKOUT_SYSTEM,
    render_tray_user_text,
)

log = logging.getLogger(__name__)

MAX_TOKENS = 8000


class AnthropicVisionProvider(VisionProvider):
    name = "anthropic"

    def __init__(self, api_key: str | None = None, model: str | None = None):
        try:
            from anthropic import AsyncAnthropic
        except ImportError as exc:  # pragma: no cover - optional dependency
            raise UpstreamError(
                "anthropic 패키지가 설치되어 있지 않습니다. `pip install anthropic`"
            ) from exc

        key = api_key or settings.anthropic_api_key
        if not key:
            raise UpstreamError("ANTHROPIC_API_KEY가 설정되지 않았습니다.")
        self._client = AsyncAnthropic(api_key=key, timeout=settings.vision_timeout_s)
        self._model = model or settings.anthropic_model

    # --- plumbing ---------------------------------------------------------

    @staticmethod
    def _image_block(image: ImagePayload) -> dict[str, Any]:
        return {
            "type": "image",
            "source": {
                "type": "base64",
                "media_type": image.media_type,
                "data": base64.standard_b64encode(image.data).decode("ascii"),
            },
        }

    async def _call(
        self,
        *,
        system: str,
        content: list[dict[str, Any]],
        schema: dict[str, Any],
    ) -> dict[str, Any]:
        import anthropic

        try:
            response = await self._client.messages.create(
                model=self._model,
                max_tokens=MAX_TOKENS,
                system=[
                    {
                        "type": "text",
                        "text": system,
                        "cache_control": {"type": "ephemeral"},
                    }
                ],
                messages=[{"role": "user", "content": content}],
                output_config={
                    "effort": settings.anthropic_effort,
                    "format": {"type": "json_schema", "schema": schema},
                },
            )
        except anthropic.RateLimitError as exc:
            raise UpstreamError("비전 모델 호출이 레이트 리밋에 걸렸습니다.") from exc
        except anthropic.APIStatusError as exc:
            raise UpstreamError(f"비전 모델 오류({exc.status_code}): {exc.message}") from exc
        except anthropic.APIConnectionError as exc:
            raise UpstreamError("비전 모델에 연결하지 못했습니다.") from exc

        # A refusal is a successful HTTP 200 with empty/partial content, so it
        # has to be checked before touching `content`.
        if response.stop_reason == "refusal":
            category = getattr(response.stop_details, "category", None)
            raise UpstreamError(f"비전 모델이 요청을 거부했습니다. (category={category})")
        if response.stop_reason == "max_tokens":
            raise UpstreamError("비전 모델 응답이 잘렸습니다. max_tokens를 늘리십시오.")

        text = next((b.text for b in response.content if b.type == "text"), None)
        if not text:
            raise UpstreamError("비전 모델이 빈 응답을 반환했습니다.")
        try:
            return json.loads(text)
        except json.JSONDecodeError as exc:  # pragma: no cover - schema should prevent
            raise UpstreamError("비전 모델 응답을 JSON으로 해석하지 못했습니다.") from exc

    # --- contract ---------------------------------------------------------

    async def analyze_tray(self, req: TrayRequest) -> TrayAnalysis:
        data = await self._call(
            system=TRAY_SYSTEM,
            content=[
                self._image_block(req.image),
                {"type": "text", "text": render_tray_user_text(req)},
            ],
            schema=TRAY_SCHEMA,
        )
        return TrayAnalysis.model_validate(data)

    async def parse_menu_board(self, req: MenuBoardRequest) -> MenuBoardParse:
        hint = []
        if req.week_of:
            hint.append(f"기준 주(월요일): {req.week_of.isoformat()}")
        if req.hint:
            hint.append(req.hint)
        hint.append("이 주간 식단표를 파싱해 주십시오.")
        data = await self._call(
            system=MENU_BOARD_SYSTEM,
            content=[
                self._image_block(req.image),
                {"type": "text", "text": "\n".join(hint)},
            ],
            schema=MENU_BOARD_SCHEMA,
        )
        return MenuBoardParse.model_validate(data)

    async def parse_workout_note(self, req: WorkoutNoteRequest) -> WorkoutParse:
        content: list[dict[str, Any]] = []
        if req.image:
            content.append(self._image_block(req.image))
        prompt: list[str] = []
        if req.known_exercises:
            prompt.append(
                "참고용 운동명 목록(강제 아님): " + ", ".join(req.known_exercises[:80])
            )
        if req.text:
            prompt.append(f"기록 원문: {req.text}")
        prompt.append("세트 단위로 파싱해 주십시오.")
        content.append({"type": "text", "text": "\n".join(prompt)})

        data = await self._call(
            system=WORKOUT_SYSTEM, content=content, schema=WORKOUT_SCHEMA
        )
        return WorkoutParse.model_validate(data)

    async def aclose(self) -> None:
        await self._client.close()
