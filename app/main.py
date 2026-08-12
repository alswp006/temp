"""FastAPI application entrypoint."""

from __future__ import annotations

import asyncio
import contextlib
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles

from app.api import api_router
from app.config import REPO_ROOT, settings
from app.db import create_all, dispose_engine, session_scope
from app.errors import AppError
from app.jobs import handlers  # noqa: F401 - registers job handlers
from app.jobs.worker import worker_loop
from app.services import nutrition
from app.vision import close_provider, get_provider

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s :: %(message)s",
)
log = logging.getLogger("sikpan")

WEB_DIR = REPO_ROOT / "web"


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Alembic owns the schema in production; this keeps `make dev` and the
    # tests one command instead of three.
    if settings.env != "prod":
        await create_all()

    async with session_scope() as db:
        if not await nutrition.is_seeded(db):
            counts = await nutrition.seed_all(db)
            log.info("seeded reference data: %s", counts)

    log.info("vision provider: %s", get_provider().name)

    worker_task: asyncio.Task | None = None
    stop = asyncio.Event()
    if settings.run_worker_in_process:
        worker_task = asyncio.create_task(worker_loop(stop))

    try:
        yield
    finally:
        stop.set()
        if worker_task:
            worker_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await worker_task
        await close_provider()
        await dispose_engine()


app = FastAPI(
    title="식판 (Sikpan) API",
    description=(
        "같이 쓰는 식단·운동 기록 앱. "
        "기록을 나 혼자 하지 않아도 되는 것이 이 앱의 전제입니다."
    ),
    version="0.1.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"] if settings.env != "prod" else [settings.base_url],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.exception_handler(AppError)
async def app_error_handler(_: Request, exc: AppError) -> JSONResponse:
    return JSONResponse(status_code=exc.status_code, content=exc.to_dict())


@app.exception_handler(RequestValidationError)
async def validation_handler(_: Request, exc: RequestValidationError) -> JSONResponse:
    return JSONResponse(
        status_code=422,
        content={
            "error": "validation_error",
            "message": "요청 형식이 올바르지 않습니다.",
            "detail": exc.errors(),
        },
    )


app.include_router(api_router, prefix="/api")


# --- PWA ------------------------------------------------------------------

if WEB_DIR.is_dir():
    app.mount("/app", StaticFiles(directory=WEB_DIR, html=True), name="web")

    @app.get("/", include_in_schema=False)
    async def root() -> RedirectResponse:
        return RedirectResponse(url="/app/")

    @app.get("/sw.js", include_in_schema=False)
    async def service_worker() -> FileResponse:
        # A service worker's scope is capped by the path it is served from, so
        # it has to sit at the origin root to control /app/ and /api/.
        return FileResponse(
            WEB_DIR / "sw.js",
            media_type="application/javascript",
            headers={"Service-Worker-Allowed": "/"},
        )

    @app.get("/manifest.webmanifest", include_in_schema=False)
    async def manifest() -> FileResponse:
        return FileResponse(
            WEB_DIR / "manifest.webmanifest", media_type="application/manifest+json"
        )

else:  # pragma: no cover - web assets missing in a slim deploy

    @app.get("/", include_in_schema=False)
    async def root_api_only() -> dict:
        return {"name": settings.app_name, "docs": "/docs"}
