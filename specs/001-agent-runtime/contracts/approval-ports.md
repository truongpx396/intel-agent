# Contract: Human-in-the-Loop / Approval (reusable ports)

**Plan**: [../plan.md](../plan.md) | **Status**: Design addition — the reusability seam that turns Phase 1's one ad-hoc human gate (the note-enrichment accept-gate) into a **first-class, reusable approval mechanism** (FR-005, FR-012, FR-040; SC-014). It factors "an action pauses for an explicit human decision before it runs" into a small set of ports so the *same* gate guards note-enrichment indexing, a long-horizon agent step, a model-suggested sensitivity bump, the agent `web_search` per-fetch confirmation, and the scoped agent `note_edit` write (FR-041) today — and broader agent writes / messaging tomorrow — without a bespoke flow per feature. The graph-native instance is the idiomatic LangGraph **`interrupt()` + `Command(resume=…)`** pattern over the checkpointer the durable `long_horizon` path already has ([agent-graph.md](./agent-graph.md)).

Phase 1 already *promises* human-in-the-loop everywhere it matters — "the note body is never auto-rewritten without approval" ([note-enrichment-design.md](../note-enrichment-design.md)), "model-suggested sensitivity … never the enforced access level without explicit human confirmation" (FR-005), "any … state-changing or message-sending action MUST likewise require explicit human confirmation" (FR-012) — but only the *first* is backed by a mechanism, and it is welded to the note flow. This contract names the seam that removes that welding, the same treatment [authorizer-ports.md](./authorizer-ports.md), [metering-ports.md](./metering-ports.md), and [notification-ports.md](./notification-ports.md) gave access control, billing, and notifications. Ports are given in Go (the kernel language); the graph-native suspend/resume is shown in Python (the agent tier) because that is where the `long_horizon` caller lives.

---

## Why: the four couplings this removes

| # | Today's coupling | Evidence it is a coupling | The port that removes it |
|---|---|---|---|
| 1 | A gate is welded to **notes / enrichment** | The only gate is `note.enrich_status` + `POST /notes/{id}` accept ([data-model.md](../data-model.md) Note, [bff-rest.md](./bff-rest.md), [note-enrichment-design.md](../note-enrichment-design.md)); gating a second thing (an agent step, a sensitivity bump) has no home — it would be a second bespoke flow | `HumanGate` + opaque `Subject` — one port, N callers |
| 2 | "Human confirmation" is an **unbacked promise** | FR-005 and FR-012 mandate confirmation with no durable representation, no resolve endpoint, and no resume path; `agent_run.status='paused'` exists in the schema but is never explained or produced | `ApprovalStore` + the `approval_request` table — a pending gate that survives a restart |
| 3 | The decision is welded to **one UX (accept the draft)** | The only verdict expressible is "accept" (persist the streamed draft); there is no reject/edit, no structured resume value a paused computation continues with | `Decision{Verdict, ResumeValue}` — approve / reject / edit, with the value the caller resumes on |
| 4 | **Who may approve** is implicit | The note owner accepts by owning the note; there is no explicit "this approver, within this tenant, may resolve this subject" check separable from the resource | `Approver`, authorized via the [Authorizer](./authorizer-ports.md) `Actor` — recipient-scoped like a notification |

The rule: **the gate kernel is generic; only the `Subject` kinds, who the `Approver` is, and how a caller resumes are product-specific.** Everything release-relevant — durable-before-spend, fail-closed, recipient-scoped, human-authored, exactly-once resume — is preserved verbatim and stops assuming "a note."

---

## Ports at a glance

```text
CALLERS (enrich worker · long_horizon graph · ingestion metadata · agent web_search · agent note_edit)
   │  Require(req)  ── record a pending gate (idempotent on IdemKey); ZERO spend, ZERO mutation
   ▼
┌── HumanGate ─────────────────────────────────────────────────────────────────────┐
│   ApprovalStore.Create(req) → pending approval_request row (durable)               │
│   two shapes, one port:                                                            │
│     • SUSPEND  — LangGraph human_gate node calls interrupt(payload); the run       │
│                  CHECKPOINTS and yields → agent_run.status='paused'                │
│     • ASYNC    — Require returns a Handle; caller emits an approval_request SSE     │
│                  event and parks (enrich draft lives client-side; note='drafted')  │
└───────────────────────────────────────────────┬────────────────────────────────────┘
        surfaced to the approver                 │  approval_request (pending)
        (GET /approvals · SSE approval_request)  ▼
┌── resolve (HUMAN) ───────────────────────────────────────────────────────────────┐
│   POST /approvals/{id}/resolve {verdict, resume_value?}  (the note accept is this) │
│   ApprovalStore.Resolve(id, approver, decision)  ── idempotent; approver-checked   │
│     approve → resume the caller:                                                   │
│        graph  → publish agent.resume.<ws> → Command(resume=decision) past the gate │
│        enrich → POST /notes/{id} persists body+citations → normal ingestion        │
│     reject/expire → caller ends cleanly, action NEVER runs (fail-closed)           │
└───────────────────────────────────────────────────────────────────────────────────┘
```

