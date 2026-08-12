FROM python:3.11-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /srv

# Pillow needs the image libs; asyncpg builds fine from the wheel.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libjpeg62-turbo zlib1g curl \
    && rm -rf /var/lib/apt/lists/*

COPY pyproject.toml ./
COPY app ./app
RUN pip install --upgrade pip && pip install ".[postgres,anthropic]"

COPY web ./web
COPY scripts ./scripts
COPY alembic.ini ./
COPY migrations ./migrations

# Photos and the SQLite file live here; mount a volume over it in production.
RUN mkdir -p /srv/var/media && useradd -m -u 10001 sikpan && chown -R sikpan /srv
USER sikpan

EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS http://localhost:8000/api/healthz || exit 1

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
