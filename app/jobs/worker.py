"""Background worker.

Two ways to run it:

* **In-process** (default, ``SIKPAN_RUN_WORKER_IN_PROCESS=true``) — a task on
  the API's event loop. Right for Phase 1/2, where there is one box.
* **Standalone** (``python -m app.jobs.worker``) — a separate process, which is
  what you want in production so a slow model call can't starve request
  handling.

Both share the same claim logic, so running several is safe.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import signal

from app.config import settings
from app.db import dispose_engine
from app.jobs import handlers  # noqa: F401 - registers the handlers
from app.jobs.queue import reclaim_stale, run_due_jobs

log = logging.getLogger(__name__)

RECLAIM_EVERY_N_TICKS = 60


async def worker_loop(stop: asyncio.Event | None = None) -> None:
    stop = stop or asyncio.Event()
    ticks = 0
    log.info("worker started")
    while not stop.is_set():
        ticks += 1
        try:
            ran = await run_due_jobs()
            if ticks % RECLAIM_EVERY_N_TICKS == 0:
                reclaimed = await reclaim_stale()
                if reclaimed:
                    log.warning("중단된 job %d개를 큐로 되돌렸습니다", reclaimed)
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 - the loop must never die
            log.exception("worker tick 실패")
            ran = 0

        if not ran:
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(
                    stop.wait(), timeout=settings.worker_poll_interval_s
                )
    log.info("worker stopped")


def main() -> None:  # pragma: no cover - process entrypoint
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s :: %(message)s",
    )

    async def runner() -> None:
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            with contextlib.suppress(NotImplementedError):
                loop.add_signal_handler(sig, stop.set)
        try:
            await worker_loop(stop)
        finally:
            await dispose_engine()

    asyncio.run(runner())


if __name__ == "__main__":  # pragma: no cover
    main()
