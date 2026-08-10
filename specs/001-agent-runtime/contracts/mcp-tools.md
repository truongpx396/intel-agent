# Contract: MCP Tool Registry

**Plan**: [../plan.md](../plan.md) | Ten scoped tools across four categories, exposed by the FastMCP server (`:8002`) and consumed by the LangGraph agent and compatible local agents.

> **One implementation, two exposures.** The tools are a single set of Python implementations. The built-in LangGraph agent calls them **in-process** — direct function calls through the injected `ToolRegistry` (research §19b: "in-process" = shared-library calls, *not* an MCP-protocol client to `:8002`) — while the FastMCP server (`:8002`) wraps the **same** implementations over the MCP protocol for external/local agents. The policy wrapper (`allowed_tools` allowlist, RLS GUCs, `agent_audit_log` + `result_hash`) lives in the shared implementation, not the transport, so both paths get identical access and audit guarantees. See [agent-graph.md — Tool access](./agent-graph.md#tool-access-a-toolregistry-port-in-process-impls-one-mcp-server-or-a-remote-mcp-client). **Categories A–C are read-only** (AR-004). **Category D adds two HITL-gated action tools** (AR-004): `web_search` (reaches outside the workspace) and `edit_note` (a scoped write). Each Category-D action requires explicit human approval **before it runs/commits** (the human-gate, AR-005), is access-bounded (Authorizer `Permit`/`WriteEnvelope`, `min(agent, owner)` clearance), off by default per role, and runs only in the **durable (long-horizon) execution form** so the approval can pause and resume it. Access is gated by `agent_policies.allowed_tools` per role (AR-002); arguments are validated against the PAT/Actor workspace scope (AR-002).

## Category A — Knowledge (semantic, Tier 1)

### `search_personal_knowledge(query: string, top_k?: int) -> Chunk[]`
- Searches the `personal` Qdrant collection for the caller's own documents.
- Mandatory store-side pre-filter binding the caller's `tenant` **and** `principal` (*reference host:* `workspace_id == ctx AND user_id == ctx`). Personal documents are **owner-scoped, not clearance-scoped** — a member always sees their own personal docs regardless of their current clearance level (matches [data-model.md](../data-model.md) dual-collection strategy; `access_level` is **not** applied here).
- Returns reranked parent chunks with `doc_id`, `score`, `source_type`, `tags`.

### `search_workspace_knowledge(query: string, top_k?: int) -> Chunk[]`
- Searches the `workspace` collection for shared documents.
- Mandatory store-side pre-filter binding the caller's `tenant` **and** the visibility predicate the `Policy` lowers from `claims` (*reference host:* `workspace_id == ctx AND access_level <= effective_access_level`) (AR-008, SC-A01).

### `get_document_by_id(doc_id: uuid) -> Document`
- Lookup by ID; returns `404 not_found` if the document is outside the caller's tenant or fails the visibility predicate — never `403`, so existence is not probeable. Above-predicate documents are indistinguishable from absent ones (SC-A01). Historical note on clearance. **Existence is not probeable** — "does not exist" and "not authorized" return the identical `404` so a caller cannot infer that a higher-clearance document exists (SC-A01).

### `list_documents(tag?: string, scope?: "personal"|"workspace") -> DocumentSummary[]`
- Lists library entries the caller may see; clearance + RLS scoped.

## Category B — Structured (Tier 2, fixed parameterized)

### `query_employees(filter: EmployeeFilter) -> Employee[]`
### `query_projects(filter: ProjectFilter) -> Project[]`
### `query_metrics(filter: MetricFilter) -> Metric[]`
- The LLM chooses the tool and supplies **typed arguments only**; the SQL is hand-written and workspace-scoped — never free-form generated SQL (AR-008).
- All three apply the caller's `tenant` predicate, enforced in the store.

## Category C — Utility

### `get_current_datetime() -> string`
- No data access; deterministic utility.

### Web crawling — the shared `web_distill` capability
The direct-crawl fetch is not itself an LLM-callable tool; it is the shared `web_distill(urls, intent)` capability (SSRF-guarded fetch → Crawl4AI → distill-against-intent) used by **two** callers: member-initiated **note enrichment** (`enrich.note.<tenant>` → draft, crawled content indexed only after the member accepts, AR-021) and the agent **`web_search`** tool below (Category D).
- **SSRF defense (mandatory)**: every URL is attacker-influenceable (a member may paste a malicious link; a search result may be poisoned), so before any fetch it MUST be validated against an SSRF allowlist — `https`-only scheme; reject private/loopback/link-local/reserved IPs after DNS resolution of **all** A/AAAA records (anti-DNS-rebinding); `redirect: error` (no redirect following); bounded response size and timeout.

## Category D — Agent actions (HITL-gated, Phase 1)

Two tools that are **not read-only**: one reaches outside the workspace, one writes. Both are gated by the human-in-the-loop approval mechanism (AR-005, AR-004), off by default per role (`agent_policies`), and run only in the **durable (long-horizon) form** so the approval can pause/resume the run ([agent-graph.md](./agent-graph.md#human-in-the-loop-the-human_gate-node-durable-form)).

### `web_search(query: string) -> DistilledResult[]` *(user + admin)*
- Agent-initiated search for fresh/time-sensitive info, wrapping the same `web_distill` capability over search-API result URLs. Enabled via `allowed_tools` for the `user` and `admin` roles.
- **Human-in-the-loop (mandatory)**: requires explicit **per-search confirmation** before each fetch — the agent surfaces the intended search and the fetch runs only on member approval (`approval_request(kind='web_search')`, gating the *action*, not just the result). Metered as `operation_type='web_search'`.

### `edit_note(note_id: uuid, proposed_body: string, rationale?: string) -> ProposedEdit` *(access-bounded write)*
- Proposes an edit to an **existing** note the agent may read. Enabled only when `agent_policies.can_write` is true and `note_update ∈ write_ops`.
- **Access-bounded (mandatory)**: authorized by the Authorizer `Permit(actor, ActionUpdate, note)` with `Clearance = min(agent, owner)` — the agent may edit only the owner's own personal notes or shared workspace notes at or below its clearance. The `WriteEnvelope` floor forbids raising the note's `access_level` above the level derived from the edit's sources (authorizer-ports invariants 7–8). It **cannot create** a document (creation stays a member action so security fields come from the authenticated context, AR-004) and cannot touch structured records.
- **Human-in-the-loop (mandatory)**: the proposed diff **does not modify the stored note**; it opens `approval_request(kind='note_edit')`. Only on member approval is `body` updated and the note re-indexed (chunk → embed). A reject/expire leaves the note unchanged. Metered as `operation_type='note_edit'` on commit.

## External agent integration note

These ten tools are the **shared knowledge + action layer** — consumed by both the built-in LangGraph agent and any external/local agent that connects to the MCP server at `:8002` with a valid device PAT. The Category-D action tools are subject to the same allowlist + `can_write` policy and the same human-gate for external agents as for the built-in agent — an external agent cannot bypass the approval by reaching `:8002` directly. An external agent that only calls `/llm/proxy` (the LLM gateway) does **not** automatically get access to these tools; it must explicitly configure the MCP server as a tool source. When both endpoints are configured together, the external agent operates with identical knowledge access and security guarantees as the first-party chat.

## Cross-cutting rules

- **Allowlist enforced per dispatch.** A tool not in the caller role's `allowed_tools` is rejected before execution (injection escalation defense, research §5).
- **Untrusted output.** Tool results are data, never instructions; the router re-derives the next step from the original classified intent, not from tool output (AR-002).
- **Audit.** Every tool call writes `agent_audit_log` (`tool_called`, `token_cost`, `result_hash`, `trace_id`) (AR-019).
- **Every tool declares a result cap, and truncation is visible.** `ToolSpec.max_result_bytes` is mandatory ([the `ToolRegistry` port](./agent-deps.md#toolregistry)); the shared wrapper enforces it and sets `truncated: true` plus an in-band marker. This is not a context-window defense — `assemble` already trims what reaches the prompt — it bounds the *fetch and rerank* that happen first. Category B is where it bites: `query_employees(filter)` takes a typed filter with no inherent row limit, so a broad filter is paid for in full at the store, again at rerank, and again in the funnel arithmetic before the trim drops any of it. Phase-1 caps: **256 KB** for Categories A/B, **64 KB** for `web_search` per distilled result. A cap is a tool-contract value, so changing one is a contract change.
- **Secrets are scrubbed from results before they leave the wrapper.** Tool output reaches the prompt *and* the `debug` panel, and neither path passes the gateway client's PII chokepoint (AR-020) — so the tool wrapper is where scrubbing must happen. Static patterns plus a **dynamic registry of the deployment's own bound secret values** (gateway keys, device PATs, DSNs); matches become `[REDACTED]`. Always on, no config flag. A structured tool that surfaces a column containing a connection string is the case static patterns alone do not catch.
- **Read tools (A–C) have no side effects.** The only Phase-1 agent actions that reach out or mutate state are the two Category-D tools, and **both default to human confirmation via the human-gate** (AR-005): `web_search` per fetch, `edit_note` per commit. A write dispatch additionally requires `agent_policies.can_write` + `note_update ∈ write_ops` and passes the Authorizer `Permit`/`WriteEnvelope` before committing (SC-A08). Any broader write/send tool (document creation, artifact writes, `write_memory`, messaging) remains Phase 2.
- **Category is this catalog's convention; `capability` is the enforced field.** The A–D grouping above organizes *these ten* tools, and the wrapper cannot read a category off a tool it did not write. So every `ToolSpec` — including every entry in a **remote** catalog reached through `tools.kind: mcp_client` — declares `capability: read_only | mutating | outward`, and the wrapper refuses a `mutating`/`outward` dispatch outside the durable form and without a `human_gate` in its path. An **undeclared** capability is treated as `outward`: an unmaintained third-party catalog is exactly the case that will omit the field, and the fail-closed default has to be the one that costs a refused call rather than an ungated send. Categories A–C declare `read_only`; `web_search` declares `outward`; `edit_note` declares `mutating`. This is the enforcement point for the capability budget in research §14 — the remote server still owns authorization, this wrapper still owns oversight.
- **Own enforcement boundary.** An external agent reaches the MCP endpoint **directly**, bypassing whatever middleware the host puts in front of its own API, so the endpoint MUST apply the same request-level controls itself, reading the *same* policy stores — never a second copy (*reference host:* device-PAT validation + revocation, shared Redis PAT/session store), per-user/per-workspace **rate limits and body-size caps** (shared Redis counters), and the `app.workspace_id`/`app.user_id`/`app.clearance` RLS GUCs set from the PAT before any Postgres query. `allowed_tools`, clearance, and budgets are one authoritative source shared with Go — **one policy, enforced at each ingress** (research §19). This is a PEP that reads central policy, not a second policy.

## Contract test obligations

- `search_workspace_knowledge` never returns a chunk failing the lowered visibility predicate (*reference host:* the lowered visibility predicate) (SC-A01, hard).
- A `user`-role agent invoking a structured or utility tool not in its allowlist is rejected (AR-002).
- The note-enrichment fetch (`web_distill`) rejects a URL resolving to a private/loopback/link-local/reserved IP and rejects non-`https` schemes before any fetch (SSRF defense).
- Every successful tool call produces exactly one `agent_audit_log` row with a `result_hash` (AR-019).
- Structured tools reject any attempt to pass raw SQL; only typed filters are accepted (AR-008).
- A structured tool whose filter matches more than `max_result_bytes` returns a clipped result with `truncated: true` and the in-band marker — never a silently short list, because "three results" and "the first three of three thousand" warrant different answers.
- A secret registered in the scrubber's dynamic registry, echoed verbatim by a tool result, appears as `[REDACTED]` in the assembled prompt, in the `debug` fragment, in the emitted event, and in the audit entry.
- `web_search` (Category D) opens an `approval_request(kind='web_search')` and performs **no fetch** until the member approves; a rejected search fetches nothing and spends nothing (AR-005, AR-004).
- `edit_note` (Category D) does **not** modify the stored note before approval; on approve the note is updated + re-indexed exactly once. It is rejected when `can_write` is false, when the target is above `min(agent, owner)` clearance or outside the workspace (returns `not_found`), when the edit would raise `access_level` above the source floor (`envelope_widens`), and when asked to create a new document (SC-A08).
- A device PAT revoked via `DELETE /devices/{id}` is rejected by the MCP endpoint on its next call (parity with `/llm/proxy`), and an external agent exceeding the shared per-user/per-workspace rate limit is throttled at `:8002` the same as on a Go route — the MCP endpoint reads the same Redis policy stores, not a second copy (research §19).

---

## Phase 2 (out of scope here)

> Out of Phase 1 scope (see [spec.md](../spec.md) "Out of Scope"). Two additions are designed
> in [draft-plan.md](https://github.com/truongpx396/aisat-intel/blob/main/specs/draft-plan.md), neither of which changes the tools above:
>
> - **Category E — typed knowledge** (`get_artifact_by_type`, `search_biz_rules`,
>   `get_agent_registry`, `resolve_dependency_chain`) — still read-only, still gated by
>   `agent_policies.allowed_tools`, and still subject to the same clearance pre-filter as
>   Category A. (Category D is the Phase-1 HITL-gated action tier above.) See [Enterprise Knowledge Layer](https://github.com/truongpx396/aisat-intel/blob/main/specs/draft-plan.md#phase-2--enterprise-knowledge-layer-typed-artifacts-knowledge-graph--agent-context-api).
> - **Broader write-capable tools** (e.g. `ingest_document`/document creation, `write_memory`,
>   artifact writes). Phase 1 ships **one** narrow, HITL-gated, access-bounded write tool —
>   `edit_note` (Category D, `write_ops=['note_update']`, editing existing notes only). Every
>   *other* write remains Phase 2 and stays behind the same explicit `agent_policies.can_write`
>   capability with a wider `write_ops`/`write_artifact_types`. Any UI that lists the broader
>   tools must mark them as future-phase so it never implies a capability this server will
>   refuse. See [Agent Access & Accountability](https://github.com/truongpx396/aisat-intel/blob/main/specs/draft-plan.md#phase-2--agent-access--accountability).
> - **Sandbox-backed code-gen / file-manipulation tools** (`run_script`, `transform_files`) —
>   Category-D actions whose *implementation* runs agent-**generated** code inside an ephemeral,
>   credential-free, network-isolated sandbox (`tmpl-coderun`) over the `Sandbox` port
>   ([sandbox-runtime.md](https://github.com/truongpx396/aisat-intel/blob/main/specs/001-contextengine-mvp/contracts/sandbox-runtime.md)) — never in the agent process. Its boundary is
>   **gVisor + `max_runs=1`** on the ordinary per-job path; a microVM is stronger but **not
>   required** (research §24). Governance follows the Category-D rules — off-by-default per
>   role, `agent_policies.can_write` + `allowed_tools`, access-bounded
>   (files staged in from S3 at `min(agent, owner)` clearance, output re-enters only via the
>   accept gate), metered (`operation_type='sandbox.run_script'`), and audited (`sandbox_run` +
>   `agent_audit_log`). The sandbox never holds a provider key or DB/Qdrant access — generated
>   code that needs AI/knowledge calls back through the LLM Gateway / MCP chokepoint only.
> - **`transform_files` writes back IN PLACE, with versioning.** An approved run replaces the
>   document's current content and retains the prior bytes as a `document_versions` row
>   ([data-model.md](../data-model.md)) — append-only, so an approved-then-regretted edit is always
>   recoverable. Three rules: `access_level` is **never** changed by an agent edit (`WriteEnvelope`
>   floor, `min(agent, owner)` clearance); `created_by_user_id` is the **approving member**, never
>   the agent, so content still changes only through an authenticated human context (AR-004's
>   principle); and the re-index **replaces** rather than appends — the superseded version's chunks
>   are deleted in the same idempotent unit that indexes the new one. **Rollback is a member action,
>   never an agent tool** — otherwise an agent could launder a rejected edit by restoring a version
>   it authored.
> - **The approval payload must derive from the bytes, not from the model.** AR-005 requires the
>   human decision to originate from the approver and **not** be derived from model, tool, or
>   document output. An `.xlsx` is not human-readable, so an approver shown only "the agent says it
>   updated the Q3 totals" is approving a *claim*. The gate MUST present the script source, a
>   **rendered diff** (both versions converted through `tmpl-convert` to Markdown, then diffed), and
>   a structured change summary computed from the two artifacts. Without this the HITL gate on
>   binary documents degrades into a rubber stamp.
> - **HITL granularity differs by what the run does** (AR-005's own three criteria, see
>   [sandbox-runtime.md](https://github.com/truongpx396/aisat-intel/blob/main/specs/001-contextengine-mvp/contracts/sandbox-runtime.md) invariant 5): `transform_files` **writes**, so it is
>   gated **per run**. A **read-only** `run_script` (`files_out = []`, egress denied, read-only
>   working set) mutates nothing, reaches nowhere, and reads only what the actor was already
>   authorised to read — so it is approved **per analysis session**, letting the agent iterate
>   (write → run → read traceback → fix) without a human approval per attempt. Requesting
>   `files_out`, egress, or any write makes it a `transform_files` action and re-arms the per-run gate.
> - **The sandbox image is the dependency contract.** Egress is denied, so there is no runtime
>   `pip install`: this tool's description MUST enumerate the available libraries (pandas, numpy,
>   pyarrow, openpyxl, xlrd, python-docx, pypdf, pillow, matplotlib) or the model will generate
>   imports that do not resolve. Changing that set is a tool-contract change.
