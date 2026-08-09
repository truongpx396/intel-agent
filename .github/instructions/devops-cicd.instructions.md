---
description: 'Production practices for DevOps and CI/CD: Docker, multi-stage builds, Docker Compose, Makefiles, and GitHub Actions. Build, test, security-scan, and release standards, with worked examples for Go, Python/UV, and Node/React toolchains.'
applyTo: '**/Dockerfile,**/Dockerfile.*,**/*.Dockerfile,**/.dockerignore,**/docker-compose*.yml,**/docker-compose*.yaml,**/compose*.yml,**/compose*.yaml,**/Makefile,**/*.mk,**/.github/workflows/*.yml,**/.github/workflows/*.yaml,**/.github/actions/**'
---

# DevOps & CI/CD — Production Practices

Standards for containerizing, building, testing, and releasing a service. Applies to
Dockerfiles, `.dockerignore`, Compose files, Makefiles, and GitHub Actions workflows.

The principles are toolchain-independent; the worked examples use **Go**, **Python + UV**, and
**Node/React** because those cover the compiled-binary, interpreted-with-lockfile, and
static-asset build shapes respectively. Adapt the example to whichever toolchains the project
actually uses, and ignore the sections for languages it does not.

Complements [backing-services.instructions.md](./backing-services.instructions.md) (the
services these images connect to), [security-and-owasp.instructions.md](./security-and-owasp.instructions.md)
(secrets, supply chain), [go.instructions.md](./go.instructions.md), and
[python.instructions.md](./python.instructions.md).

## Cross-Cutting Principles

- **Reproducible builds.** Pin base image digests or exact tags, pin tool versions, and commit
  lockfiles (`go.sum`, `uv.lock`, `package-lock.json`/`pnpm-lock.yaml`). `latest` is banned in
  build and deploy artifacts.
- **Least privilege at every layer.** Containers run as a non-root user; CI jobs use minimal,
  scoped tokens (`permissions:` block); registries use short-lived OIDC credentials, not
  long-lived keys.
- **Fail fast and loud.** Lint, type-check, test, and scan gates block merge. A red pipeline is
  never merged around.
- **Same artifact everywhere.** Build the image once, tag it by immutable digest, and promote
  that exact digest through environments. Never rebuild per environment.
- **Cache deliberately, never for correctness.** Layer and dependency caches speed builds; the
  build must still be correct on a cold cache. Cache keys include lockfile hashes.
- **Everything in version control.** Dockerfiles, Compose, Makefile, and workflows are reviewed
  like application code — no undocumented, hand-run build steps.

---

## Docker & Multi-Stage Builds

### Image Structure

- **Use multi-stage builds** to separate build-time tooling from the runtime image. The final
  stage contains only the binary/artifact and its runtime dependencies — no compilers, no
  package managers, no source.
- Pick the smallest correct base for the runtime stage:
  - **Go**: `scratch` or `gcr.io/distroless/static` for static binaries (`CGO_ENABLED=0`).
  - **Python**: `python:3.12-slim` (or distroless) — never full `python:3.12`.
  - **React/Vite**: build with Node, serve static assets from `nginx:alpine`/`caddy` or a CDN;
    Node is not in the runtime image.
- Pin base images by tag **and** digest: `FROM python:3.12-slim@sha256:...`. Digests make the
  build tamper-evident (supply-chain integrity, A03/A08).
- Order layers by change frequency: copy dependency manifests and install **before** copying
  source, so the dependency layer caches across source edits.

```dockerfile
# GOOD — Go multi-stage, static, non-root, distroless
FROM golang:1.23-bookworm@sha256:... AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download          # cached until go.sum changes
COPY . .
ARG TARGETOS TARGETARCH
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w" -o /out/api ./cmd/api

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/api /api
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/api"]
```

```dockerfile
# GOOD — Python + UV, deps cached separately, non-root runtime
FROM python:3.12-slim@sha256:... AS build
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
WORKDIR /app
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-project --no-dev
COPY . .
RUN --mount=type=cache,target=/root/.cache/uv uv sync --frozen --no-dev

FROM python:3.12-slim@sha256:...
RUN useradd --create-home --uid 10001 appuser
WORKDIR /app
COPY --from=build --chown=appuser:appuser /app /app
ENV PATH="/app/.venv/bin:$PATH"
USER appuser
ENTRYPOINT ["python", "-m", "app"]
```

### Security & Runtime

- **Never run as root.** Create a dedicated non-root user (`USER`) in the final stage; the
  process must not need root to start.
