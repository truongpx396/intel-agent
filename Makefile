SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# intel-agent — the self-contained agent runtime extracted from aisat-intel.
# Single runtime (Python 3.12): no Go tier, no frontend, so no per-runtime guards.
# Targets are still tolerant of a specs-only checkout so `make ci` runs green
# before any code lands.

IMAGE_TAG ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)
REGISTRY ?= docker.io
IMAGE_PREFIX ?= intel-agent

COMPOSE_PROFILE_B := deploy/compose.profile-b.yml

.PHONY: help
help: ## List targets
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk -F':.*?## ' '{printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}'

# ------------------------------- lint --------------------------------------
.PHONY: lint
lint: ## Lint + format check
	@if [ -f pyproject.toml ] && [ -d src ]; then uv run ruff check . && uv run ruff format --check .; else echo "skip lint (no src/ yet)"; fi

.PHONY: typecheck
typecheck: ## Type-check (ports are a published contract — keep them typed)
	@if [ -d src ]; then uv run mypy src; else echo "skip typecheck (no src/ yet)"; fi

# ------------------------------- test --------------------------------------
.PHONY: test
test: ## Unit tests
	@if [ -d tests ]; then uv run pytest -m "not integration and not smoke"; else echo "skip test (no tests/ yet)"; fi

.PHONY: test-integration
test-integration: ## Integration tests (testcontainers: postgres+pgvector, redis)
	@if [ -d tests ]; then uv run pytest -m integration; else echo "skip integration"; fi

.PHONY: conformance
conformance: ## Port conformance suites — the contract host repos also run
	@if [ -d tests/conformance ]; then uv run pytest tests/conformance -v; else echo "skip conformance (not built yet)"; fi

# ------------------------------- docs --------------------------------------
.PHONY: check-links
check-links: ## Verify every relative markdown link resolves
	@./scripts/check-links.sh

# ------------------------------- profile B ---------------------------------
# The reason this repo exists: the runtime stands up and answers a cited query
# with NO Qdrant, NO NATS, and NO Go kernel bound.
# Contract: specs/001-agent-runtime/contracts/agent-runtime.md § Profile B.
.PHONY: up
up: ## Stand up the self-contained profile (postgres+pgvector, redis, litellm)
	docker compose -f $(COMPOSE_PROFILE_B) up -d --wait

.PHONY: down
down: ## Tear down the self-contained profile
	docker compose -f $(COMPOSE_PROFILE_B) down -v

.PHONY: logs
logs: ## Tail the self-contained profile
	docker compose -f $(COMPOSE_PROFILE_B) logs -f

.PHONY: smoke
smoke: ## Prove a cited answer end-to-end on the standalone profile
	@if [ -d tests ]; then uv run pytest -m smoke -v; else echo "skip smoke (not built yet)"; fi

.PHONY: smoke-assert-isolation
smoke-assert-isolation: ## Fail if a forbidden backend (Qdrant/NATS) got bound
	@./scripts/assert-profile-b-isolation.sh

# ------------------------------- build -------------------------------------
.PHONY: build
build: ## Build the runtime image
	@if [ -f Dockerfile ]; then docker build -t $(IMAGE_PREFIX):$(IMAGE_TAG) .; else echo "skip build (no Dockerfile yet)"; fi

.PHONY: lock
lock: ## Regenerate uv.lock (never hand-merge it — regenerate after a rebase)
	uv lock

# ------------------------------- security ----------------------------------
.PHONY: scan
scan: ## Dependency audit
	@if [ -f pyproject.toml ]; then uvx pip-audit || echo "pip-audit reported advisories"; fi

# ------------------------------- aggregate ---------------------------------
.PHONY: ci
ci: lint typecheck test conformance check-links ## Local gate — mirrors GitHub Actions CI
