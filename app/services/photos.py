"""Photo intake: EXIF capture time, downscale, EXIF strip, storage.

Order matters. We read the capture timestamp *before* stripping metadata,
because ``shot_at`` is what decides the meal slot and the local date — and a
photo uploaded at 23:00 from the gym might have been taken at lunch.
"""

from __future__ import annotations

import hashlib
import io
import logging
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from PIL import Image, ImageOps

from app.config import settings
from app.core.timeutil import ensure_aware, utcnow
from app.errors import ValidationError

log = logging.getLogger(__name__)

_EXIF_DATETIME_ORIGINAL = 36867
_EXIF_DATETIME_DIGITIZED = 36868
_EXIF_DATETIME = 306

ALLOWED_FORMATS = {"JPEG", "PNG", "WEBP", "HEIF", "HEIC"}


@dataclass(slots=True)
class StoredPhoto:
    path: str          # media-root-relative
    data: bytes        # normalised bytes, ready to send to the model
    media_type: str
    shot_at: datetime
    exif_shot_at: datetime | None
    width: int
    height: int
    sha256: str


def _parse_exif_datetime(raw: str | bytes | None) -> datetime | None:
    if not raw:
        return None
    if isinstance(raw, bytes):
        raw = raw.decode("ascii", errors="ignore")
    raw = raw.strip().rstrip("\x00")
    for fmt in ("%Y:%m:%d %H:%M:%S", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.strptime(raw, fmt)
        except ValueError:
            continue
    return None


def extract_shot_at(image: Image.Image) -> datetime | None:
    """Naive local wall-clock from EXIF, if present."""
    try:
        exif = image.getexif()
    except Exception:  # noqa: BLE001 - corrupt EXIF must never fail an upload
        return None
    if not exif:
        return None
    for tag in (_EXIF_DATETIME_ORIGINAL, _EXIF_DATETIME_DIGITIZED, _EXIF_DATETIME):
        parsed = _parse_exif_datetime(exif.get(tag))
        if parsed:
            return parsed
    return None


def process_upload(
    raw: bytes,
    *,
    user_id: int,
    tz_name: str,
    kind: str = "meal",
    fallback_shot_at: datetime | None = None,
) -> StoredPhoto:
    """Validate, orient, downscale, strip metadata, and persist one photo."""
    if not raw:
        raise ValidationError("빈 파일입니다.")
    if len(raw) > settings.max_upload_bytes:
        raise ValidationError(
            f"파일이 너무 큽니다. 최대 {settings.max_upload_bytes // (1024 * 1024)}MB."
        )

    try:
        image = Image.open(io.BytesIO(raw))
        image.load()
    except Exception as exc:  # noqa: BLE001
        raise ValidationError("이미지를 읽을 수 없습니다.") from exc

    if image.format and image.format.upper() not in ALLOWED_FORMATS:
        raise ValidationError(f"지원하지 않는 이미지 형식입니다: {image.format}")

    exif_shot_at = extract_shot_at(image)
    shot_at = (
        ensure_aware(exif_shot_at, tz_name)
        if exif_shot_at
        else (fallback_shot_at or utcnow())
    )

    # exif_transpose applies the orientation tag, then we re-encode without
    # metadata — the model sees an upright photo and no GPS coordinates or
    # device identifiers are persisted.
    image = ImageOps.exif_transpose(image)
    if image.mode not in ("RGB", "L"):
        image = image.convert("RGB")
    image.thumbnail(
        (settings.photo_max_edge, settings.photo_max_edge), Image.LANCZOS
    )

    buf = io.BytesIO()
    clean = Image.new(image.mode, image.size)
    clean.putdata(list(image.getdata()))
    clean.save(buf, format="JPEG", quality=88, optimize=True)
    data = buf.getvalue()

    digest = hashlib.sha256(data).hexdigest()
    rel_dir = Path(kind) / str(user_id) / shot_at.strftime("%Y%m")
    rel_path = rel_dir / f"{digest[:24]}.jpg"
    abs_path = settings.media_root / rel_path
    abs_path.parent.mkdir(parents=True, exist_ok=True)
    abs_path.write_bytes(data)

    return StoredPhoto(
        path=str(rel_path),
        data=data,
        media_type="image/jpeg",
        shot_at=shot_at,
        exif_shot_at=exif_shot_at,
        width=clean.width,
        height=clean.height,
        sha256=digest,
    )


def read_photo(rel_path: str) -> bytes | None:
    abs_path = settings.media_root / rel_path
    try:
        # Refuse anything that escapes the media root.
        abs_path.resolve().relative_to(settings.media_root.resolve())
    except ValueError:
        log.warning("media root 밖 경로 접근 시도: %s", rel_path)
        return None
    if not abs_path.is_file():
        return None
    return abs_path.read_bytes()


def delete_photo(rel_path: str | None) -> None:
    """Used by the 'discard original after analysis' privacy option and by
    account deletion."""
    if not rel_path:
        return
    abs_path = settings.media_root / rel_path
    try:
        abs_path.resolve().relative_to(settings.media_root.resolve())
    except ValueError:
        return
    abs_path.unlink(missing_ok=True)
