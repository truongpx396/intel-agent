<!-- Extracted from aisat-intel@369756e (specs/001-contextengine-mvp/quickstart.md),
     rewritten for the standalone profile — the source quickstart stands up a
     full product (Go BFF, SPA, the host's auth provider, Qdrant, NATS), none of which exists here. -->

# Quickstart

Two paths: stand the runtime up **standalone**, or **embed** it in a host.

## Prerequisites

- Docker + Docker Compose
- `uv` (Python 3.13 toolchain)
- An OpenAI-wire endpoint. The local compose file runs LiteLLM; point it at whatever provider keys you have. **This repo holds no provider key** and never will.

---

## Path A — standalone (Profile B)

```bash
git clone https://github.com/truongpx396/intel-agent
cd intel-agent
cp deploy/.env.example deploy/.env      # gateway URL + provider keys go here
uv sync --extra profile-b

make up                                 # postgres+pgvector, redis, litellm
intel-agent ingest ./my-documents       # build a corpus — files, URLs, or raw text
make smoke                              # a cited answer end-to-end
```

`make up` waits for health checks, so a green `make smoke` means the whole path worked — not that it started.

**The ingest step is not optional and not a detail.** An earlier revision of this page went straight from `make up` to `make smoke` and then listed "check the corpus is seeded" under troubleshooting — which is to say the quickstart could not answer a question about your own documents, the one thing the standalone profile exists to do. There is nothing to retrieve until something is ingested, and the built-in ingestor is what makes that reachable without writing code.

Ask a question:

```bash
make dev        # streaming CLI REPL
make dev-ui     # the built-in chat + ingest UI, on SSE
```

An unrecognized principal is **refused** — the default identity binder authenticates somebody, never everybody. Configure the single user or the user list in `deploy/.env`.

### Path A-min — Profile C (one container, one file)

No Postgres, no Redis, no bus — an embedded SQLite store holding the corpus, the checkpoints, and the usage ledger:

```bash
uv sync --extra profile-c
make up-c && make smoke-c
```

**Read the startup warning before you use this.** Profile C enforces the visibility predicate **in the query rather than in the engine**, which is a genuinely weaker floor than the RLS profiles, so it is **single-tenant only** and refuses to start against a manifest declaring more than one tenant. It fails closed rather than quietly serving a deployment that needed the strong floor. Everything else is identical — same binary, same manifest schema, and `AccessFloorContract` passes unchanged.

### Verify it is genuinely standalone

```bash
make smoke-assert-isolation
```

This asserts the **negative**: no vector-DB or message-bus client is importable, neither appears in the compose topology, and no `QDRANT_*`/`NATS_*` config is present. A smoke test alone passes just as green with a stray client quietly bound — that is the half that rots silently, so it is checked separately.

### The full local gate

```bash
make ci    # lint → typecheck → unit → conformance → link check
```

This is the **fast local subset**. CI runs more and merge requires all of it: lint/format → unit → **integration** → **contract** → conformance → **Profile-B smoke** → **build** → **security scan**, plus the 80% coverage floor and the eval gate. A green `make ci` means your loop is clean, not that your PR will merge.

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
| Answers cite nothing | `source_count == 0` is a valid state. Run `intel-agent ingest` first; then check your `RetrievalService` pre-filter is not over-narrow. |
| Every question is refused | The default identity binder fails closed on an unrecognized principal — by design. Set the single user or the user list in `deploy/.env`. |
| Startup warns about a "reduced floor" | You are on Profile C. Expected, and it is single-tenant only — see Path A-min. |
| A caller sees a row they should not | Your `Policy.lower` or store session setup. Run `AccessFloorContract` — it is designed to localize exactly this. |
| Run ends `checkpoint_lost` | The pointer outlived its checkpoint. Intentional: a silent restart would re-spend settled credits. |
| Manifest load fails at boot | By design — it fails **closed**. There is no partial-permission agent. |
