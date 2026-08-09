---
description: 'Instructions for writing Python code following idiomatic, modern (3.12+) practices with UV for environment and dependency management'
applyTo: '**/*.py,**/pyproject.toml,**/uv.lock'
---

# Python Development Instructions

Follow idiomatic, modern Python practices when writing Python code. These instructions
target Python 3.12+ and are based on [PEP 8](https://peps.python.org/pep-0008/),
[PEP 20 (The Zen of Python)](https://peps.python.org/pep-0020/), the
[official typing docs](https://docs.python.org/3/library/typing.html), and current
community standards.

The environment/dependency section assumes [UV](https://docs.astral.sh/uv/). If the project already
uses Poetry, pip-tools, or plain pip, follow the tool it uses — do not migrate a working project as
a side effect of an unrelated change — and apply every other section unchanged.

## General Instructions

- Write simple, explicit, and readable code; follow the Zen of Python
- Prefer clarity over cleverness; avoid premature abstraction
- Keep the happy path flat; return early to reduce nesting
- Make functions small and single-purpose
- Leverage the standard library before reaching for third-party packages
- Use full type annotations on all public functions, methods, and module-level constants
- Write self-documenting code with clear, descriptive names
- Write comments and docstrings in English by default; translate only on user request
- Avoid using emoji in code, comments, and docstrings
- Target Python 3.12+ syntax and features (no compatibility shims for older versions unless required)

## Environment and Dependency Management (UV)

- Use UV for all environment and dependency operations; do not use bare `pip`, `pip-tools`, `poetry`, or `conda`
- Common commands:
  - `uv sync` — install/sync the environment from `pyproject.toml` + `uv.lock`
  - `uv add <package>` / `uv add --dev <package>` — add runtime / dev dependencies
  - `uv remove <package>` — remove a dependency
  - `uv run <command>` — run a command inside the project environment (e.g., `uv run pytest`)
  - `uv lock` — update the lockfile; `uv lock --upgrade` to bump versions
  - `uv tool run <tool>` (alias `uvx`) — run a one-off tool without installing it as a dependency
- Always commit `uv.lock`; treat it as the source of truth for reproducible installs
- Declare dependencies in `pyproject.toml` ([PEP 621] `[project]` table); never edit `uv.lock` by hand
- Pin the Python version with `.python-version` or `requires-python` in `pyproject.toml`
- Prefer `uv run` over manually activating the virtual environment so commands always use the locked environment
- Keep runtime and development dependencies separated (use dependency groups / `--dev`)

## Project Structure

- Use the `src/` layout (`src/<package>/`) to avoid import ambiguity
- Keep packages small and cohesive; group by feature/domain, not by layer when practical
- Put executable entry points behind `if __name__ == "__main__":` and expose them via `[project.scripts]`
- Avoid `util`/`common`/`misc` catch-all modules
- Keep `__init__.py` thin; use it for the package's public API, not heavy logic
- Avoid circular imports; if they appear, the module boundaries are likely wrong

## Naming Conventions

- `snake_case` for variables, functions, methods, modules, and packages
- `PascalCase` for classes and type aliases
- `UPPER_SNAKE_CASE` for module-level constants
- Prefix internal/non-public names with a single leading underscore (`_helper`)
- Use descriptive names; reserve single-letter names for short scopes (loop indices, comprehensions)
- Avoid shadowing builtins (`id`, `type`, `list`, `dict`, `input`)

## Typing

- Annotate all public function signatures, including return types
- Use modern built-in generics: `list[int]`, `dict[str, int]`, `tuple[int, ...]` (not `typing.List`, etc.)
- Use `X | None` instead of `Optional[X]`, and `X | Y` instead of `Union[X, Y]`
- Use `collections.abc` types (`Iterable`, `Sequence`, `Mapping`, `Callable`) for parameters; accept abstract types, return concrete ones
- Use `typing.Protocol` for structural typing instead of forcing inheritance
- Use `typing.Final` for constants and `typing.Literal` for fixed value sets
- Use `TypedDict`, `dataclasses`, or `pydantic` models for structured data rather than loose dicts
- Prefer `Self` (3.11+) for methods returning their own instance
- Type-check with a strict configuration (`mypy --strict` or `pyright`); treat type errors as failures
- Avoid `Any`; when an escape hatch is needed, isolate it and document why

## Code Style and Formatting

- Format and lint with [Ruff](https://docs.astral.sh/ruff/) (`uv run ruff format` and `uv run ruff check`)
- Follow PEP 8; let the formatter handle layout rather than hand-aligning
- Keep imports ordered: standard library, third-party, local — let Ruff/isort manage this
- Use absolute imports for clarity; reserve relative imports for tight intra-package references
- Prefer f-strings for interpolation; never build SQL or shell commands via f-strings (see Security)
- Use `pathlib.Path` for filesystem paths instead of `os.path` string manipulation

## Functions and Data

- Prefer keyword-only arguments for booleans and optional flags to improve call-site clarity
- Never use mutable default arguments (`def f(x: list = [])`); use `None` and create inside
- Use `@dataclass(slots=True, frozen=True)` for simple immutable value objects
- Use `pydantic` models at system boundaries (API/LLM I/O, config) for validation and parsing
- Prefer comprehensions and generator expressions over manual loops when they stay readable
- Use generators/`yield` for large or streaming sequences instead of building full lists in memory
- Unpack with care; avoid deeply nested unpacking that hurts readability

## Error Handling

- Catch the most specific exception possible; never use bare `except:`
- Avoid `except Exception` unless re-raising or at a clearly defined boundary (e.g., request handler)
- Chain exceptions with `raise NewError(...) from err` to preserve context
- Define a small hierarchy of custom exceptions for domain-specific errors
- Use `try/except/else/finally` appropriately; keep `try` blocks minimal
- Use context managers (`with`) for resource cleanup; write custom ones with `contextlib.contextmanager`
- Don't swallow errors silently; either handle meaningfully or propagate
- Don't both log and re-raise the same error at every level; log once at the boundary

## Async and Concurrency

- Use `async`/`await` for I/O-bound work (DB, Redis, NATS, HTTP, LLM calls); keep blocking calls out of the event loop
- Run blocking/CPU-bound work via `asyncio.to_thread` or a process pool; never block the loop
- Use `asyncio.TaskGroup` (3.11+) for structured concurrency instead of bare `create_task` without supervision
- Always propagate `cancellation`; don't suppress `asyncio.CancelledError`
- Pass timeouts to network/LLM operations (`asyncio.timeout`, client-level timeouts)
- Use `async with`/`async for` for async resources and streams
- For CPU-bound parallelism, use `multiprocessing`/`concurrent.futures.ProcessPoolExecutor`, not threads (GIL)

## Logging and Observability

- Use structured logging (`structlog` or stdlib `logging` with structured output); avoid `print` for application logs
- Attach contextual fields (request ID, trace ID, user ID) instead of formatting them into the message
- Choose appropriate levels (`debug`, `info`, `warning`, `error`); reserve `error` for actionable failures
- Never log secrets, tokens, passwords, or PII
- Trace LLM and pipeline operations with the project's existing observability stack (OpenTelemetry, and Langfuse or similar for LLM-specific spans); match what is already wired up rather than adding a second tracer
- Either log an error or raise it — avoid doing both at every layer

## LLM, RAG, and MCP

Apply this section only when the project builds LLM-backed features; skip it otherwise.

> For the security half of this surface — tool scoping, MCP trust, agent identity, memory/RAG
> poisoning, approval gates, token/cost ceilings — follow
> [ai-agent-security.instructions.md](./ai-agent-security.instructions.md), which is authoritative
> on agentic security. For the engineering half — control loop, durable state, context budgets, tool
> design, evals, telemetry — follow
> [ai-agent-engineering.instructions.md](./ai-agent-engineering.instructions.md). The rules below are
> the Python mechanics.

- Validate all LLM inputs and outputs at the boundary; treat model output as untrusted (see Security)
- Use `pydantic` schemas to parse and validate structured LLM responses; reject non-conforming output
- Keep prompts in versioned, reviewable modules/templates; do not concatenate raw user input into system prompts
- Set explicit timeouts, retries (with backoff), and token/cost limits on model and tool calls
- For LangGraph: keep node functions pure where possible, type the state with `TypedDict`/`pydantic`, and make graph edges explicit and testable
- For MCP servers/tools: validate tool arguments with schemas, return structured errors, and never expose secrets or internal stack traces to callers
- Stream responses where the UX benefits; ensure async generators are properly closed

## Testing

- Use `pytest`; run via `uv run pytest`
- Place tests under `tests/` mirroring the package structure; name files `test_*.py`
- Write focused, descriptive test names: `test_<unit>_<scenario>_<expected>`
- Prefer `pytest.mark.parametrize` for table-driven cases over loops
- Use fixtures for setup/teardown; keep them small and composable
- Test both success and failure paths, including edge cases and error handling
- Use `pytest-asyncio` for async tests; test cancellation and timeout behavior for async code
- Mock external services (LLMs, HTTP, DB) at boundaries; don't mock what you own internally
- Aim for meaningful coverage of critical paths rather than a coverage-percentage target

## Security Best Practices

- Validate and sanitize all external input at boundaries (use `pydantic` models)
- Use parameterized queries / ORM bindings for SQL; never build queries with f-strings or `%`
- Never pass user input to `subprocess` with `shell=True`; pass an args list and avoid the shell
- Never use `eval`, `exec`, `pickle`, or `yaml.load` (use `yaml.safe_load`) on untrusted data
- Use `secrets` (not `random`) for tokens, salts, and security-sensitive randomness
- Hash passwords with Argon2id (`argon2-cffi`); bcrypt is an acceptable fallback. Never use fast hashes (MD5, SHA-1, SHA-256) for passwords
- Load secrets from environment/secret manager; never hardcode credentials or commit `.env`
- Verify TLS certificates; never disable verification in production clients
- For full secure-coding requirements (injection, auth, secrets, headers, AI/LLM), follow `.github/instructions/security-and-owasp.instructions.md`, which takes precedence on security matters

## Documentation

- Write docstrings for all public modules, classes, and functions (PEP 257)
- Keep docstrings concise; describe purpose, parameters, returns, and raised exceptions when non-obvious
- Prefer self-documenting code; comment the *why*, not the *what*
- Keep documentation close to the code and update it when behavior changes

## Tools and Workflow

- `uv run ruff format` — format code
- `uv run ruff check --fix` — lint and autofix
- `uv run mypy` (or `pyright`) — static type checking
- `uv run pytest` — run tests
- `uv lock --upgrade` — update dependency versions deliberately
- Run formatting, linting, type checks, and tests before committing; wire them into pre-commit hooks
- Keep commits focused and atomic with meaningful messages

## Common Pitfalls to Avoid

- Mutable default arguments
- Bare `except:` or overly broad `except Exception`
- Blocking calls inside async functions
- Using `print` instead of structured logging for application output
- Building SQL/shell strings from user input
- Catching and silently ignoring exceptions
- Forgetting to close resources (use `with`/`async with`)
- Overusing `Any` and bypassing the type checker
- Comparing with `== None` / `== True` instead of `is None` / truthiness
- Leaking secrets or PII into logs and error responses
- Editing `uv.lock` by hand or skipping it in commits
