# intel-agent

A **self-contained, domain-adaptable agent runtime**. One LangGraph `StateGraph`, run as a
config-first agent that adapts to a new domain by swapping a **manifest** (config) plus a thin
**domain plugin** (code), on a swappable set of backing services — without forking the graph.

Extracted from [aisat-intel](https://github.com/truongpx396/aisat-intel) at `369756e`, where it
is specified as **Profile B** of
[`contracts/agent-runtime.md`](specs/001-agent-runtime/contracts/agent-runtime.md).

> **Status: spec-first.** The contracts, spec, and task breakdown are complete and carry their
> original commit history. Implementation has not started. `make ci` is green on a specs-only
> checkout and lights up per gate as code lands.

---

## The idea in one screen

```
AgentManifest (config)  ──selects──►  DomainPlugin (code: Tools + Policy)  +  generic runtime deps
        │                                        │
        └──────────────► graph entrypoint assembles AgentDeps once per worker ──► one StateGraph
                                                 │
                                    per run: ctx (tenant/principal/claims) stamped by trusted layer
                                                 │
                              row-level pre-filter enforces visibility BELOW the graph, every manifest
```

- **Everything the runtime reads is config.** The only per-domain **code** is (1) the tool bodies
  and (2) the authorization `Policy`.
- **Config selects, code enforces.** A manifest may *name* a policy; it may never *be* one. A
  manifest can narrow what an agent may do — never widen what a principal may see.
- **The graph is manifest-blind.** No node reads the manifest. Adding a domain changes deps and
  config, never a node.

## Two deployment profiles, one binary

|  | **Profile A** — reference host | **Profile B** — self-contained |
|---|---|---|
| Runtimes | Go kernel + this Python tier | this Python container alone |
| Vector store | Qdrant | Postgres + pgvector |
| Bus | NATS JetStream | in-process (or Redis Streams) |
| Auth / billing | host kernel | host concerns, re-satisfied in-container |
| Access floor | RLS **+** vector pre-filter | RLS alone |

Both run the **same graph binary** and the **same manifest schema**. A is B plus the Go kernel and
the heavier backing services — a **superset relation, not a fork**. Swapping a backing service is a
port implementation or a config value, never a source change to the graph.

The access floor is **profile-invariant**: fewer lowerings is fewer copies to keep in parity, not
fewer guarantees.

## Quickstart — the standalone profile

```bash
make up      # postgres+pgvector, redis, litellm
make smoke   # a cited answer, with NO Qdrant and NO NATS bound
make ci      # lint, typecheck, unit, conformance, link check
```

`make smoke-assert-isolation` asserts the *negative* half of that claim — that no forbidden client
is installed, no forbidden service is in the topology, and no `QDRANT_*`/`NATS_*` config is present.
A smoke test passes just as green with a stray client quietly bound; that is the half that rots
silently, so it is checked mechanically.

## Repo layout

```
specs/001-agent-runtime/
├── spec.md  plan.md  research.md  data-model.md  tasks.md  quickstart.md
├── contracts/
│   ├── agent-graph.md        # state, nodes, checkpointing, streaming
│   ├── agent-runtime.md      # manifest + plugin, profiles, swap matrix
│   ├── mcp-tools.md          # the tool catalog + allowlist dispatch
│   ├── approval-ports.md     # human-in-the-loop gate
│   ├── agent-deps.md         # the AgentDeps port bundle  ← the boundary
│   └── host-integration.md   # what a host MUST provide   ← the boundary
└── diagrams/
src/intel_agent/              # graph/ tools/ retrieval/ memory/ ports/ conformance/
prompts/  evals/  migrations/  tests/  deploy/
```

## Integrating it into a host

A host installs the package, implements the ports, and passes the conformance suites:

```toml
# host pyproject.toml
dependencies = ["intel-agent @ git+https://github.com/truongpx396/intel-agent@v0.1.0"]
```

```python
# host tests — contract drift fails a build, not a review
from intel_agent.conformance import RetrievalServiceContract, PolicyContract

class TestHostRetrieval(RetrievalServiceContract):
    impl = MyRetrievalService
```

`intel_agent.conformance` is **public API** and is versioned as such. A change to a port protocol or
to [`host-integration.md`](specs/001-agent-runtime/contracts/host-integration.md) is a breaking
change for every host: it bumps at least the minor version and lands *before* the host PR that
consumes it.

**What does not travel with the runtime** — and must be re-satisfied by the host: credit metering,
the RLS GUC plumbing, and the moderation provider behind `guard`. The runtime declares *that* these
run; it never implements *how* a host bills or authenticates.

## Relationship to aisat-intel

| | intel-agent | aisat-intel |
|---|---|---|
| Owns | the **port** | the **implementation** and the deployment |
| Examples | `RetrievalService`, `ToolRegistry`, `Policy` protocol, `Meter` | Qdrant hybrid search, AISAT tool bodies, `SingleAxisPolicy`, the sole `credit_ledger` writer |

That single rule resolves every ownership question at the seam. Engineering principles I–VI, IX,
and X in [the constitution](.specify/memory/constitution.md) are shared **verbatim** with
aisat-intel and are amended there first — a local-only edit to a shared principle is a defect.

## License

Proprietary. All rights reserved.