Three seams a host swaps independently: the **`Subject` kinds** (what it gates), the **`Approver` authorization** (who may decide — delegated to the Authorizer port), and how a caller **resumes** (a graph `Command(resume)`, an HTTP accept, an applied field). The reference impl uses Postgres (`approval_request`) + the LangGraph Redis checkpointer, but nothing in the port signatures requires them.

---

## Domain types

```go
package approval

import "time"

// Tenant is the ISOLATION boundary a gate is scoped to — the RLS predicate source. The HOST
// decides what it means (workspace, organization); the kernel treats it as an opaque identity.
type Tenant struct {
	Kind string // host-defined: "workspace" | "organization" | …
	ID   string // opaque, stable
}

// Subject is the OPAQUE thing the gate guards — a note to index, a paused agent step, a
// document whose sensitivity is being set, a pending web search. The kernel never interprets
// it: it stores a stable reference and hands it back on resolve so the caller re-attaches.
// Parameterizing this is what makes "gate an enrich draft" vs "gate an agent step" vs "gate a
// sensitivity bump" three callers of ONE port, not three bespoke flows — the exact coupling
// #1 above. subject_type + subject_id in the approval_request row are this value.
type Subject struct {
	Kind string // host-defined: "note" | "agent_run_step" | "document" | "web_search" | …
	ID   string // opaque, stable — the row/thread the gate re-attaches to on resolve
}

// Approver identifies WHO may resolve a gate. The kernel treats it as an opaque identity to
// scope by; AUTHORIZATION is delegated to the host (here: the Authorizer Actor). Kept SEPARATE
// from Subject so "this approver, within this tenant, may resolve this subject" is expressible
// without welding who-decides to who-owns-the-resource (coupling #4).
type Approver struct {
	Kind string // "user" | "role:admin" | …
	ID   string // opaque, stable — RLS app.user_id in the reference impl
}

// Kind is a REGISTERED gate type. A string, not a DB enum the kernel special-cases: a new
// gated action is a new Kind + a caller, never an ALTER TYPE plus a bespoke flow.
type Kind string // "enrich_accept" | "long_horizon_action" | "sensitivity_confirm" | "web_search" | "note_edit" | …

// Verdict is the human's decision. `edit` carries a corrected ResumeValue (coupling #3): the
// human amends what the paused computation resumes with (an edited access_level, a trimmed
// draft), not just yes/no.
type Verdict string // "approve" | "reject" | "edit"

// Status is a gate's lifecycle. `expired` is the fail-closed terminal for an unresolved gate.
type Status string // "pending" | "approved" | "rejected" | "expired"

// Request is one gate to open. IdemKey is REQUIRED — it is the create identity that makes
// Require idempotent (one live gate per (tenant, kind, subject)); a redelivered enrich event
// or a re-entered graph node MUST NOT open a second gate.
type Request struct {
	Tenant     Tenant
	Approver   Approver          // who is ALLOWED to decide (host authorizes; kernel scopes)
	Subject    Subject
	Kind       Kind
	Prompt     string            // human-readable "what am I approving?" (surfaced in the UI)
	Payload    map[string]string // structured detail for the UI: {note_id, suggested_level, run_id, step, …}
	IdemKey    string            // REQUIRED — the create identity
	ExpiresIn  time.Duration     // 0 ⇒ no expiry; >0 ⇒ auto-expire to FAIL CLOSED (invariant 3)
	OccurredAt time.Time
	Attributes map[string]string // trace_id, source subject — audit ONLY, never a decision input
}

// Decision is the resolution — HUMAN-authored, and NEVER derived from model/tool/document
// output (invariant 5). ResumeValue is the value the caller continues with on approve/edit;
// for the graph it is what Command(resume=…) injects into AgentState.approval_decision.
type Decision struct {
	Verdict     Verdict
	ResumeValue map[string]string // edit ⇒ the human's corrected value; approve ⇒ the confirmed payload
	ResolvedBy  Approver
	ResolvedAt  time.Time
	Note        string            // optional human rationale (audited)
}

// Handle is what Require/Resolve return: the durable approval_request id + status, and the
// Decision once resolved (nil while pending). Callers correlate the async resolve on ID.
type Handle struct {
	ID       string
	Status   Status
	Decision *Decision // nil while Status == "pending"
}
```

