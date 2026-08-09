<!-- Extracted from aisat-intel@369756e. Promotes the agent-graph.md "Extraction
     checklist" from a descriptive list into a normative host contract, and
     absorbs the host-side obligations that were previously implicit in
     authorizer-ports.md / metering-ports.md / audit-ports.md (which stayed in
     aisat-intel). -->

# Contract: Host Integration — what embedding this runtime obliges you to do

**Port surface**: [agent-deps.md](./agent-deps.md) | **Composition**: [agent-runtime.md](./agent-runtime.md) | **Graph internals**: [agent-graph.md](./agent-graph.md) | **Status**: **normative for hosts**. A host that satisfies every MUST here can embed the runtime without forking it. A host that skips one has not integrated the runtime — it has forked the guarantees.

Every obligation below has a **working default that ships with the runtime**. Standalone, they all function: the agent authenticates, meters its own usage, moderates, gates, and enforces its access floor without a host. Overriding one is an **upgrade to your system's version**, not a rescue from a stub.

| Obligation | Default (works standalone) | Override when |
|---|---|---|
| H1 identity | single-user or explicit user list, fail-closed on unknown | you have an auth system (OIDC, SSO, device tokens) |
| H2 access floor | the store's own predicate — RLS (Profile B) or query (Profile C) | you have tenant middleware, or need a second lowering |
| H3 metering | **real local usage ledger** — tokens, cost, per principal, idempotent | you bill, or your ledger is authoritative elsewhere |
| H4 moderation | **real check via the gateway's moderation endpoint**, fail-closed on error | you have a provider or policy of your own |
| H5 gates | local approval store with a resolve surface | your approvals live in your product's UI |

> **No hollow defaults.** A default that does nothing is worse than no default at all: it makes a broken deployment look configured. If a capability cannot be implemented usefully without host context, the runtime **refuses to start without a binding** rather than shipping a no-op that silently passes.
>
> This is why H3 is a real ledger and not a no-op counter, and why H4 calls a real endpoint rather than returning `allow`. An unmetered or unmoderated agent should be something you **chose**, explicitly, not something you inherited by not looking.

---

## The five host obligations

### H1 — Stamp `ctx` in a trusted layer (NON-NEGOTIABLE)

The host MUST populate `SecurityCtx` from an authenticated session or token, in code the client cannot influence.

- `tenant` / `principal` MUST come from the verified session, **never** from a request body, header, or tool argument.
- `claims` MUST carry every authorization fact the host's `Policy` and `RetrievalService` need.
- `ctx` MUST NOT be derived, even partially, from model output, retrieved document content, or tool results.

> A `ctx` a caller can influence is a privilege-escalation primitive. This is the single obligation whose violation cannot be detected from inside the runtime — the runtime cannot tell a trustworthy `tenant` from a forged one, which is exactly why stamping it is *your* job and why it is listed first.

**When a chat channel is attached**, H1 takes the concrete form of an `IdentityBinder` ([channels.md](./channels.md)): a function from a platform identity (Discord snowflake, Slack `(team, user)`, WeChat OpenID) to a `SecurityCtx`.

- It MUST return `None` for anyone it does not recognize, and the runtime then refuses the message.
- It MUST NOT fall back to an anonymous or default identity. On a public Discord guild or a Slack workspace with guests, *"unrecognized user"* is the normal case, not the edge case — a default identity there hands your corpus to whoever finds the bot.
- Bind on the **full** platform key: `(team_id, user_id)` for Slack, not `user_id`; UnionID rather than per-app OpenID if one person spans several WeChat apps.

### H2 — Enforce the access floor below the agent (NON-NEGOTIABLE)

Visibility MUST be enforced at **row granularity, inside the store**, beneath the graph.

- Set your store's tenant/principal context per request (for Postgres: the RLS GUCs) **before** any query the runtime triggers.
- Lower `claims` into a store-native predicate via `Policy.lower`.
- Never enforce visibility by prompt, by tool-boundary RBAC, or by post-filtering results.

The number of lowerings is a deployment detail — RLS **plus** a vector pre-filter on a two-store profile, RLS **alone** on a single-store profile. Fewer copies to keep in parity is *simpler*, not weaker. What may never change is that the predicate runs **below** the agent.

