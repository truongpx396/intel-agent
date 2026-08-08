---
description: 'Production engineering practices for LLM agentic systems: choosing the agent shape, owning the control loop, durable state and resumption, context engineering and token budgets, tool design for models, prompt and model lifecycle, failure handling, human-in-the-loop, evaluation, agent observability, and release management. Organized around the 12-Factor Agents principles and current production guidance (Anthropic context/tool/eval engineering, OpenTelemetry GenAI semantic conventions).'
applyTo: '**/agent/**,**/agents/**,**/*agent*.py,**/*agent*.ts,**/*agent*.go,**/tools/**,**/*tool*.py,**/*tool*.ts,**/*tool*.go,**/mcp/**,**/*mcp*,**/prompts/**,**/*prompt*.py,**/*prompt*.ts,**/*.prompt.md,**/skills/**/SKILL.md,**/evals/**,**/eval/**,**/*eval*.py,**/*eval*.ts,**/*judge*,**/*langgraph*,**/*langchain*,**/*rag*,**/*retriever*,**/AGENTS.md'
---

# AI Agent Engineering — Production Practices

Standards for building LLM systems that **act** — call tools, loop, hold state across turns, spend
tokens and money, and hand work to humans or other agents. The model is one component; almost all
reliability lives in the code around it. Treat an agent as a distributed system whose planner
happens to be non-deterministic, not as a prompt with an API call attached.

The failure mode this file exists to prevent: a demo that works on the happy path, cannot be
resumed after a crash, has no way to tell whether a prompt edit made it better or worse, and burns
unbounded tokens re-deriving context it already had.

## Scope and Precedence

Apply this file whenever a change touches agent orchestration, an agent loop, tool definitions,
prompt construction, retrieval, agent memory, evals, or agent telemetry. **The `applyTo` glob is a
heuristic** — as with the security file, agentic code hides under many names. If the diff wires an
LLM to a capability or changes how one is steered, this file is in scope even when no path matched.

Precedence, so a reviewer never has to guess:

- **[ai-agent-security.instructions.md](./ai-agent-security.instructions.md) is authoritative for the
  agentic *security* surface** — tool authority and scoping (TD1–TD7), MCP and third-party trust
  (MC1–MC5), agent identity and delegation (ID1–ID4), memory/RAG poisoning (MM1–MM4), prompt
  integrity (PI1–PI3), inter-agent auth (MA1–MA3), hard budget ceilings (BC1–BC4), approval gates
  (HO1–HO3), audit (OB1–OB2), and CI/CD (CI1–CI3). This file never relaxes those rules; where the
  two touch the same mechanism, it says which security ID owns the boundary and adds the
  *engineering* requirements on top (does it resume, is it measurable, does it fit the budget).
- **[security-and-owasp.instructions.md](./security-and-owasp.instructions.md) remains authoritative
  for the classic surfaces** — an agent's HTTP handler is still an HTTP handler.
- **[agent-skills.instructions.md](./agent-skills.instructions.md) is authoritative for authoring
  `SKILL.md`** — structure, frontmatter, progressive disclosure, bundled resources. It carries no
  `applyTo` and is never auto-injected: read it explicitly when the task is to design or restructure a
  skill.
- Language mechanics come from [python.instructions.md](./python.instructions.md),
  [go.instructions.md](./go.instructions.md), and [reactjs.instructions.md](./reactjs.instructions.md).

