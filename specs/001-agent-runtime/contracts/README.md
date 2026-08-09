# Contracts — intel-agent

Every boundary this runtime has, declared before implementation (constitution, Principle III).

## The boundary (read these two first)

| Contract | What it settles |
|---|---|
| [agent-deps.md](./agent-deps.md) | **The port surface.** The complete list of what the runtime needs from outside. Nothing else may be reached for. |
| [host-integration.md](./host-integration.md) | **The host's obligations.** The five things a host MUST do — stamp `ctx`, enforce the access floor, meter, moderate, gate. |

## The runtime

| Contract | What it settles |
|---|---|
| [agent-graph.md](./agent-graph.md) | State schema, node identity, checkpointing, streaming, run budgets, reliability policy |
| [agent-runtime.md](./agent-runtime.md) | `AgentManifest` + `DomainPlugin` composition, the backing-service swap matrix, Profiles A and B |
| [mcp-tools.md](./mcp-tools.md) | The tool catalog, allowlist dispatch, and the two HITL-gated action tools |
| [approval-ports.md](./approval-ports.md) | `HumanGate` / `ApprovalStore` — the human-in-the-loop gate |
| [stream-events.md](./stream-events.md) | The event vocabulary the runtime emits, plus the `FakeAgentRuntime` and golden fixtures that let each repo be developed and tested **without the other** |
| [channels.md](./channels.md) | Chat platforms (Discord, Slack, WeChat) — the `Channel` capability model and the `IdentityBinder` split. Port fixed now, adapters Phase 2 |

## Conventions

- **Ports here, implementations elsewhere.** This repo owns the *port*; a host owns the *implementation and the deployment*. That single rule resolves every ownership question at the seam.
- **Config selects, code enforces.** A manifest may *name* a policy; it may never *be* one.
- **Prove reuse with a second fixture.** A reusability claim is backed by a conformance suite that a second, unrelated implementation passes — not by an assertion in prose.
- **Fail closed.** Every unspecified state resolves to refusal. An absent required port fails the run loudly; an absent optional one degrades *observably*.

## Cross-repo references

Contracts owned by the host product — the BFF's REST/SSE surface, the NATS subject schema, the Go `Authorizer`, metering, notifications, the sandbox tier — live in [aisat-intel](https://github.com/truongpx396/aisat-intel/tree/main/specs/001-contextengine-mvp/contracts) and are linked by absolute URL from here. They are **not** vendored, so there is exactly one source of truth for each.

The heaviest inbound dependencies, by reference count, are `authorizer-ports.md` (11), `llm-gateway.md` (8), `nats-subjects.md` (6), and `sse-events.md` (4) — a useful map of where this runtime actually touches its reference host.