### H3 — Meter and settle spend

The runtime emits spend through `Meter`; the host owns the ledger.

- The host MUST be the **single writer** of its credit ledger. The runtime never writes one.
- The host MUST honor the `idem_key` on every spend event and reject duplicates — redelivery is normal, and the runtime cannot promise exactly-once.
- A **refused** run (guard block), a **paused** run (open human gate), and a **rejected** gate MUST each settle to **zero** spend.

### H4 — Provide moderation behind `guard`

The `guard` node calls the host's moderation provider and **fails closed**: on timeout or provider error the query is blocked, zero credits are spent, and the run never reaches `retrieve`. A host that binds a permissive no-op has disabled a safety property, not configured one.

### H5 — Persist and resolve human gates

If any Category-D action tool is enabled, the host MUST supply an `ApprovalStore` where:

- a gate is visible and resolvable **only** by its designated approver;
- the first decision wins, and resolution is idempotent;
- the decision is **human-authored** — never derived from model or tool output;
- a `pending` gate blocks its action indefinitely and spends nothing.

If no action tool is enabled, bind `approvals: None`. Do not bind a stub that auto-approves.

---

## What travels, and what does not

| Travels with the runtime | Stays with the host |
|---|---|
| The graph, its nodes, and the state schema | Auth, sessions, token issuance |
| `AgentManifest` + `DomainPlugin` composition | The credit ledger and its single writer |
| Port protocols + conformance suites | RLS GUC plumbing / store session setup |
| Reference `RetrievalService` backends | The moderation provider |
| Prompt assets, evals, node telemetry | Transport (HTTP/SSE/WebSocket), UI |
| Chat-channel **protocol plumbing** (Discord/Slack/WeChat adapters) | The `IdentityBinder` — who a platform user *is* |
| Run budgets, reliability policy | A **full** ingestion pipeline (conversion, OCR, crawling, sandboxed parsing) |
| A **minimal** `Ingestor` default (files, URLs, text) | Document lifecycle, retention, versioning |

---

## Minimal integration

```python
from intel_agent import build_graph, AgentDeps
from intel_agent.retrieval import PgVectorRetrieval

deps = AgentDeps(
    retrieval=PgVectorRetrieval(dsn=DSN),
    memory=NoOpMemory(),
    llm=OpenAIWireClient(base_url=GATEWAY_URL),
    tools=my_plugin.tools(),
    emit=MyStreamWriter(),
    meter=MyMeter(),          # H3 — your ledger, your idempotency
    audit=MyRecorder(),
    approvals=None,           # H5 — no action tools enabled
)

graph = build_graph(manifest=load_manifest(agent_id), deps=deps)

async with my_store.tenant_scope(ctx):        # H2 — floor set BEFORE the graph runs
    async for event in graph.astream_events({"query": q, "ctx": ctx}):
        ...
```

`ctx` arrives from your authenticated session (H1). `tenant_scope` sets the store's row-level context (H2). Everything else the runtime brought with it.

---

## Verifying your integration

A host proves compliance by running the suites the runtime exports — this is the whole point of shipping them as importable code:

```python
from intel_agent.conformance import (
    RetrievalServiceContract, PolicyContract, MeterContract,
    ApprovalContract, AccessFloorContract,
)

class TestHostRetrieval(RetrievalServiceContract):
    impl = MyRetrievalService

class TestHostAccessFloor(AccessFloorContract):
    """Cross-tenant and above-clearance rows must be not_found, not filtered-after."""
    impl = MyRetrievalService
    policy = MyPolicy
```

Run them in **your** CI, against **your** implementations. Green suites are the integration test; a passing smoke test with a red conformance suite means the runtime is working by accident.

**H1 is the one obligation no suite can check for you.** Everything else here has a test; stamping `ctx` from a trusted layer is a property of code the runtime never sees. Review it deliberately.

---

## Versioning and breaking changes

- A change to any port protocol, to `SecurityCtx`, or to this document is **breaking for every host**.
- It bumps at least the minor version, names the affected hosts in the PR body, and lands **before** the host PR that consumes it — never in the same merge window.
- Adding an **optional** port with a documented degradation is additive.
- Narrowing a "degrades to" guarantee (making an optional port required) is **breaking**, even though nothing in the type signature changes.