**Provider-neutral by design.** Rules are written against capabilities ("the provider's strict
structured-output mode", "prompt caching", "server-side context compaction") rather than one vendor's
SDK. Apply the rule with whatever the project's provider calls it, and skip sections for capabilities
the project does not use — this is a reference, not a mandate to adopt every pattern.

**Do not adopt a pattern for its own sake.** Every section below has a cost. A single-tool
classification endpoint does not need durable execution, a wave planner, or an LLM judge. Ratchet up
as autonomy, blast radius, and horizon grow.

## Core Principles

- **Agent = model + harness.** When an agent underperforms, the harness is the likelier culprit than
  the model: unclear tools, missing feedback, evicted context, no verification step. Fix the harness
  before switching models or padding the prompt.
- **Determinism where you can, model where you must.** Every step the model does not have to decide
  is a step that cannot go wrong. Prefer code for control flow, validation, routing on known
  conditions, and enforcement of invariants.
- **Context is a per-turn budget, not a bucket.** Attention degrades long before the window fills.
  The goal is the smallest set of high-signal tokens that produces the outcome.
- **Failures are the signal; success should be quiet.** Feed the agent compact, actionable failure
  output (type errors, test names, diffs) and nothing on success. This is the highest-leverage
  reliability loop available.
- **Everything the model sees is a product artifact.** Prompts, tool descriptions, error strings, and
  retrieved snippets are versioned, reviewed, and eval-gated code — not incidental strings.
- **Nothing is done until it is measured.** An agent without evals and traces is not maintainable:
  you cannot tell a regression from variance, and you cannot tell where a run went wrong.

---

## 1. Choose the Smallest Shape That Works

Pick the least autonomous shape that solves the task; escalate only with evidence.

| Shape | Use when | Cost you take on |
|---|---|---|
| **Single call** (with structured output) | One deterministic transformation; no external state | Output validation |
| **Chain / workflow** (code-orchestrated steps) | Steps are known in advance, order is fixed | Step wiring, per-step validation |
| **Router** (model picks among fixed branches) | Input class decides a known path | Classification evals |
| **Single agent loop** (model chooses tools until done) | Path genuinely depends on intermediate results | Loop budget, termination, state, traces |
| **Multi-agent** (orchestrator + sub-agents) | Parallelizable subtasks, or context isolation is the point | Handoff contracts, fan-out control, aggregation, cost multiplier |

Rules:

- **Do not use an agent loop where a workflow suffices.** If you can draw the flowchart before
  runtime, write the flowchart.
- **Sub-agents earn their cost in two ways only:** parallelism, or as a **context firewall** — a
  sub-agent burns its own window exploring and returns a condensed result, keeping the parent's
  context clean. "It feels more modular" is not a reason; each hop adds latency, tokens, and a
  translation loss at the handoff.
- **Keep agents small and focused.** A narrow agent with 3–8 well-chosen tools and one clear job
  outperforms a monolith with thirty tools and a multi-page prompt, and it is testable.
- **Fan-out is bounded and controlled.** Concurrency limits and a circuit breaker are required — see
  `MA3` for the security boundary; the engineering requirement is that a partially failed fan-out has
  a defined aggregation result (which children failed, what the parent does about it).
- **Handoffs are typed contracts.** A sub-agent receives an explicit task object and returns an
  explicit result object (schema-validated). Never pass "the whole conversation so far" as the
  interface, and never let a child's raw transcript land in the parent's context.

---

## 2. Own the Control Loop

You own the `while` loop. A framework may supply it, but the termination conditions, budgets, and
retry semantics must be explicit and readable in your code.

```python
# BAD — the loop is somewhere in a library, and nothing here bounds it.
agent = Framework(model="...", tools=TOOLS, prompt=PROMPT)
return agent.run(user_input)          # no step cap, no budget, no resume, no trace correlation
```

```python
# GOOD — explicit loop: bounded, inspectable, resumable, instrumented.
def step(thread: Thread, budget: Budget) -> StepResult:
    """One turn: model decides, we execute. Pure w.r.t. thread — returns events, appends nothing."""
    response = model.generate(
        system=render_system_prompt(thread.context),   # static-first, cache-friendly (§4)
        messages=thread.to_messages(),
        tools=tool_specs_for(thread.phase),           # only the tools this phase may use (TD1)
        timeout=budget.request_timeout,
    )
    budget.charge(response.usage)                     # tokens/cost accounted per turn (BC1, BC2)
    if response.stop_reason == "tool_use":
        return StepResult(events=[ToolRequested(response.tool_call)])
    return StepResult(events=[Finished(response.text)], done=True)


def run(thread_id: str, budget: Budget) -> Outcome:
    thread = store.load(thread_id)                    # resume is the same code path as start (§3)
    while True:
        if budget.exhausted():
            return thread.halt("budget_exhausted")    # a defined terminal state, not an exception
        if thread.step_count >= MAX_STEPS:
            return thread.halt("step_limit")
        if thread.is_looping():                        # BC4: same call + same args repeating
            return thread.halt("loop_detected")

        result = step(thread, budget)
        thread = store.append(thread_id, result.events)   # durable before side effects
        if result.done:
            return thread.finish()

        for call in list(thread.pending_tool_calls()):
            if requires_approval(call):                # HO1/HO2 own the gate; we own the pause
                thread = store.append(thread_id, [ApprovalRequested(call)])
                return thread.pause(reason="awaiting_approval")
            # idempotency key = (thread_id, step, call) so a resume cannot double-apply (§3)
            thread = store.append(thread_id, [execute(call, thread.principal)])
```

Rules:

- **Every loop has a hard step cap, a token/cost budget, and a wall-clock deadline.** All three, and
  each has a *named terminal state* the caller can render. `BC1` requires the ceiling; the
  engineering requirement is that hitting it is an ordinary, testable outcome — not an exception that
  loses the run's work.
- **Termination conditions are enumerated in one place.** `done`, `step_limit`, `budget_exhausted`,
  `loop_detected`, `awaiting_approval`, `awaiting_input`, `failed(reason)`. Anything else is a bug.
- **Detect non-productive loops, not just long ones.** Identical tool call + identical arguments
  twice, or N turns with no state change, is a halt (`BC4`).
- **Tool calls are just structured output.** The model emits a name and typed arguments; your code
  decides whether, when, and with what authority to run them. Never let a tool name coming back from
  the model be dispatched dynamically without lookup against a registry.
- **The model's decision and the effect are separate steps.** Emit `ToolRequested` → persist →
  execute → persist result. This is what makes approvals, retries, and crash recovery possible.
- **No hidden autonomy.** If a framework can spawn agents, retry, or call tools without appearing in
  your loop, disable that behavior or replace the framework. You cannot debug what you cannot see in
  the trace.
- **Phase-scope the tool set.** Expose only the tools legal for the current phase (research vs write
  vs verify). This cuts wrong-tool errors and shrinks context; it also enforces `TD1`.

---

## 3. State, Durability, and Resumption

Agents run long enough to be interrupted: a deploy, a rate limit, a human who answers tomorrow.
Design for interruption from the first commit — retrofitting it means rewriting the loop.

- **One event log is the source of truth.** Unify execution state (what the agent did, tool calls,
  results, errors) and business state (the order, the PR, the ticket) in a single append-only thread
  per run. Two stores drift, and reconstructing "where was it?" from a chat transcript plus a
  separate table is a permanent source of bugs.
- **Model the agent as a stateless reducer.** `(state, event) -> state'`. The process holds nothing
  that isn't in the store. This buys horizontal scaling, deterministic replay from any prefix,
  free time-travel debugging, and tests that are plain data-in/data-out.
- **Launch, pause, and resume are three calls on the same state machine.** Resuming must not be a
  special path: `run(thread_id)` loads and continues, whether the thread is new, mid-loop, or was
  parked on an approval. If pause/resume is not exercised by a test, assume it is broken.
- **Persist before you act, and record the outcome after.** An event log written after side effects
  cannot tell "did not run" from "ran, then crashed".
- **Every side-effecting tool takes an idempotency key derived from the thread and step.** Retries,
  resumes, and duplicate approvals are all normal; exactly-once effects come from keys plus a
  dedupe check at the boundary, not from hoping the retry never happens.
- **Prefer a durable-execution engine over hand-rolled checkpointing** when the work spans minutes to
  days, has many external calls, or must survive process restarts (workflow engines, queues with
  visibility timeouts, or a framework's durable checkpointer). Hand-rolled is fine for short runs —
  say so explicitly in the code rather than by omission.
- **Separate the log from the context window.** The full log is for durability, audit, and replay; the
  context is a rendered projection of it (§4). Conflating them is what makes long runs unaffordable.
- **Version the thread schema.** Old threads will be resumed by new code. Tag each event with a
  schema version and keep the reducer able to read the previous one.
- **Concurrency on a thread is explicit.** Single-writer per thread, or optimistic concurrency on an
  event sequence number. Two workers appending to one thread produce interleaved nonsense.
- Memory that outlives a run (semantic memory, user preferences, learned facts) is a separate store
  with its own write validation and tenant isolation — `MM1`–`MM4` are authoritative there.

---

## 4. Context Engineering

Context is the scarcest resource in an agent and the one most often squandered. Curate what the model
sees on **every** call; do not accumulate.

**Compose the window deliberately.** In stable-to-volatile order, which is also the order prompt
caching rewards:

1. System prompt / role and operating rules (static)
2. Tool specifications (static per phase)
3. Long-lived reference material, few-shot examples (static)
4. Retrieved or task-scoped material (semi-static)
5. Thread history and tool results (volatile)
6. The current instruction (volatile)

Rules:

- **Write the system prompt at the right altitude.** Neither brittle if/else logic transcribed into
  prose, nor vague aspiration that assumes shared context. Use clear sections
  (`<background>`, `<instructions>`, `## Tool guidance`, `## Output format`) so both models and humans
  can navigate it. If a rule can be mechanically enforced, enforce it in code and delete the
  sentence.
- **Prefer a few canonical examples over exhaustive rules.** A small, diverse set of examples that
  portrays the expected behavior beats a long list of edge cases — and costs fewer tokens.
- **Retrieve just-in-time.** Hold lightweight identifiers (file paths, ids, queries, URLs) and let the
  agent load content through tools when it needs it, rather than pre-stuffing everything that might
  be relevant. Pre-fetch only what is *certainly* needed for the first step — that is a latency
  optimization, not license to dump the corpus.
- **Bound every injection.** Retrieved documents, tool results, logs, and file reads get explicit
  size limits with truncation that tells the model how to get more (`TD5` for the security angle:
  unbounded tool output is also a context-flooding vector).
- **Compact on a threshold, not on a crash.** When the thread approaches a fraction of the window
  (a documented ratio, e.g. ~80%), summarize: keep decisions, constraints, open questions, file paths,
  and unresolved errors; drop resolved tool payloads and superseded reasoning. Persist the summary
  as an event so the compaction itself is auditable and replayable.
- **Let the agent take structured notes outside the window.** A durable scratchpad (plan file,
  progress notes, findings doc) survives compaction and context resets and costs one read to
  rehydrate. This is the cheapest long-horizon memory available.
- **Do not paginate the same data through the window twice.** If the agent has already summarized a
  file, the summary — not the file — belongs in later turns.
- **Keep the cache prefix stable.** Anything volatile (timestamps, request ids, randomized tool
  order, per-turn boilerplate) placed early invalidates the cached prefix on every call. Reported
  savings from correct prompt caching on long agentic sessions are large (roughly 40–80% cost and
  meaningful time-to-first-token gains); naively caching volatile tool results can *increase* latency
  through cache writes that are never reused. Measure both cost and latency after enabling it.
- **Instrument context utilization.** Log per-turn input tokens, share consumed by tool results, and
  compaction events. "The agent got worse after step 20" is nearly always visible here first.

---

## 5. Tool Design for Models

Tools are the agent's API to the world, and the model — not a developer — is the consumer. Design for
that reader. Security constraints on tools (authority, schemas, path handling, shell, irreversible
actions, description-as-instruction-channel) are owned by `TD1`–`TD7`; the rules here are about
whether the agent can *use* the tool correctly at all.

- **Build tools around workflows, not around endpoints.** Wrapping each REST route one-to-one forces
  the model to reconstruct your API's choreography every run. A single `schedule_event` that resolves
  attendees and finds a slot beats `list_users` + `list_calendars` + `find_free_slot` + `create_event`
  — fewer turns, fewer failure points, less context.
- **Fewer, clearer tools.** If a competent engineer cannot say with certainty which tool applies to a
  given situation, the model cannot either. Overlapping tools are a top cause of wrong-tool errors.
  Consolidate or split until each has an unambiguous trigger.
- **Namespace related tools** with a consistent prefix (`repo_pr_create`, `repo_issue_comment`) so
  the model can group capabilities and so multiple servers do not collide.
- **Names and parameters are documentation.** `user_id` not `user`; `max_results` not `limit`;
  `created_after: ISO-8601 date` not `date`. Use enums for closed sets. Prefer explicit units in the
  name (`timeout_seconds`).
- **Write the description as a spec, not a sales pitch.** State what it does, when to use it, when
  *not* to, required formats, and how it relates to other tools. Descriptions are prompt real estate
  paid for on every call — dense and unambiguous, never instructions aimed at overriding the system
  prompt (`TD7`).
- **Return high-signal, low-token results.** Natural-language identifiers over opaque UUIDs, the
  fields the next decision needs, nothing else. Where both are useful, expose a
  `response_format: "concise" | "detailed"` parameter and default to concise.
- **Paginate, filter, and truncate by default** — and make truncation self-describing:
  `"showing 20 of 4,312 matches; narrow with `author` or `path`"`. A truncated response that does not
  say how to narrow the search guarantees the agent retries the same broad call.
- **Errors are instructions.** Return what was wrong, the constraint violated, and the corrective
  action — `"invalid `path`: must be inside the repo root; got '../../etc/passwd'"` — as a normal
  tool result the model can act on, not a stack trace and not an exception that kills the loop.
  Never leak internals (paths, SQL, secrets) into an agent-visible error.
- **Make tools idempotent and retry-safe** wherever the underlying operation allows, and mark those
  that are not so the loop's retry policy can skip them (§8).
- **Tools declare their cost.** Latency class and token-weight of a typical response belong in the
  tool's metadata or docs, so routing and budgeting can reason about them.
- **Develop tools with the agent in the loop.** Prototype → evaluate on realistic tasks → read the
  transcripts → fix the tool. Most tool bugs are discoverable only by watching an agent misuse them;
  transcripts of failed runs are the highest-yield input to the next iteration.

---

## 6. Prompts and Instructions as Versioned Assets

- **Prompts live in the repo, in files, under review** — never inline string-built at call sites, and
  never edited exclusively in a vendor console with no diff. `PI3` makes this a security requirement;
  the engineering requirement is that a prompt change is a reviewable diff with an eval result
  attached.
- **Template with typed variables.** A prompt is a function with a signature: render from a template
  with named, validated inputs. Untrusted content is *data*, delimited and labeled as untrusted,
  never concatenated into the instruction region (`PI1`, `PI2` are authoritative).
- **Version the whole bundle, not the prompt alone.** Prompt text + tool set + model id + decoding
  params + retrieval config behave as one unit; a mismatch between them is a silent regression.
  Reference bundles by version in traces and eval runs so any result can be reproduced.
- **Every prompt has at least one eval case** that fails if the prompt is emptied or reverted. If no
  test notices, the prompt is either dead weight or untested.
- **Keep repo-level agent instructions lean and navigable.** `AGENTS.md` (the cross-tool convention
  now read by most agent CLIs, stewarded under the Linux Foundation's Agentic AI Foundation) or
  `CLAUDE.md` should read as a table of contents — build/test commands, conventions, and pointers —
  not a manual. Long instruction files get skimmed by models exactly like they get skimmed by people;
  push depth into skills or reference files loaded on demand (see
  [agent-skills.instructions.md](./agent-skills.instructions.md)).
- **Mechanical enforcement beats instruction.** Any rule you can express as a lint, type, test, hook,
  or schema should be — instructions are advisory, and an agent under context pressure will drop
  them. Keep the sentence only if the check does not exist.

---

## 7. Models: Selection, Routing, Cost, and Latency

- **Pin the model version explicitly.** Floating aliases change behavior underneath a passing eval
  suite. Upgrades are a deliberate change: run the eval suite on the new version, diff the results,
  then move the pin.
- **Route by task difficulty, not by habit.** Use a small/fast model for classification, extraction,
  routing, and summarization; reserve the frontier model for planning and hard reasoning. Route in
  code on observable features of the request, and eval each route separately.
- **Set decoding params deliberately.** Low temperature for extraction, classification, and anything
  compared against a fixed expectation; higher only where diversity is the goal. Record the params in
  the versioned bundle.
- **Timeouts, retries, and a fallback are required on every model call.** Retry transient failures
  with exponential backoff and jitter; fail over to an alternate model or a degraded deterministic
  path when the primary is unavailable. Define what "degraded" means for the product before the
  incident, not during it.
- **Use structured output modes** (strict JSON schema / tool-call schemas) rather than parsing prose.
  Validate the parse anyway — schema conformance is not correctness (`TD2`, and treat model output as
  untrusted per the security files).
- **Stream when a human is waiting**; do not stream into code paths that need the whole object.
- **Parallelize independent tool calls** and independent sub-tasks. Sequential fan-out is the most
  common avoidable latency in agent systems.
- **Track cost and latency per task, not per call.** The unit that matters is "cost to resolve one
  ticket", including retries, sub-agents, and failed attempts. Publish p50/p95 latency and
  tokens-per-task alongside quality metrics; a quality win that triples cost is a product decision,
  not a free improvement.
- **Cache what repeats:** prompt caching for stable prefixes (§4), a semantic or exact-match cache for
  repeated read-only queries, and memoized tool results within a run. Cache keys must include the
  tenant and the bundle version.

---

## 8. Failure Handling and Reliability

- **Classify failures before reacting.** Transient infrastructure (retry with backoff), model-format
  errors (repair or re-ask once with the validation error attached), tool/business errors (return to
  the model as actionable context), and terminal errors (halt with a named state). One catch-all
  `except: retry` produces both infinite loops and lost work.
- **Compact errors into the context.** One tight, actionable line per failure. Do not paste a 200-line
  stack trace; do not paste the same failure three times. Keep a per-error retry counter and, after a
  small cap (2–3), escalate — change approach, hand to a human, or halt — instead of letting the agent
  retry itself into the budget ceiling.
- **Bound self-healing.** "The agent fixes its own mistake" is a feature only with a cap. Uncapped, it
  is the most expensive failure mode in production.
- **Validate outputs at the boundary in two layers:** schema (shape) and business rules (referential
  integrity, permissions, invariants). A syntactically perfect JSON object naming a nonexistent
  account is a failure, not a success.
- **Never retry a non-idempotent effect without a key.** See §3 — this is where duplicate emails,
  double refunds, and duplicate PRs come from.
- **Circuit-break repeated downstream failures** so an outage does not become a token bonfire.
- **Degrade gracefully and legibly.** Partial results with an explicit statement of what is missing
  beat a confident fabrication and beat a bare failure. Give the agent an explicit way to say
  "I could not do this, here is what I have" and make that a first-class terminal state, not a
  fallthrough.
- **Deterministic guardrails before model guardrails.** Regex/schema/policy checks on inputs and
  outputs are cheaper, faster, and more reliable than asking a model to police itself; use a model
  check only for judgments code cannot make, and make it fail closed for high-impact actions.
- **Chaos-test the harness.** A test suite that never kills the process mid-run, never times out a
  tool, never returns malformed model output, and never rejects an approval has not tested the
  system you are shipping.

---

## 9. Human-in-the-Loop as a First-Class Path

Humans are high-latency tools. Model them that way and the architecture falls out.

- **Requests for humans are tool calls.** `request_approval`, `ask_human`, `escalate` are tools with
  schemas. The agent emitting one is a normal step; the loop persists it and pauses (§3). This is what
  makes an approval survive a restart and a two-day wait.
- **Approvals bind to exact parameters** (`HO2`) and carry enough context for a human to decide
  without reconstructing the run: what will happen, to what, why, what it costs, what happens if
  denied. A reviewer who must open the trace to understand the request will start rubber-stamping.
- **Design against approval fatigue** (`HO3`). Gate by impact and reversibility, batch related
  approvals, and let low-risk actions through with post-hoc audit. Ten prompts per run trains humans
  to click yes.
- **Every pause has a timeout and a default.** Define what happens when nobody answers — expire,
  escalate, or proceed on a documented low-risk default — and make the choice explicit per action
  type.
- **Meet users where they are.** Triggers (chat, webhook, cron, CI, email, API) and responses should
  reach the same thread. A durable thread id plus channel adapters is the whole pattern; do not build
  a second state machine per channel.
- **Log the human decision as an event** — who, when, what was shown, what they chose. This is both
  the audit record (`OB1`) and your best source of eval labels.

---

## 10. Evaluation

Observability adoption runs far ahead of evals in practice; that gap is where undetected regressions
live. Evals are what make an agent maintainable — without them, every prompt or model change is a
guess and every "it seems better" is unfalsifiable.

- **Build the eval set from real traces.** Sample production runs — especially failures, escalations,
  and human corrections — and promote them into cases. Synthetic-only suites test the situations you
  imagined, not the ones users produce. **Start small and start early:** 20–50 tasks drawn from real
  failures is a working suite; waiting for a comprehensive one means shipping unmeasured.
- **Grade the outcome, not the path.** Score what the agent produced against a verifiable expectation
  (final state, artifact, answer). Do not require a specific tool sequence: many trajectories are
  legitimately correct, and pinning the path freezes the implementation.
- **Track trajectory metrics as diagnostics.** Step count, tool-call count, tool-error rate, tokens,
  cost, wall-clock, retries, human interventions. They do not decide pass/fail; they explain *why* a
  case passed expensively or failed late, and they catch the regression where quality holds but cost
  doubles.
- **Prefer programmatic graders wherever the outcome is checkable** — exact match, schema validation,
  tests passing, database state, file diffs. They are cheap, deterministic, and unambiguous.
- **Use an LLM judge only for what code cannot grade**, and treat it as a component that itself needs
  validation: a 0–5 scale with explicit criteria at each level (finer scales add noise, not
  precision), reasoning emitted before the score so the verdict is auditable, and calibration against
  a human-labeled subset. Re-check that agreement whenever the judge's prompt or model changes, and
  never let a judge grade its own generator with the same prompt.
- **Test the deterministic parts deterministically.** Reducers, state transitions, context rendering,
  tool handlers, and parsers get ordinary unit tests with mocked model responses. Reserve
  model-in-the-loop evals for the parts that need judgment — they are slower and noisier.
- **Run evals in CI as a gate.** A fast smoke subset on every PR that touches a prompt, tool, model
  pin, or loop; the full suite before release. Gate on thresholds (pass rate, plus cost and latency
  budgets) and record the bundle version with the result. Account for variance: a single run of a
  stochastic system is not a measurement — repeat critical cases or use a pass rate over N.
- **Every production incident becomes an eval case** before the fix is called done. This is the
  ratchet that keeps quality from oscillating.
- **Eval the tools, not just the agent.** Realistic multi-step tasks per tool surface, measuring
  accuracy, token consumption, and error rate — that is how you find the tool whose description reads
  fine and gets misused every time (§5).
- Adversarial and prompt-injection testing is required for any agent reading untrusted content —
  [ai-agent-security.instructions.md](./ai-agent-security.instructions.md) (Adversarial Testing) is
  authoritative; run it in the same CI job as the quality suite.

---

## 11. Observability and Metrics

You cannot debug an agent from logs of its final answer. Instrument the run.

- **Trace the whole run as one tree.** A root span per run, a child span per model call, per tool
  execution, per sub-agent, per retry — carrying the thread id, bundle version, tenant, and principal.
  Correlate the trace id with the durable thread so an operator can jump between "what happened" and
  "what state remains".
- **Follow the OpenTelemetry GenAI semantic conventions** rather than inventing attribute names: the
  agent lifecycle spans (`create_agent`, `invoke_agent`), tool execution (`execute_tool`), the
  operation-duration metric (`gen_ai.client.operation.duration`), and token usage
  (`gen_ai.client.token.usage`). **These conventions are still pre-stable** — they moved to a
  dedicated GenAI conventions repository in mid-2026 and no GenAI span, metric, or attribute is
  marked Stable — so pin the semconv version you emit, keep the mapping in one adapter module, and
  expect renames on upgrade.
- **Record per-run, per-tenant:** outcome (terminal state), step count, input/output/cached tokens,
  cost, latency (p50/p95), tool-error rate, retry count, compaction events, human-intervention rate,
  and budget-halt rate. Alert on the derived rates, not on raw volume.
- **Capture prompts and completions, redacted.** They are the only way to diagnose a bad run — and the
  fastest way to leak secrets and PII into a third-party dashboard. Redact at the emitter, sample by
  policy, set retention, and render untrusted content inertly in any UI (`OB2` is authoritative;
  `MM1` covers secrets in memory).
- **Score a sample of production traces online** with the same graders used offline, and alert on
  drift. Offline evals catch regressions you ship; online scoring catches the ones reality ships to
  you.
- **Make one run reproducible from telemetry alone:** bundle version, model pin, inputs, thread id,
  and seed/params. If reproducing an incident requires guesswork, the telemetry is incomplete.

---

## 12. Release and Change Management

An agent's behavior is a function of prompt + tools + model + retrieval + harness. Ship that bundle
like any other artifact — with staging, a rollback, and a way to turn it off.

- **Roll out behind flags, per tool and per capability.** New tools and new autonomy levels go to a
  small cohort first; a flag is what lets you disable one tool without redeploying.
- **Shadow or canary before full rollout.** Run the new bundle against live traffic without effects
  (or on a small share), compare outcome and cost metrics against the incumbent, then promote.
- **Rollback is atomic over the bundle.** Reverting the prompt while leaving the new tool schema live
  produces a configuration nobody tested.
- **Ratchet autonomy.** Start with human approval on every impactful action; relax gates only with
  measured evidence from the audit log. Widening scope is a reviewed change, not a config tweak.
- **A kill switch and revocation path must exist and be tested** (`ID4`) — including in-flight runs:
  define whether they halt or drain, and make that behavior deliberate.
- **Version and migrate memory and retrieval stores.** Re-embedding, schema changes, and prompt
  changes that alter what gets retrieved are all behavior changes; they need the same eval gate.
- **Document the operator runbook**: how to inspect a stuck thread, resume it, cancel it, replay it,
  raise a budget, and revoke the agent's credentials. Agents fail at 3am like every other system.

---

## Mapping to the 12-Factor Agents

The [12-Factor Agents](https://github.com/humanlayer/12-factor-agents) principles, and where each is
covered here:

| Factor | Covered in |
|---|---|
| 1. Natural language → tool calls | §2 (tool calls as structured output), §5 |
| 2. Own your prompts | §6 |
| 3. Own your context window | §4 |
| 4. Tools are just structured outputs | §2, §5, §7 (structured output modes) |
| 5. Unify execution state and business state | §3 (one event log) |
| 6. Launch / pause / resume with simple APIs | §3, §9 |
| 7. Contact humans with tool calls | §9 |
| 8. Own your control flow | §2 |
| 9. Compact errors into the context window | §8 |
| 10. Small, focused agents | §1 |
| 11. Trigger from anywhere, meet users where they are | §9 |
| 12. Make your agent a stateless reducer | §3 |
| 13 (bonus). Pre-fetch the context you know you need | §4 (just-in-time, with pre-fetch as a latency optimization) |

Factors the original list does not cover, and this file adds because production demands them:
evaluation (§10), agent observability (§11), model routing and cost control (§7), and release
management (§12).

---

## Common Failure Modes → Where the Fix Lives

| Symptom in production | Root cause to check first |
|---|---|
| Works in demo, unrecoverable after a restart | §3 — state not durable, resume is a separate path |
| Quality degrades in long runs | §4 — no compaction, context flooded by tool results |
| Agent picks the wrong tool | §5 — overlapping tools, vague descriptions, unscoped tool set |
| Agent retries the same failing call forever | §2 loop detection, §8 per-error retry cap |
| Cost per task drifts upward with no quality change | §7 metrics per task, §4 broken cache prefix |
| Duplicate side effects (double email, double PR) | §3 — missing idempotency keys on retries |
| "The new prompt feels better" but nobody can prove it | §10 — no eval set, no CI gate |
| A bad run cannot be diagnosed after the fact | §11 — no per-step spans, no captured prompts |
| Humans rubber-stamp every approval | §9 — approval fatigue, insufficient decision context |
| Model upgrade silently changes behavior | §7 — floating model pin, §12 — no bundle versioning |
| Sub-agent output derails the parent | §1 — untyped handoff, raw transcript returned |

---

## Pre-Production Checklist

**Shape and loop**

- [ ] The chosen shape is the least autonomous one that solves the task, and the reason is written down
- [ ] The loop is in project code with enumerated terminal states
- [ ] Hard step cap, token/cost budget, and wall-clock deadline — all three, each with a named halt state
- [ ] Non-productive loop detection (repeat call + args, or no state change)
- [ ] Tool set is phase-scoped; no dynamic dispatch on a model-supplied tool name

**State**

- [ ] One append-only event log unifying execution and business state
- [ ] Reducer is pure; the process holds nothing that isn't persisted
- [ ] Resume is the same code path as start, and a test proves it
- [ ] Events persisted before side effects; outcomes persisted after
- [ ] Idempotency keys on every side-effecting tool; thread schema is versioned

**Context**

- [ ] Window composed static-first; cache prefix is stable and caching measured (cost *and* latency)
- [ ] Every injection (retrieval, tool output, file read) is size-bounded with self-describing truncation
- [ ] Compaction triggers on a documented threshold and is persisted as an event
- [ ] Durable scratchpad for long-horizon work; per-turn context utilization is logged

**Tools**

- [ ] Tools model workflows, are namespaced, and have unambiguous non-overlapping triggers
- [ ] Strict schemas with enums and explicit parameter names; results are high-signal and token-bounded
- [ ] Errors returned to the model are actionable, leak nothing, and do not kill the loop
- [ ] Each tool has evals on realistic tasks and a recorded token/latency profile

**Prompts and models**

- [ ] Prompts in versioned files, templated with typed variables, reviewed as code
- [ ] Bundle (prompt + tools + model pin + params + retrieval config) versioned and stamped in traces
- [ ] Model version pinned; routing by task difficulty; timeout, retry, and fallback on every call
- [ ] Structured output mode used, and the parse validated anyway

**Reliability and humans**

- [ ] Failures classified; per-error retry cap with escalation; self-healing bounded
- [ ] Outputs validated at schema *and* business-rule layers; guardrails deterministic where possible
- [ ] Human requests are tool calls that pause a durable thread, with timeout and default
- [ ] Approvals bind exact parameters, carry decision context, and are gated by impact
- [ ] Chaos tests: mid-run kill, tool timeout, malformed model output, denied approval

**Evals, telemetry, release**

- [ ] Eval set seeded from real traces, including failures and human corrections
- [ ] Outcome-graded; trajectory metrics tracked as diagnostics; variance accounted for
- [ ] LLM judges use a 0–5 scale with reasoning and are calibrated against human labels
- [ ] Evals gate CI on quality, cost, and latency; every incident became a case
- [ ] One span tree per run (OTel GenAI semconv, version pinned); prompts captured with redaction
- [ ] Per-run/per-tenant metrics published; a sample of production traces is scored online
- [ ] Flagged rollout, shadow/canary comparison, atomic bundle rollback, tested kill switch, runbook

---

## References

- [12-Factor Agents](https://github.com/humanlayer/12-factor-agents) — HumanLayer
- [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) — Anthropic
- [Writing effective tools for AI agents](https://www.anthropic.com/engineering/writing-tools-for-agents) — Anthropic
- [Demystifying evals for AI agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents) — Anthropic
- [Building effective agents](https://www.anthropic.com/engineering/building-effective-agents) — Anthropic (workflow vs agent patterns)
- [OpenTelemetry GenAI semantic conventions](https://github.com/open-telemetry/semantic-conventions-genai) — spans, metrics, events for LLM/agent/retrieval/MCP operations (pre-stable; split out of the main semantic-conventions repo in v1.42.0, June 2026)
- [AGENTS.md](https://agents.md/) — cross-tool repository instruction convention
- Companion files: [ai-agent-security.instructions.md](./ai-agent-security.instructions.md),
  [agent-skills.instructions.md](./agent-skills.instructions.md),
  [security-and-owasp.instructions.md](./security-and-owasp.instructions.md)
