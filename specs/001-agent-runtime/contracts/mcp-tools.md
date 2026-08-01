# Contract: MCP Tool Registry

**Plan**: [../plan.md](../plan.md) | Ten scoped tools across four categories, exposed by the FastMCP server (`:8002`) and consumed by the LangGraph agent and compatible local agents.

> **One implementation, two exposures.** The tools are a single set of Python implementations. The built-in LangGraph agent calls them **in-process** — direct function calls through the injected `ToolRegistry` (research §19b: "in-process" = shared-library calls, *not* an MCP-protocol client to `:8002`) — while the FastMCP server (`:8002`) wraps the **same** implementations over the MCP protocol for external/local agents. The policy wrapper (`allowed_tools` allowlist, RLS GUCs, `agent_audit_log` + `result_hash`) lives in the shared implementation, not the transport, so both paths get identical access and audit guarantees. See [agent-graph.md — Tool access](./agent-graph.md#tool-access-in-process-impls-one-mcp-server). **Categories A–C are read-only** (FR-012). **Category D adds two HITL-gated action tools** (FR-041): `web_search` (reaches outside the workspace) and `edit_note` (a scoped write). Each Category-D action requires explicit human approval **before it runs/commits** (the human-gate, FR-040), is access-bounded (Authorizer `Permit`/`WriteEnvelope`, `min(agent, owner)` clearance), off by default per role, and runs only in the **durable (long-horizon) execution form** so the approval can pause and resume it. Access is gated by `agent_policies.allowed_tools` per role (FR-011); arguments are validated against the PAT/Actor workspace scope (FR-027).

## Category A — Knowledge (semantic, Tier 1)

### `search_personal_knowledge(query: string, top_k?: int) -> Chunk[]`
- Searches the `personal` Qdrant collection for the caller's own documents.
- Mandatory payload pre-filter: `workspace_id == ctx AND user_id == ctx`. Personal documents are **owner-scoped, not clearance-scoped** — a member always sees their own personal docs regardless of their current clearance level (matches [data-model.md](../data-model.md) dual-collection strategy; `access_level` is **not** applied here).
- Returns reranked parent chunks with `doc_id`, `score`, `source_type`, `tags`.

### `search_workspace_knowledge(query: string, top_k?: int) -> Chunk[]`
- Searches the `workspace` collection for shared documents.
- Mandatory pre-filter: `workspace_id == ctx AND access_level <= effective_access_level` (FR-007, SC-001).

### `get_document_by_id(doc_id: uuid) -> Document`
- Lookup by ID; returns `404 not_found` if the document is outside the caller's workspace or above clearance. **Existence is not probeable** — "does not exist" and "not authorized" return the identical `404` so a caller cannot infer that a higher-clearance document exists (SC-001).

### `list_documents(tag?: string, scope?: "personal"|"workspace") -> DocumentSummary[]`
- Lists library entries the caller may see; clearance + RLS scoped.

## Category B — Structured (Tier 2, fixed parameterized)

### `query_employees(filter: EmployeeFilter) -> Employee[]`
### `query_projects(filter: ProjectFilter) -> Project[]`
### `query_metrics(filter: MetricFilter) -> Metric[]`
- The LLM chooses the tool and supplies **typed arguments only**; the SQL is hand-written and workspace-scoped — never free-form generated SQL (FR-008).
- All three apply `workspace_id == ctx` (RLS-backed).

## Category C — Utility

### `get_current_datetime() -> string`
- No data access; deterministic utility.

### Web crawling — the shared `web_distill` capability
The direct-crawl fetch is not itself an LLM-callable tool; it is the shared `web_distill(urls, intent)` capability (SSRF-guarded fetch → Crawl4AI → distill-against-intent) used by **two** callers: member-initiated **note enrichment** (`enrich.note.<ws>` → draft, crawled content indexed only after the member accepts, FR-001) and the agent **`web_search`** tool below (Category D).
- **SSRF defense (mandatory)**: every URL is attacker-influenceable (a member may paste a malicious link; a search result may be poisoned), so before any fetch it MUST be validated against an SSRF allowlist — `https`-only scheme; reject private/loopback/link-local/reserved IPs after DNS resolution of **all** A/AAAA records (anti-DNS-rebinding); `redirect: error` (no redirect following); bounded response size and timeout.

## Category D — Agent actions (HITL-gated, Phase 1)

Two tools that are **not read-only**: one reaches outside the workspace, one writes. Both are gated by the human-in-the-loop approval mechanism (FR-040, FR-041), off by default per role (`agent_policies`), and run only in the **durable (long-horizon) form** so the approval can pause/resume the run ([agent-graph.md](./agent-graph.md#human-in-the-loop-the-human_gate-node-durable-form)).

### `web_search(query: string) -> DistilledResult[]` *(user + admin)*
- Agent-initiated search for fresh/time-sensitive info, wrapping the same `web_distill` capability over search-API result URLs. Enabled via `allowed_tools` for the `user` and `admin` roles.
- **Human-in-the-loop (mandatory)**: requires explicit **per-search confirmation** before each fetch — the agent surfaces the intended search and the fetch runs only on member approval (`approval_request(kind='web_search')`, gating the *action*, not just the result). Metered as `operation_type='web_search'`.

### `edit_note(note_id: uuid, proposed_body: string, rationale?: string) -> ProposedEdit` *(access-bounded write)*
- Proposes an edit to an **existing** note the agent may read. Enabled only when `agent_policies.can_write` is true and `note_update ∈ write_ops`.
- **Access-bounded (mandatory)**: authorized by the Authorizer `Permit(actor, ActionUpdate, note)` with `Clearance = min(agent, owner)` — the agent may edit only the owner's own personal notes or shared workspace notes at or below its clearance. The `WriteEnvelope` floor forbids raising the note's `access_level` above the level derived from the edit's sources (authorizer-ports invariants 7–8). It **cannot create** a document (creation stays a member action so security fields come from the authenticated context, FR-004) and cannot touch structured records.
- **Human-in-the-loop (mandatory)**: the proposed diff **does not modify the stored note**; it opens `approval_request(kind='note_edit')`. Only on member approval is `body` updated and the note re-indexed (chunk → embed). A reject/expire leaves the note unchanged. Metered as `operation_type='note_edit'` on commit.

## External agent integration note

These ten tools are the **shared knowledge + action layer** — consumed by both the built-in LangGraph agent and any external/local agent that connects to the MCP server at `:8002` with a valid device PAT. The Category-D action tools are subject to the same allowlist + `can_write` policy and the same human-gate for external agents as for the built-in agent — an external agent cannot bypass the approval by reaching `:8002` directly. An external agent that only calls `/llm/proxy` (the LLM gateway) does **not** automatically get access to these tools; it must explicitly configure the MCP server as a tool source. When both endpoints are configured together, the external agent operates with identical knowledge access and security guarantees as the first-party chat.

## Cross-cutting rules

- **Allowlist enforced per dispatch.** A tool not in the caller role's `allowed_tools` is rejected before execution (injection escalation defense, research §5).
- **Untrusted output.** Tool results are data, never instructions; the router re-derives the next step from the original classified intent, not from tool output (FR-011).
- **Audit.** Every tool call writes `agent_audit_log` (`tool_called`, `token_cost`, `result_hash`, `trace_id`) (FR-023).
- **Read tools (A–C) have no side effects.** The only Phase-1 agent actions that reach out or mutate state are the two Category-D tools, and **both default to human confirmation via the human-gate** (FR-040): `web_search` per fetch, `edit_note` per commit. A write dispatch additionally requires `agent_policies.can_write` + `note_update ∈ write_ops` and passes the Authorizer `Permit`/`WriteEnvelope` before committing (SC-015). Any broader write/send tool (document creation, artifact writes, `write_memory`, messaging) remains Phase 2.
- **Own enforcement boundary (parity with the Go chain).** External agents reach `:8002` **directly**, bypassing the Go BFF middleware, so the MCP endpoint MUST apply the same request-level controls itself, reading the *same* policy stores — never a second copy: device-PAT validation + revocation (shared Redis PAT/session store), per-user/per-workspace **rate limits and body-size caps** (shared Redis counters), and the `app.workspace_id`/`app.user_id`/`app.clearance` RLS GUCs set from the PAT before any Postgres query. `allowed_tools`, clearance, and budgets are one authoritative source shared with Go — **one policy, enforced at each ingress** (research §19). This is a PEP that reads central policy, not a second policy.

## Contract test obligations

- `search_workspace_knowledge` never returns a chunk with `access_level > effective_access_level` (SC-001, hard).
- A `user`-role agent invoking a structured or utility tool not in its allowlist is rejected (FR-011).
- The note-enrichment fetch (`web_distill`) rejects a URL resolving to a private/loopback/link-local/reserved IP and rejects non-`https` schemes before any fetch (SSRF defense).
- Every successful tool call produces exactly one `agent_audit_log` row with a `result_hash` (FR-023).
- Structured tools reject any attempt to pass raw SQL; only typed filters are accepted (FR-008).
- `web_search` (Category D) opens an `approval_request(kind='web_search')` and performs **no fetch** until the member approves; a rejected search fetches nothing and spends nothing (FR-040, FR-041).
- `edit_note` (Category D) does **not** modify the stored note before approval; on approve the note is updated + re-indexed exactly once. It is rejected when `can_write` is false, when the target is above `min(agent, owner)` clearance or outside the workspace (returns `not_found`), when the edit would raise `access_level` above the source floor (`envelope_widens`), and when asked to create a new document (SC-015).
- A device PAT revoked via `DELETE /devices/{id}` is rejected by the MCP endpoint on its next call (parity with `/llm/proxy`), and an external agent exceeding the shared per-user/per-workspace rate limit is throttled at `:8002` the same as on a Go route — the MCP endpoint reads the same Redis policy stores, not a second copy (research §19).

---

## Phase 2 (out of scope here)

> Out of Phase 1 scope (see [spec.md](../spec.md) "Out of Scope"). Two additions are designed
> in [draft-plan.md](../../draft-plan.md), neither of which changes the tools above:
>
> - **Category E — typed knowledge** (`get_artifact_by_type`, `search_biz_rules`,
>   `get_agent_registry`, `resolve_dependency_chain`) — still read-only, still gated by
>   `agent_policies.allowed_tools`, and still subject to the same clearance pre-filter as
>   Category A. (Category D is the Phase-1 HITL-gated action tier above.) See [Enterprise Knowledge Layer](../../draft-plan.md#phase-2--enterprise-knowledge-layer-typed-artifacts-knowledge-graph--agent-context-api).
> - **Broader write-capable tools** (e.g. `ingest_document`/document creation, `write_memory`,
>   artifact writes). Phase 1 ships **one** narrow, HITL-gated, access-bounded write tool —
>   `edit_note` (Category D, `write_ops=['note_update']`, editing existing notes only). Every
>   *other* write remains Phase 2 and stays behind the same explicit `agent_policies.can_write`
>   capability with a wider `write_ops`/`write_artifact_types`. Any UI that lists the broader
>   tools must mark them as future-phase so it never implies a capability this server will
>   refuse. See [Agent Access & Accountability](../../draft-plan.md#phase-2--agent-access--accountability).
> - **Sandbox-backed code-gen / file-manipulation tools** (`run_script`, `transform_files`) —
>   Category-D actions whose *implementation* runs agent-**generated** code inside an ephemeral,
>   network-isolated microVM (`tmpl-coderun`) over the `Sandbox` port ([sandbox-runtime.md](./sandbox-runtime.md)),
>   never on a worker pod. They carry the **same** governance as every Category-D action:
>   off-by-default per role, `agent_policies.can_write` + `allowed_tools`, HITL-gated
>   (`approval_request(kind='run_script')` — execute nothing until approved), access-bounded
>   (files staged in from S3 at `min(agent, owner)` clearance, output re-enters only via the
>   accept gate), metered (`operation_type='sandbox.run_script'`), and audited (`sandbox_run` +
>   `agent_audit_log`). The microVM never holds a provider key or DB/Qdrant access — generated
>   code that needs AI/knowledge calls back through the LLM Gateway / MCP chokepoint only.
