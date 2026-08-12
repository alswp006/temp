"""Durable job queue backed by the ``jobs`` table.

Why a table and not Redis/RQ: it works identically on SQLite and Postgres, it
survives a restart mid-analysis, and an upload can be retried without the user
re-taking the photo. The handler interface is deliberately narrow
(``async (session, payload) -> None``) so swapping the transport later is a
contained change.
"""

from __future__ import annotations

import asyncio
import logging
import os
import socket
from collections.abc import Awaitable, Callable
from datetime import timedelta

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.core.timeutil import utcnow
from app.db import session_scope
from app.models import Job, JobStatus

log = logging.getLogger(__name__)

Handler = Callable[[AsyncSession, dict], Awaitable[None]]
_HANDLERS: dict[str, Handler] = {}

WORKER_ID = f"{socket.gethostname()}:{os.getpid()}"
# Retry backoff per attempt: 5s, 30s, 2m, 10m.
BACKOFF_SECONDS = (5, 30, 120, 600)


def register(kind: str) -> Callable[[Handler], Handler]:
    def decorator(fn: Handler) -> Handler:
        _HANDLERS[kind] = fn
        return fn

    return decorator


def handlers() -> dict[str, Handler]:
    return dict(_HANDLERS)


async def enqueue(
    db: AsyncSession,
    kind: str,
    payload: dict | None = None,
    *,
    delay_s: float = 0.0,
    max_attempts: int | None = None,
) -> Job:
    job = Job(
        kind=kind,
        payload=payload or {},
        status=JobStatus.QUEUED,
        run_at=utcnow() + timedelta(seconds=delay_s),
        max_attempts=max_attempts or settings.job_max_attempts,
    )
    db.add(job)
    await db.flush()
    return job


async def _claim(db: AsyncSession, limit: int) -> list[Job]:
    """Claim due jobs.

    ``UPDATE ... WHERE id IN (...)`` guarded by a status check makes the claim
    atomic on both backends without needing ``SKIP LOCKED``, which SQLite
    doesn't have.
    """
    now = utcnow()
    candidates = (
        await db.execute(
            select(Job.id)
            .where(Job.status == JobStatus.QUEUED, Job.run_at <= now)
            .order_by(Job.run_at)
            .limit(limit)
        )
    ).scalars().all()
    if not candidates:
        return []

    result = await db.execute(
        update(Job)
        .where(Job.id.in_(candidates), Job.status == JobStatus.QUEUED)
        .values(status=JobStatus.RUNNING, locked_at=now, locked_by=WORKER_ID)
        .execution_options(synchronize_session=False)
    )
    if not result.rowcount:
        return []
    await db.commit()

    return list(
        (
            await db.execute(
                select(Job).where(
                    Job.id.in_(candidates),
                    Job.locked_by == WORKER_ID,
                    Job.status == JobStatus.RUNNING,
                )
            )
        ).scalars().all()
    )


async def _execute(job: Job) -> None:
    handler = _HANDLERS.get(job.kind)
    if handler is None:
        log.error("등록되지 않은 job kind: %s", job.kind)
        async with session_scope() as db:
            row = await db.get(Job, job.id)
            if row:
                row.status = JobStatus.FAILED
                row.last_error = f"unknown kind: {job.kind}"
                row.finished_at = utcnow()
        return

    payload = dict(job.payload or {})
    try:
        async with session_scope() as db:
            await handler(db, payload)
    except Exception as exc:  # noqa: BLE001 - the queue is the boundary
        log.exception("job %s (%s) 실패", job.id, job.kind)
        async with session_scope() as db:
            row = await db.get(Job, job.id)
            if row is None:
                return
            row.attempts += 1
            row.last_error = f"{type(exc).__name__}: {exc}"[:2000]
            if row.attempts >= row.max_attempts:
                row.status = JobStatus.FAILED
                row.finished_at = utcnow()
            else:
                delay = BACKOFF_SECONDS[
                    min(row.attempts - 1, len(BACKOFF_SECONDS) - 1)
                ]
                row.status = JobStatus.QUEUED
                row.run_at = utcnow() + timedelta(seconds=delay)
                row.locked_at = None
                row.locked_by = None
        return

    async with session_scope() as db:
        row = await db.get(Job, job.id)
        if row:
            row.attempts += 1
            row.status = JobStatus.DONE
            row.finished_at = utcnow()
            row.last_error = None


async def run_due_jobs(limit: int | None = None) -> int:
    """Claim and run one batch. Returns how many jobs ran."""
    async with session_scope() as db:
        claimed = await _claim(db, limit or settings.worker_batch_size)
    if not claimed:
        return 0
    await asyncio.gather(*(_execute(job) for job in claimed))
    return len(claimed)


async def reclaim_stale(older_than_s: float = 900.0) -> int:
    """Return jobs abandoned by a crashed worker to the queue."""
    cutoff = utcnow() - timedelta(seconds=older_than_s)
    async with session_scope() as db:
        result = await db.execute(
            update(Job)
            .where(Job.status == JobStatus.RUNNING, Job.locked_at < cutoff)
            .values(status=JobStatus.QUEUED, locked_at=None, locked_by=None)
            .execution_options(synchronize_session=False)
        )
        return int(result.rowcount or 0)