---

## Port: `HumanGate` — the one port callers use

```go
// HumanGate is the ONE port business + graph code call to require a human decision before an
// action proceeds. Two resolution shapes, one interface:
//
//   • SUSPEND (graph): the LangGraph `human_gate` node calls interrupt(payload) — the run
//     CHECKPOINTS and yields control; the caller does not resume until Command(resume=decision).
//     This is the durable (long_horizon) form; agent_run.status becomes 'paused'.
//
//   • ASYNC (BFF/worker): Require creates a pending approval_request and returns a Handle; the
//     caller emits an `approval_request` SSE event and PARKS. The enrich draft lives client-side
//     (note.enrich_status='drafted'); the resolve is POST /notes/{id} (accept) or /approvals/{id}/resolve.
//
// In BOTH shapes the pending state is DURABLE (ApprovalStore) and the gate is FAIL-CLOSED: an
// unresolved, rejected, or expired gate NEVER lets the action proceed.
type HumanGate interface {
	// Require records a pending gate (idempotent on r.IdemKey) and blocks/returns per the shape
	// above. It performs ZERO side effects on the guarded Subject and triggers ZERO credit spend
	// while pending (invariant 2). On resolve it returns a Handle whose Decision the caller MUST
	// honor: proceed only on approve/edit; on reject/expire the caller ends cleanly and the action
	// does not run (invariant 3).
	Require(ctx context.Context, r Request) (Handle, error)
}
```

**Why this is the whole game.** A caller that needs a human in the loop writes `gate.Require(ctx, Request{Kind: "…", Subject: …})` and honors the returned verdict — it never invents its own pending-state table, its own resolve endpoint, or its own resume plumbing. The Phase-1 agent `web_search` and `note_edit` tools are each just one `Require` call (`Kind:"web_search"` per fetch, `Kind:"note_edit"` per commit); a future broad write/messaging tool is one more, with no new mechanism.

## Port: `ApprovalStore` — the durable tier (driven)

```go
// ApprovalStore is the durable backing of every gate — the approval_request rows. It is the
// answer to coupling #2: a pending decision that survives a worker restart or a client
// disconnect, instead of living only in a note column or (worse) in memory.
type ApprovalStore interface {
	// Create writes a pending row, idempotent on (Tenant, Kind, Subject) backstopped by IdemKey:
	// a replay returns the EXISTING Handle, never a second gate (invariant 1). Writes nothing to
	// the guarded Subject.
	Create(ctx context.Context, r Request) (Handle, error)

	// Resolve records a HUMAN Decision. Idempotent: resolving an already-resolved gate returns the
	// FIRST decision unchanged (a double-click, a redelivered resume, a retried request are no-ops,
	// invariant 1). MUST verify `resolver` is the authorized Approver within the Tenant via the
	// host's Authorizer (invariant 4); a non-approver receives not_found — never the gate, and never
	// a `forbidden` that would confirm the gate exists (existence privacy, SC-001 posture).
	Resolve(ctx context.Context, id string, resolver Approver, d Decision) (Handle, error)

	// Get / ListPending back the /approvals endpoints. Both are recipient-scoped: a viewer sees a
	// gate only if it is theirs to resolve (RLS in the reference impl).
	Get(ctx context.Context, id string, viewer Approver) (Handle, bool, error)
	ListPending(ctx context.Context, a Approver, t Tenant) ([]Handle, error)

	// Expire fails-closed every pending gate past its ExpiresIn (a single-owner scheduled sweep,
	// like the other *.tick jobs). An unresolved gate defaults to NOT proceeding (invariant 3).
	Expire(ctx context.Context, now time.Time) (expired int, err error)
}
```

The store owns nothing about *what* is gated or *how* a caller resumes — only the durable, idempotent, recipient-scoped lifecycle of a `pending → approved|rejected|expired` decision.

