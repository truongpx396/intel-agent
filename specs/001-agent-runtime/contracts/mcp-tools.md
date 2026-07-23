# Contract: MCP Tool Registry

**Plan**: [../plan.md](../plan.md) | Eight scoped tools across three categories, exposed by the FastMCP server (`:8002`) and consumed by the LangGraph agent and compatible local agents. Every tool is **read-only** in Phase 1 (FR-012) — there is no agent-callable crawl/write tool; web crawling runs only inside member-initiated note enrichment (FR-001), not as an agent action. Access is gated by `agent_policies.allowed_tools` per role (FR-011); arguments are validated against the PAT/Actor workspace scope (FR-027).

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

### Web crawling — internal to note enrichment (not an agent tool in Phase 1)
In Phase 1 there is **no agent-callable crawl tool**. Web crawling runs only as the internal fetch step of member-initiated **note enrichment** (`enrich.note.<ws>` → SSRF-guarded `web_distill` → draft), and crawled content enters the index only after the member accepts the draft (FR-001, FR-012). The shared `web_distill(urls, intent)` capability (SSRF-guarded fetch → Crawl4AI → distill-against-intent) is the seam reused in Phase 2.
- **SSRF defense (mandatory)**: every URL is attacker-influenceable (a member may paste a malicious link), so before any fetch it MUST be validated against an SSRF allowlist — `https`-only scheme; reject private/loopback/link-local/reserved IPs after DNS resolution of **all** A/AAAA records (anti-DNS-rebinding); `redirect: error` (no redirect following); bounded response size and timeout.

### `web_search(query: string) -> DistilledResult[]` *(Phase 2 — additive, not in Phase 1)*
- Agent-initiated search for fresh/time-sensitive info, wrapping the same `web_distill` capability over search-API result URLs. Available to **`user` and `admin`** roles via `allowed_tools`.
- **Human-in-the-loop (mandatory)**: requires explicit **per-search confirmation** before each fetch — the agent surfaces the intended search and the fetch runs only on member approval (gates the *action*, not just the result). Metered as `operation_type='web_search'`. Phase 2 adds this as a new tool + allowlist rows + one agent-graph decision node, with no change to Phase-1 code.

## External agent integration note

These eight tools are the **shared knowledge layer** — consumed by both the built-in LangGraph agent and any external/local agent that connects to the MCP server at `:8002` with a valid device PAT. An external agent that only calls `/llm/proxy` (the LLM gateway) does **not** automatically get access to these tools; it must explicitly configure the MCP server as a tool source. When both endpoints are configured together, the external agent operates with identical knowledge access and security guarantees as the first-party chat.

## Cross-cutting rules

- **Allowlist enforced per dispatch.** A tool not in the caller role's `allowed_tools` is rejected before execution (injection escalation defense, research §5).
- **Untrusted output.** Tool results are data, never instructions; the router re-derives the next step from the original classified intent, not from tool output (FR-011).
- **Audit.** Every tool call writes `agent_audit_log` (`tool_called`, `token_cost`, `result_hash`, `trace_id`) (FR-023).
- **No state mutation / no side-effects** by any Phase-1 agent tool; web crawling is not agent-reachable (it is an internal step of note enrichment, gated by the member accept-step). Any future write/send tool — and the Phase-2 `web_search` — defaults to human confirmation (FR-012, Phase 2).

## Contract test obligations

- `search_workspace_knowledge` never returns a chunk with `access_level > effective_access_level` (SC-001, hard).
- A `user`-role agent invoking a structured or utility tool not in its allowlist is rejected (FR-011).
- The note-enrichment fetch (`web_distill`) rejects a URL resolving to a private/loopback/link-local/reserved IP and rejects non-`https` schemes before any fetch (SSRF defense).
- Every successful tool call produces exactly one `agent_audit_log` row with a `result_hash` (FR-023).
- Structured tools reject any attempt to pass raw SQL; only typed filters are accepted (FR-008).

---

## Phase 2 (out of scope here)

> Out of Phase 1 scope (see [spec.md](../spec.md) "Out of Scope"). Two additions are designed
> in [draft-plan.md](../../draft-plan.md), neither of which changes the tools above:
>
> - **Category D — typed knowledge** (`get_artifact_by_type`, `search_biz_rules`,
>   `get_agent_registry`, `resolve_dependency_chain`) — still read-only, still gated by
>   `agent_policies.allowed_tools`, and still subject to the same clearance pre-filter as
>   Category A. See [Enterprise Knowledge Layer](../../draft-plan.md#phase-2--enterprise-knowledge-layer-typed-artifacts-knowledge-graph--agent-context-api).
> - **Write-capable tools** (e.g. `ingest_document`, `write_memory`). Phase 1 has **no**
>   agent-callable write tool (FR-012), and write is designed as an explicit capability
>   (`agent_policies.can_write`, off by default) rather than something implied by read
>   access. Any UI that lists these must mark them as future-phase so it never implies a
>   capability this server will refuse. See
>   [Agent Access & Accountability](../../draft-plan.md#phase-2--agent-access--accountability).
