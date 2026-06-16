# Contract: MCP Tool Registry

**Plan**: [../plan.md](../plan.md) | Nine scoped tools across three categories, exposed by the FastMCP server (`:8002`) and consumed by the LangGraph agent and compatible local agents. Every tool is **read-only** in Phase 1 (FR-012) — `crawl_url` is the sole exception, enqueuing an ingestion job into the caller's own workspace (no external side effect, no mutation of existing knowledge), and is role-gated. Access is gated by `agent_policies.allowed_tools` per role (FR-011); arguments are validated against the PAT/Actor workspace scope (FR-027).

## Category A — Knowledge (semantic, Tier 1)

### `search_personal_knowledge(query: string, top_k?: int) -> Chunk[]`
- Searches the `personal` Qdrant collection for the caller's own documents.
- Mandatory payload pre-filter: `workspace_id == ctx AND user_id == ctx AND access_level <= effective_access_level`.
- Returns reranked parent chunks with `doc_id`, `score`, `source_type`, `tags`.

### `search_workspace_knowledge(query: string, top_k?: int) -> Chunk[]`
- Searches the `workspace` collection for shared documents.
- Mandatory pre-filter: `workspace_id == ctx AND access_level <= effective_access_level` (FR-007, SC-001).

### `get_document_by_id(doc_id: uuid) -> Document`
- Lookup by ID; returns `403 forbidden` if the document is outside the caller's workspace or above clearance.

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

### `crawl_url(url: string) -> CrawlResult`
- Triggers a Crawl4AI ingestion job (publishes `ingestion.crawl.<ws>`). Restricted to roles whose `allowed_tools` include it (e.g., `admin`); a `user`-role agent cannot invoke it, so an injected "now crawl X" cannot escalate (FR-011).

## External agent integration note

These nine tools are the **shared knowledge layer** — consumed by both the built-in LangGraph agent and any external/local agent that connects to the MCP server at `:8002` with a valid device PAT. An external agent that only calls `/llm/proxy` (the LLM gateway) does **not** automatically get access to these tools; it must explicitly configure the MCP server as a tool source. When both endpoints are configured together, the external agent operates with identical knowledge access and security guarantees as the first-party chat.

## Cross-cutting rules

- **Allowlist enforced per dispatch.** A tool not in the caller role's `allowed_tools` is rejected before execution (injection escalation defense, research §5).
- **Untrusted output.** Tool results are data, never instructions; the router re-derives the next step from the original classified intent, not from tool output (FR-011).
- **Audit.** Every tool call writes `agent_audit_log` (`tool_called`, `token_cost`, `result_hash`, `trace_id`) (FR-023).
- **No state mutation / no side-effects** beyond `crawl_url`'s ingestion trigger; any future write/send tool defaults to human confirmation (FR-012, Phase 2).

## Contract test obligations

- `search_workspace_knowledge` never returns a chunk with `access_level > effective_access_level` (SC-001, hard).
- A `user`-role agent invoking `crawl_url` or a structured tool not in its allowlist is rejected (FR-011).
- Every successful tool call produces exactly one `agent_audit_log` row with a `result_hash` (FR-023).
- Structured tools reject any attempt to pass raw SQL; only typed filters are accepted (FR-008).