---

## Invariants every implementation MUST uphold

1. **Durable & idempotent.** A pending gate is a durable `approval_request` row that survives a worker crash / client disconnect. `Create` is idempotent on `(tenant, kind, subject)` + `IdemKey` (one live gate per subject); `Resolve` is idempotent (a double-click / redelivered resume returns the first decision). This is what makes the whole feature exactly-once.
2. **Refuse-before-spend / no-mutation-while-pending.** A gated action consumes **zero credits** and performs **zero side effects on the guarded resource** while its gate is pending — spend and mutation happen only *past* an approve. This is the security thesis and the direct analogue of `guard`'s refuse-before-spend (SC-007): the gate sits *before* the state change, so nothing crawled/inferred/generated enters the index or the outside world without a human (FR-005, FR-012, FR-040).
3. **Fail-closed.** Unresolved, rejected, or expired ⇒ the action **never proceeds**. There is no timeout-auto-approve and no default-allow; an expired gate is the same as a reject for the caller. A missing or ambiguous decision is a deny.
4. **Recipient-scoped & audited (hard).** A gate is visible and resolvable **only** by an authorized `Approver` within its `Tenant`, enforced at the data layer (RLS: `user_id = current_setting('app.user_id')` within `workspace_id`) — never in application code, and never across tenants regardless of clearance (parity with SC-012). Authorization of the approver is delegated to the [Authorizer](./authorizer-ports.md) `Actor`. Every resolution writes an `audit_log` row (FR-023).
5. **Human-authored decision only.** The `Decision` and any edited `ResumeValue` originate from the human resolver — **never** re-derived from model, tool, or document output. This closes the injection loop: a poisoned crawled page can at worst influence a *draft the human reviews before accepting* (note-enrichment §3), and a tool result can never synthesize its own approval (parity with FR-011 and the graph's "re-derive only from `query` + pinned `intent`" rule).
6. **Exactly-once resume, no re-spend.** Approving a paused `long_horizon` run resumes it **exactly once** from the checkpoint the interrupt wrote — it continues *past* the gate, never re-running settled nodes, so no credit already spent is spent again (parity with SC-009 and the checkpoint-lost rule in [agent-graph.md](./agent-graph.md)). A redelivered `agent.resume.<ws>` or a second approve is a no-op (invariant 1).

---

## The graph-native instance: `interrupt()` + `Command(resume=…)`

The `long_horizon` caller is the load-bearing one, and it is pure idiomatic LangGraph — the durable compiled form of the single `StateGraph` ([agent-graph.md](./agent-graph.md)) already runs on the Redis checkpointer, which is exactly what `interrupt()` needs. The `human_gate` node is the `HumanGate.Require` SUSPEND shape:

```python
# backend-python/src/services/agent/graph.py  (durable/long_horizon compiled form only)
from langgraph.types import interrupt, Command

def node_human_gate(state: AgentState, config: RunnableConfig) -> dict:
    deps = config["configurable"]["deps"]
    pending = state["pending_approval"]              # {kind, subject, prompt, payload} — set by the prior node

    # 1) record a DURABLE pending gate. RE-RUNS on resume (see sharp edge below) → MUST be
    #    idempotent on the run+step idem_key. ZERO spend / ZERO mutation may sit before interrupt().
    handle = deps.gate.create(pending)               # → approval_request(kind='long_horizon_action', status='pending')

    # 2) SUSPEND: checkpoint + yield. The run's status becomes 'paused'; the BFF emits an
    #    approval_request SSE event. Nothing below runs until Command(resume=…) re-enters.
    decision = interrupt({"approval_id": handle.id, **pending})   # ← blocks; state is checkpointed

    # 3) resumed with a HUMAN decision (invariant 5). Honor it (invariant 3).
    if decision["verdict"] == "reject":
        return {"approval_decision": decision, "blocked": True, "block_reason": "approval_rejected"}
    return {"approval_decision": decision}            # approve/edit → the next node proceeds past the gate
```

Suspend / resume / durability mapping:

| Step | LangGraph | Durable state | Surface |
|---|---|---|---|
| open gate | `deps.gate.create(...)` | `approval_request(status='pending')` + `agent_run.status='paused'` | — |
| suspend | `interrupt(payload)` | Redis checkpoint at the `human_gate` boundary (the interrupt payload rides the checkpoint) | `approval_request` SSE event; `GET /approvals` |
| resolve | (out of graph) | `approval_request(status='approved'\|'rejected')` + `audit_log` | `POST /approvals/{id}/resolve` |
| resume | `Command(resume=decision)` | run re-enters at the checkpoint, `status='running'` | `agent.resume.<ws>` → worker loads the checkpoint |

The BFF `POST /approvals/{id}/resolve` publishes `agent.resume.<ws>` (payload `{run_id, approval_id, decision, …}`, [nats-subjects.md](./nats-subjects.md)); the long-horizon worker loads the paused run's checkpoint by `agent_run.state.thread_id` and resumes with `Command(resume=decision)`. Because resume re-enters *at* the checkpoint, invariant 6 holds *across nodes* — the settled nodes before `human_gate` are not re-run and their spend is not repeated. **This capability exists only in the durable compiled form**; the interactive form has no durable approval home and disables `human_gate`, so an interactive query can never silently pause (design thesis, [agent-graph.md](./agent-graph.md)).

> **Implementation sharp edge — the interrupted node's prefix re-executes on resume.** LangGraph resumes an interrupted node by **re-running it from the top** up to the `interrupt()` call; the graph does *not* snapshot mid-function. So everything *before* `interrupt()` — here, `deps.gate.create(...)` — runs **twice**: once when the gate opens, once on resume. Two rules make this safe, and they are load-bearing, not incidental: (1) `ApprovalStore.Create` MUST be **idempotent** on the run+step `IdemKey` (invariant 1), so the second run returns the same `Handle` rather than opening a duplicate gate; and (2) **no credit `billing.deduct` and no resource mutation may sit in the node prefix** — spend and mutation belong strictly *after* the `interrupt()` (invariant 2), so the double-executed prefix has no billable or state-changing effect. An implementer who puts a non-idempotent side effect (a second ledger write, an un-keyed insert, an outbound call) before the `interrupt()` breaks exactly-once. Node granularity is the unit of "settled"; *within* the gate node, treat only the code after `interrupt()` as run-once. (This mirrors the same re-entrancy discipline Temporal/Step-Functions activities require, and is documented LangGraph `interrupt` behavior.)

---

## Reference wiring: the Phase-1 gates as implementations of these ports

One port, several callers — nothing in the kernel knows what any of them gate:

| Generic port / type | ContextEngine (Phase 1) binding |
|---|---|
| `Tenant` | `{Kind:"workspace", ID:workspace_id}` — RLS `app.workspace_id` |
| `Approver` | `{Kind:"user", ID:user_id}` — RLS `app.user_id`; authorization via the Authorizer `Actor` |
| `Subject` (`enrich_accept`) | `{Kind:"note", ID:note_id}` — gates indexing crawled/distilled content; resolve = `POST /notes/{id}` |
| `Subject` (`long_horizon_action`) | `{Kind:"agent_run_step", ID:run_id+step}` — gates a flagged durable step; resolve = `/approvals/{id}/resolve` → `Command(resume)` |
| `Subject` (`sensitivity_confirm`) | `{Kind:"document", ID:doc_id}` — gates applying a model-suggested `access_level` above the uploader default (FR-005) |
| `Subject` (`web_search`) | `{Kind:"web_search", ID:query_hash}` — gates each agent web fetch (FR-041); resolve → `web_distill` runs |
| `Subject` (`note_edit`) | `{Kind:"note", ID:note_id}` — gates an agent note write bounded by `Permit(ActionUpdate)`+`WriteEnvelope`, `Clearance=min(agent,owner)` (FR-041, SC-015); resolve → commit + re-index |
| `Decision.ResumeValue` | enrich: the accepted body+citations · agent step/web: the injected `approval_decision` · sensitivity: the confirmed level · note_edit: the approved (optionally human-edited) body |
| `ApprovalStore` | Postgres `approval_request` (RLS recipient-scoped) + the LangGraph Redis checkpointer for the suspended-run payload |
| `HumanGate` (SUSPEND) | the `human_gate` graph node (`interrupt`/`Command(resume)`) — long_horizon only |
| `HumanGate` (ASYNC) | the enrich worker + ingestion metadata step returning a `Handle` and parking |

**Phase-1 graph callers.** The agent `web_search` per-fetch confirmation is `gate.Require(Request{Kind:"web_search", Subject:{Kind:"web_search", ID:query_hash}})` inside the `web_search_decide` node, and the agent `note_edit` write is `gate.Require(Request{Kind:"note_edit", Subject:{Kind:"note", ID:note_id}})` before the commit — both SUSPEND-shape callers in the durable form (FR-041; [agent-graph.md](./agent-graph.md#human-in-the-loop-the-human_gate-node-durable-form)). A future broad write / messaging tool is one more caller of the same shape, no new mechanism.

---

## Contract-test skeleton (`ApprovalContract`)

Validates *any* `HumanGate`/`ApprovalStore` implementation against the invariants, so a new gate `Kind` or a swapped store is held to the same guarantees — the conformance gate a `PricerContract`/`ChannelContract`/`ParityContract` is for the other ports. The store suite runs against a real impl via Testcontainers (`//go:build integration`); the suspend/resume suite is a Python graph test.

```go
package approval_test

// ApprovalContract runs against a REAL approval.ApprovalStore (Testcontainers PG). //go:build integration
func ApprovalContract(t *testing.T, newStore func(t *testing.T) approval.ApprovalStore) {
	ctx := context.Background()
	ws := approval.Tenant{Kind: "workspace", ID: uuidv7()}
	owner := approval.Approver{Kind: "user", ID: uuidv7()}
	other := approval.Approver{Kind: "user", ID: uuidv7()}
	req := func(idem string) approval.Request {
		return approval.Request{Tenant: ws, Approver: owner, Kind: "enrich_accept",
			Subject: approval.Subject{Kind: "note", ID: "n1"}, IdemKey: idem}
	}

	t.Run("create is idempotent — one live gate per subject", func(t *testing.T) {
		st := newStore(t)
		h1, err := st.Create(ctx, req("e1")); mustNoErr(t, err)
		h2, err := st.Create(ctx, req("e1")); mustNoErr(t, err) // redelivery / graph re-entry
		if h1.ID != h2.ID { t.Fatal("second Create opened a duplicate gate") }
		if h1.Status != "pending" { t.Fatalf("want pending, got %s", h1.Status) }
	})
	t.Run("resolve is idempotent — first decision wins", func(t *testing.T) {
		st := newStore(t); h, _ := st.Create(ctx, req("e2"))
		d := approval.Decision{Verdict: "approve", ResolvedBy: owner}
		r1, err := st.Resolve(ctx, h.ID, owner, d); mustNoErr(t, err)
		r2, err := st.Resolve(ctx, h.ID, owner, approval.Decision{Verdict: "reject", ResolvedBy: owner}); mustNoErr(t, err)
		if r2.Decision.Verdict != r1.Decision.Verdict { t.Fatal("second resolve changed the decision — not idempotent") }
	})
	t.Run("recipient-scoping: a non-approver gets not_found, never the gate (invariant 4)", func(t *testing.T) {
		st := newStore(t); h, _ := st.Create(ctx, req("e3"))
		if _, found, _ := st.Get(ctx, h.ID, other); found {
			t.Fatal("cross-recipient leak: a non-approver can see the gate")
		}
		if _, err := st.Resolve(ctx, h.ID, other, approval.Decision{Verdict: "approve"}); err == nil {
			t.Fatal("a non-approver was allowed to resolve the gate")
		}
	})
	t.Run("expire fails closed (invariant 3)", func(t *testing.T) {
		st := newStore(t)
		r := req("e4"); r.ExpiresIn = time.Millisecond; _, _ = st.Create(ctx, r)
		_, _ = st.Expire(ctx, time.Now().Add(time.Second))
		h, _, _ := st.Get(ctx, /*id*/ lastID(t), owner)
		if h.Status != "expired" { t.Fatalf("unresolved gate did not fail closed: %s", h.Status) }
	})
}
```

```python
# backend-python/tests/integration/test_human_gate.py  — the SUSPEND/resume + no-spend proof
def test_long_horizon_gate_interrupts_no_spend_resumes_once(durable_graph, fake_deps):
    # a long_horizon run reaches human_gate → interrupts (checkpoints), spends nothing while paused
    state = durable_graph.invoke(seed(intent="long_horizon"), thread("t1"))
    assert state["__interrupt__"], "run did not pause at the human gate"
    assert fake_deps.billing.deducted == 0, "spend occurred while paused (invariant 2 violated)"
    assert run_status("t1") == "paused"

    # resume with a HUMAN decision → continues PAST the gate, exactly once, no re-spend (invariant 6)
    out = durable_graph.invoke(Command(resume={"verdict": "approve", "resolved_by": "u1"}), thread("t1"))
    assert out["answer"] and fake_deps.billing.deducted == out["usage"]["credits"]
    # a redelivered resume is a no-op — the thread is already past the gate
    again = durable_graph.invoke(Command(resume={"verdict": "approve"}), thread("t1"))
    assert again == out, "second resume re-ran the run (not idempotent)"

def test_gate_decision_is_human_never_tool_output(durable_graph, fake_deps):
    # a rejected gate ends the run cleanly; nothing the tool/document produced can synthesize an approve (invariant 5)
    durable_graph.invoke(seed(intent="long_horizon"), thread("t2"))
    out = durable_graph.invoke(Command(resume={"verdict": "reject", "resolved_by": "u1"}), thread("t2"))
    assert out["blocked"] and out["block_reason"] == "approval_rejected"
    assert fake_deps.index.writes == 0, "a rejected gate still mutated the index"
```

---

## Deployment topology & extraction

The gate is a small kernel module (`backend-go/kernel/approval/`) with the same ports-and-adapters discipline as the other three: `domain` (types + invariants) → `ports` (`HumanGate`, `ApprovalStore`) → `adapters/driven` (the Postgres `approval_request` store; the graph SUSPEND shape lives in the Python tier and calls the same store over the BFF). A `depguard` rule forbids `kernel/approval/**` from importing `internal/**`, so it is extraction-ready (`git mv` + `go mod init` compiles) exactly like `kernel/metering` and `kernel/notify`.

It does **not** stand alone conceptually — it **composes** the other ports rather than duplicating them:
- **Authorizer** ([authorizer-ports.md](./authorizer-ports.md)) decides *who may approve* (invariant 4): `ApprovalStore.Resolve` checks the resolver's `Actor`, it does not re-implement authorization.
- **Metering** ([metering-ports.md](./metering-ports.md)) is what invariant 2 gates: a pending gate simply means no `billing.deduct` is published — the gate does not touch the ledger, it *withholds* the spend the caller would otherwise emit.
- **Notification** ([notification-ports.md](./notification-ports.md)) is the optional surface: pinging an approver that a gate awaits them is one more `Topic` (`approval_requested`) — additive, not required (the live `approval_request` SSE event + the `GET /approvals` inbox already surface it).

**Recommended posture:** embedded in the kernel; there is no service-extraction pressure because a gate is a fast DB write plus a checkpoint the graph already owns.

---

## Generalization checklist (before reusing this in another system)

- [ ] **Subject kinds defined** — enumerate the actions the host gates; each is a `Kind` + a caller that honors the verdict. No kernel change per new kind.
- [ ] **Approver authorization wired** — `Resolve` checks the resolver via the host's Authorizer; recipient-scoping RLS matches `Approver` within `Tenant` (verified by the `ApprovalContract` leak test).
- [ ] **Refuse-before-spend honored** — every caller withholds spend and resource mutation while pending; the gate sits *before* the state change (invariant 2).
- [ ] **Fail-closed by default** — unresolved/expired ⇒ deny; a scheduled `Expire` sweep runs; no timeout-auto-approve (invariant 3).
- [ ] **Human-authored decisions** — the resume value comes from the human; no code path lets tool/document output produce a `Decision` (invariant 5).
- [ ] **Exactly-once resume** — the durable caller resumes from a checkpoint past the gate; a redelivered resume is a no-op; no settled spend repeats (invariant 6).
- [ ] **Idempotency backstop present** — `UNIQUE(workspace_id, kind, subject_id)` (one live gate/subject) + a create `IdemKey`; `Resolve` returns the first decision on replay.
- [ ] **Extraction-clean** — nothing under `kernel/approval/` imports the product; `depguard` enforces it.

## Non-goals (stays in the host / other ports, by design)

- **What is gated** — callers decide which actions require a human (the `guard` moderation gate, the clearance ladder, and the SSRF guard are *separate* structural defenses, not this port).
- **Who may approve** — authorization is the Authorizer port's; this port only scopes and records.
- **Copy / UI** — the `Prompt`/`Payload` are opaque strings the SPA renders; the kernel does not know what a gate *says*.
- **Delivering the ping** — surfacing "you have a pending approval" beyond the live SSE event is the Notification port's job (an additive `approval_requested` topic), not this one.
