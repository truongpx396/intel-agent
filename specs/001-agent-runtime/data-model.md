<!-- Extracted from aisat-intel@369756e (specs/001-contextengine-mvp/data-model.md).
     Carries the two entities this runtime OWNS, plus port-facing views of the
     three it only reads or writes through a host-supplied port. -->

# Data Model — Self-Contained Agent Runtime

**Spec**: [spec.md](./spec.md) | **Ports**: [contracts/agent-deps.md](./contracts/agent-deps.md) | **Host obligations**: [contracts/host-integration.md](./contracts/host-integration.md)

Two tables this repo **owns** and ships migrations for; three it reaches only through a port, where the host owns the durable table. The split follows the repo's organizing rule: *the port is ours, the implementation and the deployment are the host's*.

| Entity | Owner | Why |
|---|---|---|
| `agent_policies` | **intel-agent** | This row *is* the `AgentManifest`. The runtime cannot boot without it. |
| `agent_run` | **intel-agent** | Checkpoint pointer + run budget accounting; meaningless outside the runtime. |
| `approval_request` | host | Also backs non-agent gates (e.g. ingestion accept/confirm). Reached via `ApprovalStore`. |
| `agent_audit_log` | host | The host owns the tamper-evident chain head. Reached via `Recorder`. |
| credit ledger | host | The host MUST be its single writer (the host's ledger-exactness criterion). Reached via `Meter`. |

> A **reference** implementation of `approval_request` and `agent_audit_log` ships here so the standalone profile runs alone. It is explicitly *not* the source of truth in an embedded deployment — a host binds its own.

---

## Owned entities

### `agent_policies` — the manifest's backing row

The complete, portable description of one agent. Everything here is data the runtime **reads**; nothing here is behavior.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | |
| `tenant` | text | **opaque** — the runtime never interprets it |
| `agent_role` | text | opaque label the `allowed_tools` allowlist is keyed on |
| `allowed_tools` | text[] | selects from the `ToolRegistry`; narrows only |
| `prompts` | jsonb | refs into prompt assets — **never inline secrets** |
| `models` | jsonb | names gateway **aliases** only (`fast`/`smart`/`embed`/`rerank`), never model IDs |
| `retrieval` | jsonb | `{kind: qdrant\|pgvector\|sqlite, ...}` — binds a `RetrievalService`. `sqlite` is Profile C: a weaker floor enforced by the query rather than the engine, so it warns at startup and fails closed on a multi-tenant manifest (AR-024a) |
| `memory` | jsonb | `{kind: mem0\|none, retention_days: int\|null}` — degrades cleanly; `retention_days` is a horizon enforced **at recall**, not only by a sweep. `null` is unbounded and is a choice a deployment makes explicitly |
| `bus` | jsonb | `{kind: jetstream\|redis_streams\|inprocess}` |
| `mcp_servers` | jsonb | external tool sources to mount |
| `channels` | text[] | transport adapters to attach (`web_sse`, and Phase 2: `discord`, `slack`, `wechat` — [contracts/channels.md](./contracts/channels.md)). Attaching a channel changes **how** a principal reaches the agent, never **what** they may see |
| `policy` | text | **SELECTS** a `Policy` impl by name; is NOT a policy |
| `can_write` | bool | default `false` |
| `write_ops` | text[] | Phase 1: `note_update` only |
| `write_max_level` | int | upper bound on a write's access level, ≤ owner clearance |
| `token_budget_day` | int | admission budget |
| `max_loop_depth` | int | default 20 |
| `run_deadline_s` | int | default 1800; **paused time excluded**; a breach past `assemble` degrades rather than discarding |
| `run_credits_cap` | int | per-run cost ceiling for the **interactive** form, which the wall-clock deadline bounds only incidentally. Degrades past `assemble` like a deadline. The durable form uses `agent_run.credits_cap` |
| `max_steps` | int | default 60 (durable form) |
| `max_no_progress_steps` | int | default 3 (durable form) — consecutive identical step fingerprints before `no_progress`. Bounded re-entry is not forward progress |
| `history_token_budget` | int | default 24000 — the only unbounded input in `AgentState` gets an explicit ceiling |
| `history_keep_first` | int | default 2 — opening turns kept verbatim (task framing) |
| `history_keep_last` | int | default 6 — recent turns kept verbatim (what a follow-up refers to) |
| `hooks_enabled` | text[] | `audit` \| `langfuse` \| … |

**Rules**

- **A manifest narrows, never widens.** No field here can raise what a principal may see. That is `ctx.claims` plus the `Policy`, stamped by the host's trusted layer.
- **Per-run, not per-worker.** Loaded from this row at run start. Workers hold no manifest state, so any worker serves any tenant and scaling is replica count alone.
- **Fails closed.** A missing or invalid field fails at load. There is no partial-permission agent.
- Phase-2 manifests extend this row **additively** — no new table, no isolation fork.

### `agent_run` — durable long-horizon run

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | also the checkpoint `thread_id` |
| `tenant`, `principal` | text | opaque |
| `agent_role` | text | |
| `status` | text | `queued`\|`running`\|`paused`\|`completed`\|`failed`\|`cancelling`\|`cancelled` |
| `current_step` | int | |
| `state` | jsonb | **checkpoint POINTER** — `{thread_id, checkpoint_ns, checkpoint_id, node, step, graph_version, state_schema_version}` |
| `result` | jsonb | |
| `error` | text | incl. `checkpoint_lost`, `checkpoint_incompatible`, `deadline_exceeded`, `step_cap_exceeded`, `context_window_exceeded`, `credits_exhausted`, `no_progress` |
| `credits_cap`, `credits_spent` | int | hard per-run cap, independent of any daily budget |
| `trace_id` | text | |
| `started_at`, `last_heartbeat_at`, `completed_at` | timestamptz | |

**Rules**

- **`state` is a pointer, not the state.** The checkpointer is authoritative for graph state; this column only *locates* the checkpoint on resume.
- **Checkpoint loss is explicit.** Pointer present but checkpoint gone → `failed('checkpoint_lost')`. Never a silent restart, which would re-spend settled credits.
- **Checkpoint *staleness* is explicit too.** The pointer carries the `graph_version` and `state_schema_version` of the build that wrote it. A resume under a differing `state_schema_version` → `failed('checkpoint_incompatible')`; a differing `graph_version` alone is recorded and resumes. A gate may pause for days, so "the deploy moved underneath a paused run" is the ordinary case, not the exotic one — and resuming a checkpoint into a changed state schema fails silently rather than loudly, which is the reason this is a stored column and not a convention.
- **`paused` means interrupted at a human gate**: a matching approval is pending, the checkpoint holds the interrupt payload, and **zero credits accrue while paused**. Resolving resumes **exactly once**.
- Heartbeat every 10s; a janitor conditionally re-queues on a stale heartbeat.
- Only the durable form creates a row. Interactive runs carry none.

---

## Port-facing views (host owns the table)

### `approval_request` → `ApprovalStore`

The runtime needs: open a gate for a subject, await a decision, observe status. It does **not** need the table.

Invariants the host's implementation MUST satisfy (asserted by `ApprovalContract`): one live gate per subject; visible and resolvable only by its approver; first decision wins; **zero spend and no subject side effect while pending**; the decision is human-authored, never derived from model output.

### `agent_audit_log` → `Recorder`

The runtime emits one entry per tool call — tool, role, cost, `result_hash`, `trace_id` — **including failures**. A tool call that cannot be audited MUST NOT run.

The host owns the durable chain: monotonic per-tenant `seq`, `prev_hash`, `entry_hash`. The runtime never advances a chain head — it is a writer, not the authority. **No bodies are stored**, only refs and hashes.

### credit ledger → `Meter`

The runtime emits `(tenant, principal, operation, units, idem_key)`. The host reduces those to money.

The `idem_key` exists because the runtime **cannot** guarantee exactly-once emission under redelivery, and a host that assumes otherwise will double-charge. The host MUST reject duplicates by that key.

---

## Validation & invariants (test targets)

1. Two runs with the same `agent_policies` row resolve to the same `AgentDeps` wiring.
2. A manifest listing a tool cannot return data the `Policy` would deny — SC-A01 is a deps/floor property, never a manifest property.
3. Two concurrent runs for different tenants on one worker share no manifest-derived state.
4. A `paused` run has `credits_spent` unchanged from the moment it paused.
5. `agent_run.state.thread_id` locates a checkpoint whose `node` matches the last completed node; the same pointer carries the `graph_version` and `state_schema_version` that wrote it, and a resume under a differing schema version ends `checkpoint_incompatible` rather than resuming into a topology the checkpoint predates.
6. A run past `run_deadline_s` terminates at a **node boundary** with spend settled — mid-node termination would leave spend unreconciled. Before `assemble` that is `failed('deadline_exceeded')`; at or after it, the run finishes `degraded` with an answer or its sources under an explicit not-generated marker, and the exhaustion metric increments either way. A run past `run_credits_cap` / `credits_cap` follows the identical boundary rule under `credits_exhausted` / `degraded{reason:'budget_partial'}` — time and money are set independently, but work already bought is bought under either.
7. A durable run repeating an identical step fingerprint `max_no_progress_steps` times ends `failed('no_progress')` **before** `max_steps` fires; a run whose fingerprint changes on any step resets the counter and is bounded by `max_steps` alone.
8. Every `Recorder` entry has a `result_hash` and no body.
9. A session exceeding `history_token_budget` compacts to `history_keep_first` + digest + `history_keep_last` and records the compaction; overflow surviving compaction ends `context_window_exceeded`, never an unclassified provider error.
10. No `Recorder` entry, `debug` fragment, or emitted event contains a value in the credential scrubber's dynamic registry.
11. A `MemoryService.delete` for a principal removes every memory that principal's `recall` could return, and a memory past its retention horizon is not recalled — the two erasure paths a persistent, cross-session, re-injected surface owes.
12. A run marked `cancelling` reaches `cancelled` at the **next node boundary** with `credits_spent` settled and no partial side effect; one cancelled while `paused` never executes its gated action and never waits on the approver; a `cancelled` run is not resumable, and cancelling an already-terminal run is a no-op rather than an error. Same boundary rule as a deadline, and for the same reason — mid-node termination would leave spend unreconciled.
13. Every terminal state in `status` and every value in `error` resolves to a code in the canonical `{code, message, details}` registry (AR-036), and `refused` / `degraded` / `failed` are distinguishable without parsing `message`.
