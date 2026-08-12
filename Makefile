.DEFAULT_GOAL := help
PY ?= python3
PORT ?= 8000

.PHONY: help install dev worker test seed lint fmt clean docker-up docker-down migrate revision

help: ## 사용 가능한 명령
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

install: ## 의존성 설치
	$(PY) -m pip install -e ".[dev,anthropic]"

dev: ## 개발 서버 (워커 인프로세스, 자동 리로드)
	$(PY) -m uvicorn app.main:app --reload --host 0.0.0.0 --port $(PORT)

worker: ## 워커를 별도 프로세스로 실행 (프로덕션 형태)
	$(PY) -m app.jobs.worker

test: ## 테스트
	$(PY) -m pytest -q

seed: ## 영양·운동 기준 데이터 적재 (멱등)
	$(PY) scripts/seed.py

import-mfds: ## 식약처 통합 DB CSV 적재 — make import-mfds FILE=path.csv
	$(PY) scripts/import_mfds.py $(FILE)

migrate: ## 최신 마이그레이션 적용
	alembic upgrade head

revision: ## 마이그레이션 생성 — make revision M="설명"
	alembic revision --autogenerate -m "$(M)"

docker-up: ## Postgres + API + 워커 기동
	docker compose up --build -d

docker-down: ## 정리
	docker compose down -v

clean: ## 로컬 산출물 삭제
	rm -rf .pytest_cache **/__pycache__ sikpan.db sikpan.db-wal sikpan.db-shm var/media