- **No secrets in images or build args.** Do not `COPY .env`, bake API keys into layers, or pass
  secrets via `ARG` (they persist in history). Use BuildKit secret mounts
  (`RUN --mount=type=secret,...`) for build-time credentials and inject runtime secrets via the
  orchestrator/env at run time.
- Add a `.dockerignore` (`.git`, `node_modules`, `.env*`, `__pycache__`, `dist`, `*.log`, test
  fixtures) so the build context stays small and secrets can't leak into the context.
- Set a `HEALTHCHECK` (or rely on the orchestrator probe) that hits the app's liveness/readiness
  endpoints (e.g. `/livez` and `/readyz`).
- Make the root filesystem read-only where possible (`--read-only` + explicit writable
  `tmpfs`); drop Linux capabilities not needed.
- Pin a specific `EXPOSE` port and run one concern per image. Where several roles share a codebase
  (api / worker / relay), prefer **one image, N roles**: build once and select the role via the
  entrypoint or command rather than maintaining a Dockerfile per role.
- **Scan every image** in CI (Trivy/Grype) for OS + dependency CVEs; fail on HIGH/CRITICAL with a
  triaged allowlist. Generate an SBOM (Syft) and attach provenance/attestations for releases.
- Build multi-arch (`linux/amd64,linux/arm64`) with `docker buildx` when targets require it.

---

## Docker Compose (Local Dev & Integration)

