"""Port protocols — the complete boundary between this runtime and any host.

Contract: specs/001-agent-runtime/contracts/agent-deps.md

This module imports NOTHING concrete. No vector-store client, no bus client, no
provider SDK, no database driver. That is enforced by
scripts/check-import-boundaries.py, not by convention: a single concrete import
here would make every downstream module transitively depend on a backend and
quietly end this repo's portability.
"""

from __future__ import annotations

from collections.abc import AsyncIterator, Sequence
from typing import Any, Protocol, TypedDict, runtime_checkable

__all__ = [
    "AgentDeps",
    "ApprovalStore",
    "Bus",
    "Candidate",
    "LLMGatewayClient",
    "Meter",
    "MemoryService",
    "Policy",
    "Recorder",
    "RetrievalService",
    "SecurityCtx",
    "StreamWriter",
    "ToolRegistry",
]


class SecurityCtx(TypedDict):
    """Two tiers: a domain-agnostic core the runtime reads, and an opaque bag it does not.

    The runtime reads the core and passes ``claims`` through untouched. Only the
    injected deps (RetrievalService, ToolRegistry, Policy) may dereference
    ``claims``. An AST scan asserts no graph node ever subscripts it.

    ``ctx`` is stamped by the HOST's trusted layer -- never by a client, and never
    derived from model, tool, or document output. A ``ctx`` a caller can influence
    is a privilege-escalation primitive, not a parameter.
    """

    tenant: str
    principal: str
    agent_role: str
    allowed_tools: list[str]
    trace_id: str
    stream_id: str
    claims: dict[str, Any]


class Candidate(TypedDict):
    """One retrieved chunk. ``score`` is backend-native and not comparable across backends."""

    doc_id: str
    chunk_id: str
    text: str
    score: float
    metadata: dict[str, Any]


@runtime_checkable
class RetrievalService(Protocol):
    """Fetch candidate context under the caller's visibility predicate.

    The predicate MUST be applied INSIDE the store as a pre-filter. Post-filtering
    in Python is a correctness bug even when the output looks identical: it means
    the store returned rows the caller may not see.
    """

    async def search(
        self,
        query: str,
        ctx: SecurityCtx,
        *,
        limit: int,
        doc_ids: Sequence[str] | None = None,
    ) -> list[Candidate]:
        """Return candidates, or ``[]`` when nothing matches.

        An empty result is a valid answer state, NOT an error -- raising here would
        turn "nothing to say" into a failed run.

        ``doc_ids`` conjoins a document-scope term. It narrows only; it can never
        widen past what ``ctx`` permits.
        """
        ...


@runtime_checkable
class Policy(Protocol):
    """The access model. PURE -- no I/O, no clock, no randomness.

    Purity is what makes a Policy exhaustively testable and what stops it failing
    open on a network blip. A manifest may SELECT a Policy by name; it may never BE
    one.
    """

    def permit(self, action: str, ctx: SecurityCtx) -> bool:
        """May this action happen? Unknown actions MUST return False (fail closed)."""
        ...

    def lower(self, ctx: SecurityCtx, target: str) -> Any:
        """Lower ``ctx.claims`` into a store-native predicate (RLS GUCs, payload filter)."""
        ...


@runtime_checkable
class ToolRegistry(Protocol):
    """Dispatch the tool catalog. Enforcement lives in the shared wrapper, never the transport."""

    def list_tools(self, agent_role: str) -> list[dict[str, Any]]: ...

    async def call(self, name: str, args: dict[str, Any], ctx: SecurityCtx) -> Any:
        """Invoke a tool.

        MUST write exactly one audit entry per call THROUGH ``Recorder`` -- including
        on failure. A tool call that cannot be audited must not run.
        """
        ...


@runtime_checkable
class LLMGatewayClient(Protocol):
    """Any OpenAI-wire endpoint.

    The runtime holds NO provider key and names only gateway aliases
    (fast/smart/embed/rerank), never concrete model IDs -- so a model swap is a
    gateway config change, invisible here.
    """

    async def complete(self, req: dict[str, Any], *, deadline: float) -> Any: ...

    def stream(self, req: dict[str, Any], *, deadline: float) -> AsyncIterator[Any]:
        """Stream tokens. ``deadline`` is the REMAINING run budget, so the gateway can
        refuse rather than overrun it."""
        ...

    async def embed(self, texts: Sequence[str]) -> list[list[float]]: ...


@runtime_checkable
class MemoryService(Protocol):
    """Cross-session recall. Degrades to a no-op yielding ``[]``."""

    async def recall(self, ctx: SecurityCtx, query: str) -> list[Any]:
        """Recall memories, re-filtered against CURRENT clearance.

        Never trust a prior turn's snapshot: filtering only at write time means a
        demotion never takes effect, which converts a clearance change into a
        permanent leak.
        """
        ...

    async def write(self, ctx: SecurityCtx, items: Sequence[Any]) -> None: ...


@runtime_checkable
class StreamWriter(Protocol):
    """Transport-agnostic event emission. Any host-specific adapter stays BEHIND this."""

    async def emit(self, event: dict[str, Any]) -> None: ...


@runtime_checkable
class Bus(Protocol):
    """Worker-role fan-out. Bindings: inprocess | redis_streams | jetstream.

    A single-container deployment binds ``inprocess`` and runs no broker at all.
    """

    async def publish(self, subject: str, payload: bytes) -> None: ...

    def subscribe(self, subject: str, group: str | None = None) -> AsyncIterator[Any]: ...


@runtime_checkable
class Meter(Protocol):
    """Spend EMISSION. The runtime never writes a ledger; the host does."""

    async def emit_spend(
        self, ctx: SecurityCtx, op: str, units: int, idem_key: str
    ) -> None:
        """Emit a spend event.

        ``idem_key`` exists because the runtime CANNOT guarantee exactly-once
        emission under redelivery. A host that assumes otherwise will double-charge,
        so the host MUST reject duplicates by this key.
        """
        ...


@runtime_checkable
class Recorder(Protocol):
    """Audit emission. The host owns the tamper-evident chain head; the runtime is a
    writer, never the authority. No bodies -- refs and hashes only."""

    async def record(self, entry: dict[str, Any]) -> None: ...


@runtime_checkable
class ApprovalStore(Protocol):
    """Human-in-the-loop gate persistence.

    Bind ``None`` when no action tool is enabled. Do NOT bind a stub that
    auto-approves -- that silently removes the gate rather than declaring its absence.
    """

    async def open_gate(self, ctx: SecurityCtx, subject: dict[str, Any], prompt: str) -> str: ...

    async def await_decision(self, gate_id: str) -> dict[str, Any]:
        """Block until a HUMAN decision exists. Never derived from model or tool output."""
        ...


class AgentDeps(TypedDict):
    """Assembled once per worker; passed via ``config['configurable']['deps']``.

    Nodes are pure functions of ``(state, config)`` and never import a concrete
    client at module scope.
    """

    retrieval: RetrievalService
    memory: MemoryService
    llm: LLMGatewayClient
    tools: ToolRegistry
    emit: StreamWriter
    meter: Meter
    audit: Recorder
    approvals: ApprovalStore | None
