# Prompt-Level Invariant Checklist

*13 items automated · 4 partly automated · 12 human-only*

**Most of this list is now automated — run [`../scripts/track-audit.sh`](../scripts/track-audit.sh)
first.** It re-derives every ⚙️-marked item below from durable artifacts (the run record, the
governance bundle, the diff) in about a second, and blocks on failure. Only the ✋ items need a human.

```bash
bash .github/hooks/track-audit.sh          # report; exit 2 on any FAIL
bash .github/hooks/track-audit.sh --json   # same verdicts for tooling
```

Wire it as a blocking Stop gate with `TRACK_AUDIT=1` (opt-in — see
[hooks.md](../references/hooks.md)), and run it at the draft-PR boundary regardless.

**Why a ✋ half still exists.** A hook sees one event; the audit sees artifacts. Neither can read
*reasoning* — whether the constraints a brief carried were the ones binding its cluster, whether a
reviewer engaged or rubber-stamped, whether a RED test failed for the right reason rather than a typo.
Those are checked by a person reading the transcript, and pretending otherwise would manufacture
exactly the false confidence this pipeline exists to prevent.

*(Brief **content** used to sit on this side of the line — "open a dispatch and look". It moved:
`track-brief.sh` reads the outgoing brief at `PreToolUse` and `G6` fails a dispatch that carried none
of the bundle. What stayed manual is narrower and genuinely judgement: whether the right sections were
sliced to the right cluster.)*

**When:** after any change to a SKILL.md or mode reference, and spot-check on real runs.
**Inputs:** the session transcript, `runs/<RUN_ID>.json`, `runs/<RUN_ID>.governance.md`, the diff.

Legend: ⚙️ = checked by `track-audit.sh` (id in brackets) · ✋ = human only.

## Coverage by pipeline step

What a reviewer sees in the PR body when a step is missed:

| Step | Missed → surfaced? |
|---|---|
| 1 Preflight & confirm | ⚙️ `I2` (no breadcrumb) |
| 2 Reconcile / resume | ⚙️ `I3` (no `last_reconcile` stamp) |
| — Compaction mid-run | ⚙️ `I4` (a dispatch after a compaction with no bundle re-read in between, **or** a first post-compaction brief that carried none of the bundle) |
| 3 Isolate | ⚙️ `I1` (on the default branch → FAIL; branch-in-place → WARN) |
| 4 Governance gate | ⚙️ `G1`–`G6` (`G5` bundle substance, `G6` the brief actually carried it) |
| 4 Mode guard + core | ⚙️ `P1`/`P2`, `T1`, `T2` |
| 5 Convergence | ⚙️ `E1` |
| 6 Evidence gate | ⚙️ `E2` + the evidence table + compliance warnings |
| 7 Run record | rendered in the Auto block |
| 8 Terminal state | ⚙️ `F1` |
| **the whole bundle** | 🏗 CI (`agent-pr-audit.yml`) — a run that skipped everything produces *no* Auto block, and a reporter cannot report on its own absence, so the check lives outside the agent. Scope comes from five signals, not the agent's own `agent-generated` label: a run that skips the bundle also skips the labeling step, so the load-bearing signal is the harness-written `Co-Authored-By` commit trailer. CI also cross-checks the block's declared counts against its rendered rows, since a hand-edited block is the last way a failing audit reaches a reviewer looking clean |

---

## A. Governance (the round-trip that ships credentials)

- [ ] ⚙️ **A1** `[G3]` — **Every** subagent dispatch was preceded by a governance pin. Derived by
      comparing the append-only `governance_stamps[]` history against every `trace[]` dispatch — so a
      deliberate mid-core re-pin (a later cluster widened the matched set) is legal, while a dispatch
      with no pin at or before it still fails.
- [ ] ✋ **A2** — `.specify/memory/constitution.md` was read, **or** its absence is explicitly stated
      in the bundle. A missing line is indistinguishable from a skipped check.
- [ ] ⚙️ **A3** `[G2, G4]` — Every `applyTo`-matching instruction file appears in the bundle for the
      actual diff surface; `security-and-owasp` whenever a trust-boundary path is touched.
- [ ] ⚙️ **A4** `[G1]` — `runs/<RUN_ID>.governance.md` exists and its sha still matches the latest pin.
- [ ] ⚙️ **A4b** `[G5]` — Each matched file's bundle section carries **actionable constraints**, not
      just a heading. G2 is a substring test and a hollow section satisfies it; G5 reads the section
      body and fails a bundle that names a file without distilling anything from it.
- [ ] ⚙️✋ **A5** `[G6]` — Maker briefs embed governance **content**, not filenames.
      `track-brief.sh` (PreToolUse on the dispatch tool) reads the outgoing brief and counts how many
      bundle constraint lines it carries, so *"Follow `go.instructions.md`"* — zero lines — is now a
      **FAIL**, not a trust item. What is still manual: whether the sections sliced into that brief
      were the ones binding **its** cluster. Open one fan-out dispatch and check the slice.