- Compose is for **local development and CI integration tests**, not production orchestration
  (that's k8s). Keep prod concerns (autoscaling, secrets manager) out of it.
- Pin service image tags; don't use `latest`. Compose should mirror the real backing services the
  app talks to — see [backing-services.instructions.md](./backing-services.instructions.md) for the
  per-service configuration rules.
- Add **healthchecks** to every backing service and gate app startup with
  `depends_on: { condition: service_healthy }` so the app doesn't race a not-ready database.
- Never hardcode credentials — use an `.env` file (gitignored) with a committed `.env.example`
  documenting every variable. Reference via `${VAR}` with sane non-secret defaults only.
- Use named volumes for stateful services; scope published ports to `127.0.0.1` in dev so
  services aren't exposed on the network.
- Separate concerns with override files (`docker-compose.override.yml` for dev,
  `docker-compose.ci.yml` for pipeline) instead of branching logic inside one file.

```yaml
services:
  postgres:
    image: postgres:16.4
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?set in .env}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER:-postgres}"]
      interval: 5s
      timeout: 3s
      retries: 10
    volumes: [pgdata:/var/lib/postgresql/data]
    ports: ["127.0.0.1:5432:5432"]

  api:
    build: { context: ./backend-go, target: build }
    depends_on:
      postgres: { condition: service_healthy }
    env_file: [.env]

volumes:
  pgdata:
```

---

## Makefile (Task Runner)

- Use the Makefile as the **single, documented entrypoint** for common tasks so developers and CI
  run the exact same commands. CI steps call `make <target>`, not ad-hoc shell.
- Declare `.PHONY` for every non-file target; add a self-documenting `help` default target.
- Fail hard: put `.SHELLFLAGS := -eu -o pipefail -c` and `SHELL := bash` at the top so a failing
  sub-command aborts the target.
- Keep targets small, composable, and toolchain-scoped. Standard set:
  `help`, `setup`, `lint`, `fmt`, `typecheck`, `test`, `build`, `docker-build`, `scan`, `up`,
  `down`, `migrate`, `ci`. `make ci` runs the full gate locally = what the pipeline runs.
- Prefer real dependencies (prerequisites) over manual ordering; use variables for versions/tags
  (`IMAGE_TAG ?= $(shell git rev-parse --short HEAD)`).

Example — the directory names and per-language commands are illustrative; keep the structure and
substitute the project's own layout and tools:

```makefile
SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

IMAGE_TAG ?= $(shell git rev-parse --short HEAD)

.PHONY: help lint test build ci
help: ## List targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk -F':.*?## ' '{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

lint: ## Run all linters
	cd backend-go && golangci-lint run ./...
	cd backend-python && uv run ruff check .
	cd frontend && pnpm lint

test: ## Run all test suites
	cd backend-go && go test -race -count=1 ./...
	cd backend-python && uv run pytest
	cd frontend && pnpm test

ci: lint test build ## Full gate — mirrors GitHub Actions
```

---

## GitHub Actions (CI/CD)

### Workflow Hygiene

- **Pin every action to a commit SHA**, not a moving tag: `uses: actions/checkout@<sha>  # v4.x`.
  A mutable tag is a supply-chain risk (A03/A08). Dependabot updates the pins.
- Set a **least-privilege `permissions:` block** at the workflow root (`contents: read`) and
  elevate per-job only where needed (`packages: write`, `id-token: write` for OIDC). Never leave
  the default broad token.
- **Never store long-lived cloud keys as secrets.** Use **OIDC** (`id-token: write`) to assume a
  scoped cloud/registry role at run time.
- Reference secrets via `${{ secrets.X }}`; never `echo` them, never put them in step names or
  logs. Mask any derived values.
- Use `concurrency` to cancel superseded runs on a branch/PR; set an explicit job `timeout-minutes`
  so a hung job can't burn minutes indefinitely.
- Trigger deliberately: `pull_request` for the gate, `push` to `main`/tags for release. Guard
  release/deploy jobs with `if:` on ref and `environment:` protection rules (required reviewers).

### Pipeline Stages

- **Fast feedback first**, split by concern and run independent jobs in parallel:
  1. lint + format check + type-check
  2. unit tests (per toolchain, matrix on Go/Python/Node versions where relevant)
  3. build images (`docker buildx`, layer cache via `cache-from`/`cache-to` or registry cache)
  4. integration tests (Compose-based, against real backing services)
  5. security scans — `npm audit`/`uv`/`govulncheck`, Trivy image scan, secret scan (gitleaks),
     SBOM
- Cache dependency downloads keyed on lockfile hashes
  (`actions/setup-go` / `setup-python` + UV cache / `setup-node` + pnpm store). Correctness must
  not depend on the cache.
- Upload test results, coverage, SBOM, and scan reports as artifacts for traceability.
- **Build once, promote by digest.** The build job outputs the image digest; deploy jobs consume
  that exact digest. Tag images with the immutable git SHA (plus optional semver on release).

### Release & Deploy

- Deploys are **gated and auditable**: protected `environment`, required approvals for prod,
  and a deploy job that only runs on the intended ref.
- Sign/attest release images (cosign / build provenance / SLSA) and verify signatures before
  deploy.
- Run database migrations as an explicit, ordered step (expand/contract — see
  backing-services PostgreSQL rules), never implicitly on app boot in a way that races replicas.
- Provide a documented rollback (redeploy previous digest); prefer forward-fix but keep rollback
  ready.

```yaml
name: ci
on:
  pull_request:
  push: { branches: [main] }

permissions:
  contents: read

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  gate:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@<sha>            # v4.x
      - uses: actions/setup-go@<sha>            # v5.x
        with: { go-version: '1.23', cache: true }
      - run: make ci

  image:
    needs: gate
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
      id-token: write          # OIDC to registry
    steps:
      - uses: actions/checkout@<sha>
      - uses: docker/setup-buildx-action@<sha>
      - uses: docker/build-push-action@<sha>
        with:
          context: ./backend-go
          push: ${{ github.event_name == 'push' }}
          tags: ghcr.io/org/api:${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
          provenance: true
          sbom: true
```

---

## DevOps / CI-CD Checklist

Before merging changes that touch build, containerization, or pipelines, verify:

### Docker
- [ ] Multi-stage build; runtime stage has no build tools/source
- [ ] Base images pinned by tag + digest; smallest correct base (distroless/slim/scratch)
- [ ] Runs as a non-root `USER`; no secrets in layers/`ARG`; `.dockerignore` present
- [ ] Dependency layer copied/installed before source (cache-friendly)
- [ ] Image scanned (Trivy/Grype) with HIGH/CRITICAL gate; SBOM generated
- [ ] `HEALTHCHECK` / orchestrator probe wired to `/livez`/`/readyz`

### Docker Compose
- [ ] Pinned service tags; healthchecks + `depends_on: service_healthy`
- [ ] No hardcoded creds (`.env` gitignored, `.env.example` committed); ports bound to localhost
- [ ] Named volumes for stateful services; dev/CI overrides split out

### Makefile
- [ ] `SHELL := bash` + `.SHELLFLAGS := -eu -o pipefail -c`; `.PHONY` on non-file targets
- [ ] Self-documenting `help`; `make ci` mirrors the pipeline gate

### GitHub Actions
- [ ] Actions pinned to commit SHA; least-privilege `permissions:` block
- [ ] OIDC for cloud/registry (no long-lived keys); secrets never logged
- [ ] `concurrency` cancel + per-job `timeout-minutes`
- [ ] Parallel lint/test/build/scan; caches keyed on lockfile hashes
- [ ] Build once → promote by digest; images tagged by git SHA; provenance/SBOM on release
- [ ] Deploy gated by protected `environment` + approvals; migrations explicit; rollback documented
