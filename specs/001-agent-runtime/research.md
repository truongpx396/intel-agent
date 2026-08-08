<!-- Extracted from aisat-intel@369756e (specs/001-contextengine-mvp/research.md).
     Carries the agent-relevant decisions (source §§5, 6, 7, 12, 13, 17, 19, 20,
     21, 22, 25), restated against the PORT boundary rather than against AISAT's
     concrete backing services. Host-specific sections (ingestion, credits,
     notifications, sandbox, scale-forward seams) stayed upstream and are linked
     rather than copied — one source of truth per decision. -->

# Research — Self-Contained Agent Runtime

**Plan**: [plan.md](./plan.md) | **Source**: [aisat-intel research.md](https://github.com/truongpx396/aisat-intel/blob/main/specs/001-contextengine-mvp/research.md)

---

## 1. Prompt-injection structural defenses (built, not deferred)

- **Decision**: Ship structural defenses from day one: (1) retrieved content wrapped in `<retrieved_document>` delimiters with a system rule that delimited text is **data, never commands**; (2) tool results never trigger new tool calls without the router re-deriving intent from the *original* classified intent; (3) a strict per-role `allowed_tools` allowlist enforced on every dispatch; (4) a read-only default tier, with action tools only behind a human gate; (5) an audit entry with a `result_hash` on every tool call. A `guard` node short-circuits disallowed input **before** any retrieval or spend.
- **Rationale**: Retrieved documents are untrusted content sitting on the core data path — the textbook injection vector. These defenses are cheap and structural rather than detective, which is what makes them hold. Required by AR-001/AR-002/AR-003 and SC-A04.
- **Alternatives considered**: Deferring injection handling to a later red-teaming phase — rejected: it leaves the primary data path exposed for the entire interim, and retrofitting delimiters after prompts exist is far more expensive than starting with them.

## 2. Async execution behind a `Bus` port (not hard-wired to a broker)

- **Decision**: Publishers and subscribers bind a `Bus` port fronting `publish` / `subscribe` / `queue-group` / `redeliver`, with three adapters: `jetstream`, `redis_streams`, and `inprocess`. A single-container deployment binds `inprocess` and has **no broker at all** — worker roles become direct function calls.
- **Rationale**: The durability semantics (durable pull consumers, redelivery, consumer-lag signal) are what a scaled host needs; none of them are what a standalone deployment needs. Putting them behind a port means the same binary serves both, and the broker earns its keep only when scaling out. Hard-wiring a broker would have made the standalone profile impossible without a fork.
- **Alternatives considered**: (a) In-process only — rejected: no durability, no independent worker scaling for a real host. (b) Core (non-durable) pub/sub as the dispatch transport — rejected: loses in-flight work on a crash and exposes no lag metric, and is unfixable later without rewriting every publisher.

## 3. Structured data via fixed tools, never generated SQL

- **Decision**: Structured-data questions are answered by fixed, parameterized, tenant-scoped tools. The model chooses a tool and supplies **typed arguments**; the SQL is hand-written and scoped.
- **Rationale**: Free-form generated SQL is an injection and exfiltration surface that cannot be reliably scoped to a tenant or a clearance. Fixed tools keep the access boundary in code, where it is reviewable and testable.
- **Alternatives considered**: Text-to-SQL — rejected: unbounded query surface, unsafe across tenants, and impossible to prove correct against SC-A01.

## 4. Context compression — a seam, not an implementation

- **Decision**: Leave a pre-send seam in the gateway client where a compression step can be inserted, but do not implement compression now.
- **Rationale**: Compression trades recall for tokens, and the trade is only measurable once real prompts and a real eval set exist. Building the seam is nearly free; building the policy early means tuning it against imagined traffic.
- **Alternatives considered**: Shipping a compressor immediately — rejected: unmeasurable, and a bad compression policy silently degrades answer quality in a way the smoke test cannot see.

## 5. Agent memory scoping

- **Decision**: Memory is stamped with tenant and principal on **write**, and re-filtered against **current** clearance on every **read**. A memory written when a principal had broader access is not readable after a demotion.
- **Rationale**: Memory is the sneakiest path around a visibility floor, because it looks like the agent's own knowledge rather than retrieved content. Filtering only at write time means a demotion never takes effect; filtering every turn means it takes effect on the next turn.
- **Alternatives considered**: Trusting a prior turn's snapshot — rejected: it converts a clearance change into a permanent leak.

## 6. Groundedness and self-correction — designed, deferred

- **Decision**: Reserve fixed insertion points for corrective-retrieval grading (after `memory`, before `generate`) and answer-faithfulness grading (after `generate`, before `suggest`), each with declared state keys. Do not build them now. Any correction loop is **depth-bounded** and **intent-pinned** — it re-derives only from the original query and pinned intent, never from tool or document output.
- **Rationale**: Fixing the insertion points now makes them additive later; a no-op stub node must change no existing node's output on a golden query, which is the test that proves the seam. Pinning intent is what stops a correction loop from becoming an injection amplifier.
- **Alternatives considered**: Building grading now — rejected: it multiplies model round-trips per query before there is an eval set to show it helps.

## 7. One policy authority, many enforcement points

- **Decision**: A single `Policy` decides; multiple enforcement points apply. The same predicate is *lowered* into each store's native form (RLS GUCs; a vector payload pre-filter where a vector store exists). Enforcement lives in a shared wrapper, never in a transport.
- **Rationale**: This is what lets the in-process tool path and the remote-MCP tool path have identical access and audit guarantees — the wrapper is shared, so there is one place enforcement can be wrong, not three.
- **Alternatives considered**: Per-transport enforcement — rejected: three copies of a security predicate drift, and the drift is invisible until it is a breach.

## 8. Provider access through an OpenAI-wire gateway

- **Decision**: All model calls go through a single client pointed at any OpenAI-wire endpoint. The runtime names **aliases** (`fast`/`smart`/`embed`/`rerank`), never concrete model IDs, and **holds no provider key**.
- **Rationale**: A model swap becomes a gateway config change, invisible to this repo. Alias indirection is also what makes the deterministic test double possible: `FakeGateway` satisfies the same protocol with scripted responses, so no test in the suite reaches a provider and an offline CI run is itself the assertion.
- **Alternatives considered**: (a) Direct provider SDKs per call site — rejected: scatters keys and retry policy, and makes offline testing impossible. (b) A hand-rolled provider chokepoint — rejected: reimplements load-balancing and fallback that mature gateways already provide.

## 9. Model routing — aliases now, complexity routing later

- **Decision**: Route by manifest-named alias tier now. Leave complexity-based routing as an in-place extension of the existing `route` node, setting the existing `model_alias` key — **no new node**.
- **Rationale**: Alias tiers capture most of the cost win with none of the classifier risk. Making the upgrade an in-place change to one node, writing a key that already exists, keeps it from becoming a graph-shape change later.
- **Alternatives considered**: A dedicated routing node now — rejected: adds a node and a failure mode for a benefit that is not yet measurable.

## 10. Config-first runtime: manifest + domain plugin

- **Decision**: The runtime's identity is an **`AgentManifest`** (prompts, allowed tools, model aliases, retrieval binding, bus binding, MCP servers, channels, budgets, and a **named** policy), plus a thin **`DomainPlugin`** supplying the only two code interfaces a new domain writes — tool bodies and a `Policy`. Everything the runtime reads is config; the only per-domain code is those two seams. Proven by a **second-domain reuse** test, not asserted.
- **The load-bearing rule**: config may **select** a `Policy`; it may never **be** one.
- **Rationale**: This is the config-first ergonomic lesson from agent gateways like GoClaw/OpenClaw — *an agent is a config record, not a code fork* — adopted deliberately and in full.
- **What is deliberately NOT adopted**: their **enforcement locus**. Those systems authorize *around the tool* via role/permission layers. This runtime keeps authorization **below** the agent at row granularity: a manifest can narrow what an agent may do, never widen what a principal may see. Adopting the ergonomics without the trust model is the entire point of this decision.
- **Alternatives considered**: (a) Tool-boundary RBAC as the isolation model — rejected: coarser than row-level enforcement and would silently downgrade SC-A01, a release blocker. (b) A new `agent_manifests` table — rejected: the existing policy row already carries the fields; the manifest is that row read as config, extended additively, so there is no new isolation unit. (c) A field-by-field mapping table to GoClaw's schema — rejected as ornament: every row is an unsurprising 1:1, and a table would couple this spec to their schema drift with nothing testing it.

## 11. Two profiles, proven by a swap test

- **Decision**: **Profile A** (embedded in a full host: vector store + broker + host kernel) and **Profile B** (one container: Postgres/pgvector + in-process bus) are both first-class. Both run the **same binary** and the **same manifest schema**; A is B plus the host kernel and heavier backing services — a **superset relation, not a fork**.
- **The access floor is profile-invariant**: Profile A lowers the visibility predicate to RLS **plus** a vector payload filter; Profile B lowers it to **RLS alone**. Fewer lowerings is *fewer copies to keep in parity*, **not** fewer guarantees — the access-correctness suite passes unchanged under both.
- **Honest cost of the swap**: the authorization floor gets *easier* in Profile B (one lowering instead of two). **Retrieval quality is the actual work** — a native hybrid (BM25 + dense + RRF) must be reproduced with pgvector plus a lexical companion. Anyone reading "just swap the backend" should read that sentence twice.
- **Rationale**: The default cannot regress *because* every reuse point is a named port with a swap test. Exercising Profile B can never break Profile A when both are the same code behind the same protocol.
- **Alternatives considered**: Deferring Profile B — rejected: it is additive behind ports that already exist, so building it now is bounded, and a CI smoke is what keeps the capability from silently rotting. Deferred capabilities that are never exercised are capabilities that do not work.

## 12. Two topologies for adapting a domain

- **Decision**: Support both (1) **embedded** — the plugin ships inside the deployable, tools called in-process; and (2) **decoupled** — the domain's tools, policy, and tables live behind a compliant remote MCP server with its **own** enforcement boundary, and a thin agent adapts by **config alone**. The `ToolRegistry` port makes both first-class from the same binary.
- **Rationale**: The per-domain authorization cost (a policy plus its tables) is real, but it is borne **once, by whoever builds the domain**, on whichever side hosts the tools. Neither topology makes agent *config* the access boundary.
- **Alternatives considered**: Supporting only the embedded topology — rejected: it forces a code change for domains that already expose a compliant server.

## 13. What is deliberately absent

- **Per-agent schedule / cron.** Config-first agent gateways typically expose autonomous self-triggering. This runtime omits it **on purpose**: the current model is caller-initiated with human-gated actions, and scheduled autonomy belongs with planner/executor decomposition. It becomes a real manifest key with a gated executor *if and when* that ships — not a config field bolted on early.
- **A broad `exec` / filesystem / write tool surface.** New power tools are added deliberately, behind a sandbox and a human gate, not imported wholesale.
- **Autonomous memory writes.** A background pass that replays a finished run and *proposes* what to persist stays behind the **same** human gate as an action tool, on the same audit trail. "Doing the task" and "reflecting on what to persist" remain separate passes — which keeps the self-improvement loop inside the existing fail-closed write path instead of creating a privileged side channel.

---

## Resolved unknowns

| Question | Resolution |
|---|---|
| Can the graph run without a vector DB? | Yes — `retrieval.kind: pgvector`, RLS as the sole floor. Retrieval-quality parity is the work, not the authz floor. |
| Can it run without a broker? | Yes — `bus.kind: inprocess`. Worker roles become direct calls. |
| Does the runtime ever hold a provider key? | No. It names gateway aliases only. |
| Does the runtime write a credit ledger? | No. It emits spend with an idempotency key; the host reduces it to money. |
| Can a manifest widen access? | No. It narrows only; widening lives in `ctx.claims` + `Policy`, stamped by the host. |
| How is reuse proven? | A second-domain plugin runs the unmodified graph green, plus the profile swap test — not by assertion. |