- [ ] ✋ **A6** — Frontend clusters carry the design artefacts (`.stitch/designs/…`,
      `design-system/…`) when they exist.

## A′. Isolation & resume (the early bracket)

- [ ] ⚙️ **A7** `[I1]` — The work was isolated: a linked worktree on its own branch. Working on the
      default branch is a FAIL; branch-in-place warns, since it is allowed only as the documented
      `using-git-worktrees` fallback *after* the limitation was surfaced.
- [ ] ⚙️ **A8** `[I2]` — A preflight breadcrumb exists and its approved branch matches the branch the
      work actually landed on. Drift means the approved plan and the real work diverged silently.
- [ ] ⚙️ **A9** `[I3]` — `track-reconcile.sh` ran (it stamps `last_reconcile`). Absent means either
      the SessionStart hook is unwired or the run never re-anchored from durable state.

## B. Compaction resilience (the invariant that silently degrades)

- [ ] ⚙️ **B1** `[P1, P2]` — `phase` was stamped, and `phase_log[]` covers the canonical gate
      sequence for the recorded core.
- [ ] ⚙️ **B2** `[I4]` — If the session was compacted: the bundle was **re-read from disk** before the
      next dispatch, **and the first brief after the compaction actually carried its constraints**.
      `track-compact.sh` records both halves of the re-read as hook-observed facts (`compactions[]`
      from `PostCompact`, `governance_reads[]` from `PostToolUse`); `track-brief.sh` records what the
      next brief contained. I4 now fails a run where the bundle was re-read and the following brief
      still went out empty — the silent post-compaction degradation this gate exists for. No longer a
      manual read.
- [ ] ✋ **B3** — After any resume, `track-reconcile.sh` ran and its `resume_action` was **acted on**,
      not merely printed.
- [ ] ✋ **B4** — Position was never rebuilt by reading the worktree ("let me look at what's there and
      figure out where I was"). Forbidden after a compaction exactly as after a crash.

## C. Maker/checker separation

- [ ] ⚙️ **C1** `[M1]` — At least two distinct `agent_id`s in `trace[]`. Note the audit can only
      prove separation was *possible*; Claude Code's `SubagentStop` omits ids entirely, and it says
      so rather than passing silently.
- [ ] ✋ **C2** — The controller never authored what it applied. In scaffold mode especially: bodies
      came back **from subagents**, not the controller's own reasoning. A converged tree the
      controller wrote itself is a violation even though it looks identical.
- [ ] ✋ **C3** — Review actually applied the governance rubric, rather than generic "looks good".

## D. Test discipline

- [ ] ⚙️✋ **D1** `[T1]` — *(story)* The audit proves a failing capture exists **before** the passing
      one, so the suite genuinely ran red. Whether it failed for the **right reason** — a real unmet
      expectation, not a typo or missing import — is still yours to read.
- [ ] ⚙️ **D2** `[T2]` — No frozen test weakened to green: the audit flags added `skip`/`only`
      markers and removed assertion lines in test files.
- [ ] ✋ **D3** — *(refactor)* Characterization tests passed **immediately** at baseline. One that
      failed is a wrong test, not a discovered bug.
- [ ] ✋ **D4** — *(refactor)* The suite was green after **every** transform step, not only at the end.
- [ ] ✋ **D5** — *(refactor)* The public contract diff is empty.
- [ ] ⚙️✋ **D6** `[G4]` — *(scaffold)* The audit fails a diff touching a trust boundary without
      security governance; whether each *task* carried a test obligation is a judgement call.

## E. Evidence honesty

- [ ] ⚙️ **E1** `[E1]` — Every kind's latest capture shares **one** fingerprint (the convergence
      gate), with no edit after it.
- [ ] ⚙️✋ **E2** `[E2]` — The audit warns on suspiciously short *passing* captures, since a
      truncated pass-looking response satisfies the gate trivially. Whether the output was actually
      **read** is yours.
- [ ] ✋ **E3** — No completion claimed before the creating command returned. "Draft PR opened"
      requires a printed PR URL.

## F. Terminal states

- [ ] ⚙️ **F1** `[F1]` — A run that could not finish wrote `status` + `blocker` — it did not open a
      PR "with a caveat".
- [ ] ✋ **F2** — Self-heal retries stayed within `TRACK_SELF_HEAL_ATTEMPTS` per **distinct** failure.
- [ ] ✋ **F3** — Infra failures (timeouts, image pulls) were retried at the orchestrator layer, not
      charged to the self-heal budget.

---

## Scoring

Any unchecked box in **A**, **B**, or **C** is a defect in the run, not a stylistic note — those are
the three that fail *silently* and produce plausible-looking output. **D**–**F** failures usually
surface later as a red CI or a reverted PR; **A**–**C** failures ship.

A clean `track-audit.sh` clears the ⚙️ items and nothing more. The ✋ items are where the residual
risk now lives — concentrated, small enough to actually check, and no longer hiding among two dozen
things a script could have told you.
