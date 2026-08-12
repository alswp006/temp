"""Gemini vision provider (raw REST — Google has no first-party async SDK we
want to depend on here).

Gemini's ``responseSchema`` is an OpenAPI 3.0 subset rather than JSON Schema:
uppercase type names, ``nullable`` instead of union types, no
``additionalProperties``. :func:`to_gemini_schema` converts our canonical
schemas so both providers stay driven by one source of truth.
"""

from __future__ import annotations

import base64
import json
import logging
from typing import Any

import httpx

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

API_ROOT = "https://generativelanguage.googleapis.com/v1beta"

_TYPE_MAP = {
    "object": "OBJECT",
    "array": "ARRAY",
    "string": "STRING",
    "number": "NUMBER",
    "integer": "INTEGER",
    "boolean": "BOOLEAN",
}


def to_gemini_schema(schema: dict[str, Any]) -> dict[str, Any]:
    """Convert a JSON Schema fragment to Gemini's OpenAPI-flavoured schema."""
    out: dict[str, Any] = {}

    raw_type = schema.get("type")
    nullable = False
    if isinstance(raw_type, list):
        types = [t for t in raw_type if t != "null"]
        nullable = "null" in raw_type
        raw_type = types[0] if types else "string"
    if raw_type:
        out["type"] = _TYPE_MAP.get(raw_type, "STRING")
    if nullable:
        out["nullable"] = True
    if "description" in schema:
        out["description"] = schema["description"]
    if "enum" in schema:
        out["enum"] = list(schema["enum"])

    if raw_type == "object":
        props = schema.get("properties", {})
        out["properties"] = {k: to_gemini_schema(v) for k, v in props.items()}
        # Gemini honours propertyOrdering; matching the schema's declared order
        # makes outputs stable across calls, which matters for the K-call median.
        out["propertyOrdering"] = list(props.keys())
        if schema.get("required"):
            out["required"] = list(schema["required"])
    elif raw_type == "array" and "items" in schema:
        out["items"] = to_gemini_schema(schema["items"])

    return out


class GeminiVisionProvider(VisionProvider):
    name = "gemini"

    def __init__(self, api_key: str | None = None, model: str | None = None):
        key = api_key or settings.gemini_api_key
        if not key:
            raise UpstreamError("GEMINI_API_KEY가 설정되지 않았습니다.")
        self._key = key
        self._model = model or settings.gemini_model
        self._client = httpx.AsyncClient(timeout=settings.vision_timeout_s)

    @staticmethod
    def _image_part(image: ImagePayload) -> dict[str, Any]:
        return {
            "inline_data": {
                "mime_type": image.media_type,
                "data": base64.standard_b64encode(image.data).decode("ascii"),
            }
        }

    async def _call(
        self, *, system: str, parts: list[dict[str, Any]], schema: dict[str, Any]
    ) -> dict[str, Any]:
        url = f"{API_ROOT}/models/{self._model}:generateContent"
        body = {
            "systemInstruction": {"parts": [{"text": system}]},
            "contents": [{"role": "user", "parts": parts}],
            "generationConfig": {
                "responseMimeType": "application/json",
                "responseSchema": to_gemini_schema(schema),
            },
        }
        try:
            resp = await self._client.post(
                url, params={"key": self._key}, json=body
            )
        except httpx.HTTPError as exc:
            raise UpstreamError("Gemini 호출에 실패했습니다.") from exc

        if resp.status_code == 429:
            raise UpstreamError("Gemini 호출이 레이트 리밋에 걸렸습니다.")
        if resp.status_code >= 400:
            raise UpstreamError(f"Gemini 오류({resp.status_code}): {resp.text[:300]}")

        payload = resp.json()
        candidates = payload.get("candidates") or []
        if not candidates:
            reason = (payload.get("promptFeedback") or {}).get("blockReason")
            raise UpstreamError(f"Gemini가 응답을 반환하지 않았습니다. (reason={reason})")

        chunks = candidates[0].get("content", {}).get("parts", [])
        text = "".join(part.get("text", "") for part in chunks)
        if not text.strip():
            raise UpstreamError("Gemini가 빈 응답을 반환했습니다.")
        try:
            return json.loads(text)
        except json.JSONDecodeError as exc:
            raise UpstreamError("Gemini 응답을 JSON으로 해석하지 못했습니다.") from exc

    async def analyze_tray(self, req: TrayRequest) -> TrayAnalysis:
        data = await self._call(
            system=TRAY_SYSTEM,
            parts=[self._image_part(req.image), {"text": render_tray_user_text(req)}],
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
            parts=[self._image_part(req.image), {"text": "\n".join(hint)}],
            schema=MENU_BOARD_SCHEMA,
        )
        return MenuBoardParse.model_validate(data)

    async def parse_workout_note(self, req: WorkoutNoteRequest) -> WorkoutParse:
        parts: list[dict[str, Any]] = []
        if req.image:
            parts.append(self._image_part(req.image))
        prompt: list[str] = []
        if req.known_exercises:
            prompt.append("참고용 운동명 목록: " + ", ".join(req.known_exercises[:80]))
        if req.text:
            prompt.append(f"기록 원문: {req.text}")
        prompt.append("세트 단위로 파싱해 주십시오.")
        parts.append({"text": "\n".join(prompt)})

        data = await self._call(system=WORKOUT_SYSTEM, parts=parts, schema=WORKOUT_SCHEMA)
        return WorkoutParse.model_validate(data)

    async def aclose(self) -> None:
        await self._client.aclose()
