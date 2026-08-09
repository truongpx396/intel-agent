<!-- Extracted from aisat-intel@369756e (specs/001-contextengine-mvp/quickstart.md),
     rewritten for the standalone profile — the source quickstart stands up a
     full product (Go BFF, SPA, the host's auth provider, Qdrant, NATS), none of which exists here. -->

# Quickstart

Two paths: stand the runtime up **standalone**, or **embed** it in a host.

## Prerequisites

- Docker + Docker Compose
- `uv` (Python 3.12 toolchain)
- An OpenAI-wire endpoint. The local compose file runs LiteLLM; point it at whatever provider keys you have. **This repo holds no provider key** and never will.

---

## Path A — standalone (Profile B)

```bash
git clone https://github.com/truongpx396/intel-agent
cd intel-agent
cp deploy/.env.example deploy/.env      # gateway URL + provider keys go here
uv sync --extra profile-b

make up        # postgres+pgvector, redis, litellm
make smoke     # a cited answer end-to-end
```

`make up` waits for health checks, so a green `make smoke` means the whole path worked — not that it started.

### Verify it is genuinely standalone

```bash
make smoke-assert-isolation
```

This asserts the **negative**: no vector-DB or message-bus client is importable, neither appears in the compose topology, and no `QDRANT_*`/`NATS_*` config is present. A smoke test alone passes just as green with a stray client quietly bound — that is the half that rots silently, so it is checked separately.

### The full local gate

```bash
make ci    # lint → typecheck → unit → conformance → link check
```

---

## Path B — embed in a host

```toml
# your pyproject.toml
dependencies = ["intel-agent @ git+https://github.com/truongpx396/intel-agent@v0.1.0"]
```

Implement the ports your deployment needs ([contracts/agent-deps.md](./contracts/agent-deps.md)), satisfy the five host obligations ([contracts/host-integration.md](./contracts/host-integration.md)), then wire it:

```python
from intel_agent import build_graph, AgentDeps

deps = AgentDeps(
    retrieval=MyRetrieval(), memory=NoOpMemory(),
    llm=OpenAIWireClient(base_url=GATEWAY_URL),
    tools=my_plugin.tools(), emit=MyStreamWriter(),
    meter=MyMeter(), audit=MyRecorder(), approvals=None,
)
graph = build_graph(manifest=load_manifest(agent_id), deps=deps)

async with my_store.tenant_scope(ctx):          # access floor set BEFORE the graph runs
    async for event in graph.astream_events({"query": q, "ctx": ctx}):
        ...
```

### Prove your integration

```python
# your tests/
from intel_agent.conformance import RetrievalServiceContract, AccessFloorContract

class TestMyRetrieval(RetrievalServiceContract):
    impl = MyRetrieval

class TestMyAccessFloor(AccessFloorContract):
    impl, policy = MyRetrieval, MyPolicy
```

Run them in **your** CI. A green smoke test with a red conformance suite means the runtime is working by accident.

---

## Adapting to a new domain

A new domain is a **manifest** plus a **plugin** — never a node edit.

1. **Write the manifest** — prompts, `allowed_tools`, model aliases, `retrieval.kind`, `bus.kind`, budgets, and a **named** policy. Config *selects* a policy; it never *is* one.
2. **Write the plugin** — exactly two things: your tool bodies, and a `Policy` that lowers your claims into a store predicate.
3. **Run the conformance suites.** If they pass, the unmodified graph runs your domain.

If you find yourself editing a node to make a domain work, stop — that is the signal that something belongs in the plugin or the manifest, and shipping the node edit is how the runtime stops being portable.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `make smoke` green, `smoke-assert-isolation` red | A transitive dependency pulled in a forbidden client. Check your extras — `profile-b` must not resolve `qdrant-client` or `nats-py`. |
| Answers cite nothing | `source_count == 0` is a valid state. Check the corpus is seeded and your `RetrievalService` pre-filter is not over-narrow. |
| A caller sees a row they should not | Your `Policy.lower` or store session setup. Run `AccessFloorContract` — it is designed to localize exactly this. |
| Run ends `checkpoint_lost` | The pointer outlived its checkpoint. Intentional: a silent restart would re-spend settled credits. |
| Manifest load fails at boot | By design — it fails **closed**. There is no partial-permission agent. |
