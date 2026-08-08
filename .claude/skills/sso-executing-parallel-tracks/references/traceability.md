# Traceability: wave dispatch + run records (the spine)

With N workers in flight, durable state is non-negotiable — the model forgets, the file doesn't.

**Two artifact tiers per wave.** One wave with three tracks produces four files:
```
runs/2026-07-20T11-30_wave1.wave.dispatch    ← orchestrator breadcrumb (this skill)
runs/2026-07-20T11-30_wave1_us1.json         ← per-track run record (SBD track-preflight.sh)
runs/2026-07-20T11-30_wave1_us2.json         ← …us3.json likewise
```
All share the `WAVE_ID` prefix, so `ls runs/*wave1*` shows the complete fleet state at a glance —
which is exactly how you rebuild it after a compaction. All are gitignored.

**Wave dispatch** (`runs/<wave-id>.wave.dispatch`) — minted by `track-wave-preflight.sh --persist`
at Step 1 (precheck), closed at Step 7 (--complete). Schema:
```json
{
  "wave_id": "2026-07-20T11-30_wave1",
  "wave_number": 1,
  "base_ref": "origin/main",
  "base_sha": "abc123def456",
  "track_run_ids": ["2026-07-20T11-30_wave1_us1", "2026-07-20T11-30_wave1_us2", "2026-07-20T11-30_wave1_us3"],
  "status": "in-progress",
  "created_utc": "2026-07-20T11:30:00Z",
  "completed_utc": null,
  "final_status": null
}
```
`final_status` values: `all-success` | `partial-blocked` | `budget-exceeded` | `aborted`.

**Per-track RUN_ID derivation.** `track-wave-preflight.sh` derives each track's `RUN_ID`
deterministically as `<wave-id>_<track-id>` (e.g. `2026-07-20T11-30_wave1_us1`). The orchestrator
exports this as `RUN_ID` when launching each worker — `track-preflight.sh` inside the worker
recognizes it as an override (the `${RUN_ID:-…}` idiom) and uses it as-is, so the per-track JSON
filename naturally carries the wave prefix. On resume the wave dispatch's `track_run_ids[]` list is
the authoritative source — never re-derive manually.

**One run-id, four surfaces.** Each per-track run-id is stamped into ALL of:
- the branch name (`track/us1` … keep the run-id in the record if the branch name is fixed),
- the draft PR title (`track/us1 [run 2026-07-20T11-30_wave1_us1]`),
- a commit trailer (`Run-Id: 2026-07-20T11-30_wave1_us1`),
- the run record filename.

Grep any one surface → reconstruct the whole run.

**Write each track's `goal` as a contract, not a wish.** The `goal` field below is the acceptance
test the worker must pass before it may claim `success` — spell out four things so "done" means
something gradable: the **end state** ("US1 ingest pipeline green per contracts", not "improve
ingest"), the **evidence** required ("integration suite exits 0, output pasted"), the **constraints**
that must hold ("do not edit frozen entrypoints; do not delete existing tests"), and the **budget**
(the hard stops). A goal with no evidence to fail against will always think it succeeded.

**Run record (one per track, git-ignored `runs/` dir).** Each worker writes/updates
`runs/<run-id>.json` — the trace anchor and the orchestrator's memory between ticks.
The record uses the **same two-array schema** as `sso-single-branch-development`:
`trace[]` = hook-observed SubagentStart/Stop (mechanical); `skills[]` = self-reported skill
activations (model's claim, provenance-tagged). Never mix them.
```json
{
  "run_id": "2026-06-26T14-03_us1", "track": "us1", "branch": "track/us1",
  "goal": "US1 ingest pipeline green per contracts",
  "status": "blocked",          // success | blocked | no-progress | budget-exceeded
  "blocker": "flaky Testcontainers Postgres startup",
  "next_step": "pin image tag; retry integration",
  "phase": { "mode": "story", "step": "green", "self_reported": true },   // WHERE it stopped
  "governance_bundle": { "path": "runs/…_us1.governance.md", "sha": "…" },
  "evidence": { "lint": "clean", "unit": "42 passed", "integration": "exit 1" },
  "iterations": 12, "iterations_self_reported": true,
  "tool_calls": 137,             // mechanical (track-meter.sh)
  "token_estimate": 48000,       // rough chars/4 estimate (track-tokens.sh)
  "started_ts": "2026-06-26T14-03-11Z",  // first hook event — run wall-clock start
  "last_ts": "2026-06-26T14-11-05Z",     // last hook event — now − last_ts = idle/staleness
  "pr_url": null,
  "trace": [                     // hook-observed subagent boundaries (track-trace.sh)
    { "t": "…14-05-02Z", "kind": "subagent", "event": "start", "agent_id": "sub-01", "agent_type": "implementer", "reason": "green T038 impl" },
    { "t": "…14-11-05Z", "kind": "subagent", "event": "stop",  "agent_id": "sub-03", "agent_type": "verifier",    "stop_reason": "fail: integration still red" }
  ],
  "skills": [                    // self-reported activations (track-note.sh)
    { "t": "…14-03-40Z", "skill": "subagent-driven-development", "step": "4-green", "self_reported": true }
  ]
}
```
Add `runs/` to `.gitignore`. The orchestrator aggregates all records into `runs/summary.md` for review.
**`status` + `blocker` + `next_step` + `phase` are what make a halted track re-dispatchable** — a
worker that stops without writing them leaves you nothing to route on but a stale worktree.

**Two sources, never conflated.** `trace[]` is hook-observed fact, written by `track-trace.sh` on
subagent start/stop. Everything from `track-note.sh` — `skills[]`, `iterations`, `phase`,
`governance_bundle`, a model-asserted `status` — is the worker's **own claim**, tagged
`self_reported:true` for exactly that reason. Together they give a readable `skill A → subagent X → …`
flow: the cheap middle layer between a one-line `blocker` and the full transcript.
