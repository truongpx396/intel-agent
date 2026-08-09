# Governance Discovery & the Persisted Governance Bundle

The standing rules a run must satisfy — the project **constitution**, the matched
**`.github/instructions/*`**, the **design artefacts** for frontend work — are not review
paperwork. They are *maker* constraints: the brief that produces the code must already carry them,
or you pay a review round-trip for every violation. This reference owns the full procedure. The
SKILL body carries only the summary and the hard rules.

**Run this once, at execution-core entry, before any code is written or any subagent is
dispatched.** It is a main-session, in-context read — see [Why it can't be delegated](#why-it-cant-be-delegated).

## The problem this procedure solves twice

There are two distinct failure modes, and the fix for one is not the fix for the other.

1. **The governance was never read.** A maker brief that says *"follow `go.instructions.md`"*
   passes a filename to an agent whose context does not contain that file. The subagent has nothing
   to act on. This is the round-trip that ships hardcoded `POSTGRES_PASSWORD` in a bootstrap PR.
2. **The governance was read, then lost.** This pipeline runs long — an execution core spans N
   maker + reviewer dispatches. Somewhere in there the session's context gets **compacted**, and
   bulk pasted file content is the first thing compaction drops. Afterwards the model remembers
   *that* it read the instructions but no longer holds the excerpts, so it silently degrades into
   failure mode 1 — while believing it complied.

Reading the files fixes (1). Only **persisting the distilled bundle to disk** fixes (2).

## Step 1 — Discover

Read these, in this order. Each is a **valid no-op when the file genuinely does not exist** — but
the *check* must happen, and its outcome must be stated. Never no-op by omission.

1. **Constitution** — `.specify/memory/constitution.md`. Extract the principles that bear on this
   task's surface. Absent → note it and continue.
2. **Matched instructions** — **list the directory, then match globs. Do not work from a remembered
   list of filenames.** For every file in `.github/instructions/`, read its `applyTo` front-matter
   glob and read the file if that glob overlaps the paths this task batch will touch.

   ```bash
   for f in .github/instructions/*.instructions.md; do
     printf '%s\t%s\n' "$(basename "$f")" \
       "$(sed -n 's/^applyTo:[[:space:]]*//p' "$f" | head -1)"
   done
   ```

   This is deliberately mechanical: the set of instruction files is per-repo and changes over time,
   and `track-audit.sh` check **G2** re-derives the matched set from the same `applyTo` globs. Any
   file matched by G2 but absent from your bundle is a FAIL, so an enumeration you carry in your head
   will eventually disagree with the gate. Two consequences worth knowing:
   - A file with **no `applyTo`** is never auto-matched and G2 never requires it. **Two files are
     deliberately in this category, and neither belongs in the bundle:**
     - `code-review-generic.instructions.md` — a reviewer rubric, loaded at the review step (see
       step 5).
     - `agent-skills.instructions.md` — a **design-time authoring guide, invoked explicitly**. Read it
       when the task *is* to design a new skill or restructure an existing one: name it, read it, then
       build. A routine edit to a `SKILL.md` (fixing a step, a command, a version) does **not** pull it
       in, and G2 will not ask for it.
   - Two files are easy to miss because they are not language files, and both match on path/name
     rather than extension:
     - `ai-agent-security.instructions.md` and `ai-agent-engineering.instructions.md` — both match
       agent/tool/MCP/prompt/RAG paths, and they are a pair: security owns the threat surface,
       engineering owns the loop, state, context, evals, and telemetry. Their globs are a heuristic
       and agentic code hides under many names, so **if the diff wires an LLM to a capability (tools,
       MCP, memory, retrieval, delegation) or changes how one is steered, treat both as matched even
       when no glob hit.** Note they apply to *this* repo's own skills and hooks, which are themselves
       an agentic system.
3. **Design context (frontend only)** — when the surface includes `**/*.tsx`, `**/*.ts`, `**/*.jsx`,
   `**/*.css` or any other frontend file, read the design artefacts if present (pass silently if
   absent, never fail): `.stitch/designs/<page>.html` for the page being built, and the
   `design-system/` master + page spec. Generated UI must match the approved design from the start
   rather than diverging into a separate alignment pass.
4. **Security** — for any cluster touching a trust boundary (auth, secrets, network, persistence,
   deploy config): `security-and-owasp.instructions.md`.
5. **NOT here: the review rubric, and not the skill-authoring guide.** Both carry no `applyTo`, so
   neither is part of the matched set and neither goes in the bundle.
   - `code-review-generic.instructions.md` is a *reviewer* rubric, not a maker constraint. It is
     loaded later, at the review step, and passed into the `requesting-code-review` / stage-2 reviewer
     brief — see [The review step reads its own rubric](#the-review-step-reads-its-own-rubric).
   - `agent-skills.instructions.md` is a *design-time* guide read on explicit request (step 2). If
     this run's actual task is authoring or restructuring a skill, read it then and say so — but it is
     never pulled in merely because a `SKILL.md` appears in the diff.

### Budget the read — distil, don't hoard

The matched set is large: `security-and-owasp` alone is ~1,100 lines, and a Go+React+compose surface
can match ~3,000 lines across several files. Holding all of that raw in the main session for the whole
core is the single biggest context-pressure source in this pipeline, and it is exactly what
compaction evicts. (Scoping the review rubric out of the maker phase — step 5 — is part of the same
budget: it is ~400 lines that only the reviewer needs.)

So **read fully, then distil immediately**. What you carry forward is not the files — it is the set
of *binding constraints that apply to this diff*, each one concrete enough to act on
(`pin image tags, never :latest`, not `follow container best practice`). Typically 30–60 lines total.
Write those to the bundle (Step 2) and let the raw text go.

## Step 2 — Persist the bundle

Write the distilled constraints to **`runs/<RUN_ID>.governance.md`**, then pin it into the run
record:

```bash
bash .github/hooks/track-note.sh governance "runs/$RUN_ID.governance.md"
```

`runs/` is gitignored, so the bundle never pollutes the diff or shifts the evidence fingerprint.
`track-note.sh governance` records the path **and a sha**, so a later reader can tell whether the
bundle changed after the briefs were built; `track-reconcile.sh` reports
`position.governance_bundle_present:false` and tells you to re-run discovery if the file has since
vanished.

### Bundle format

```markdown
# Governance bundle — run <RUN_ID>
Surface: backend-go/**, deploy/compose.yml

## Constitution (.specify/memory/constitution.md) — PRESENT
- kernel/ must not import from internal/product/** (principle 3)
- coverage floor 80% on new packages (principle 7)

## go.instructions.md — matched **/*.go
- errors wrapped with %w, never %v
- no naked returns in exported funcs

## security-and-owasp.instructions.md — matched (compose touches secrets + network)
- pinned image digests, never :latest
- no default credentials committed; env placeholder + documented dev fallback

## Design (.stitch/designs/…, design-system/…) — ABSENT (no frontend surface)

## Cluster → binding sections  (only when the core fans out to parallel makers)
- go cluster (cmd/, kernel/, internal/, go.mod): Constitution I/II, go
- deploy cluster (compose.yml, Caddyfile, .env*): devops-cicd, backing-services, security-and-owasp
```

State **ABSENT** explicitly for every check that no-opped. An absent line is proof the check ran; a
missing line is indistinguishable from a skipped check.

### Pre-slice governance to the clusters that will consume it

The per-file sections above are organized by *instruction file*, but a fan-out core
(`dispatching-parallel-agents`) dispatches **one brief per disjoint-file cluster** — and each brief
carries only the governance that binds *its* files, not the whole bundle. Whenever the core fans out
to more than one parallel maker (scaffold `generate`, story RED-authoring, refactor pin-green),
append a **`## Cluster → binding sections`** map so that slicing is done **once, in the bundle**,
not re-derived per dispatch. Each row names a cluster (by its file surface) and lists exactly which
sections above bind it — including `ABSENT`/design notes where they matter (a frontend cluster with
no design artefact should say so). A single-brief core (a lone story task, N=1) does not need the
map: there is only one consumer. See [`scaffold-mode.md`](scaffold-mode.md) GENERATE for the
cluster-brief contract this feeds.

## Step 3 — Push it into every brief

Every subagent brief — `dispatching-parallel-agents` fan-out makers **and**
`subagent-driven-development` per-task makers and reviewers — embeds the **bundle's content**, and
says it is binding: the code it returns must *already* satisfy these (pinned image tags, no
committed default credentials, secure headers, strict type/lint, parameterized queries).

When the bundle carries a **`## Cluster → binding sections`** map, a fan-out brief embeds **only the
sections that map names for its cluster** — the whole bundle re-pasted into every brief is context
waste and buries the constraints that actually bite. The map is the routing table; the per-file
sections are the content it points at. Embed content, never the filename or the bare row.

Governance therefore gates **both ends** — the maker brief prevents the violation, the review
catches what slipped through. That is deliberate defense-in-depth, not redundancy. Review is the
backstop, never the first place governance is consulted.

### This step is now audited, not trusted

`track-brief.sh` (a `PreToolUse` hook on the dispatch tool) reads the outgoing brief and counts how
many of the bundle's constraint lines it actually contains — the one hop nothing used to observe.
`track-audit.sh` check **G6** turns that into a verdict:

- **A brief that carried zero bundle constraints is a FAIL.** That is the filename-passing failure
  mode, and no amount of *"follow `go.instructions.md`"* clears it.
- **A brief that carried some but few is a WARN.** A fan-out brief embeds only its cluster's sections,
  so a low count is expected — the hook reports rather than judges.
- **A dispatch that genuinely needs no governance must say so.** Read-only research and exploration
  dispatches carry no maker constraints; declare that in the brief on its own line and the audit
  records the decision instead of counting it as a miss:

  ```
  GOVERNANCE: n/a — read-only research, returns findings only, writes nothing
  ```

  Same rule as the bundle's own `ABSENT` lines: an explicit declaration is proof the question was
  asked; silence is indistinguishable from forgetting.

Matching text is not judging relevance — G6 cannot tell whether the sections you sliced are the ones
binding *that* cluster. That narrower question is what the audit still lists as a human check.

### Widening the bundle mid-core: re-distil and re-pin

If a later cluster drags in an instruction file the first pass did not match (a `.tsx` file appears in
a run that started backend-only), **do not** patch the file and move on: re-distil the new
constraints into the bundle and call `track-note.sh governance <path>` again. Re-pinning is
append-only — `governance_stamps[]` keeps the history — so G3 asks whether *every* dispatch was
preceded by *some* pin rather than penalizing the re-pin, and G1 reports how many briefs were built
from the earlier version so a reviewer can confirm those clusters did not need the added constraints.
Editing the bundle **without** re-pinning is the case that still WARNs: the record then describes
constraints no brief provably carried.

## Step 4 — Re-anchor after a compaction

If the context was compacted (or the session crashed and resumed) at any point during the core:
**re-read `runs/<RUN_ID>.governance.md` from disk before dispatching the next subagent.** It is a
~50-line read, it is authoritative, and it costs nothing next to shipping an ungoverned brief.
`track-reconcile.sh`'s `resume_action` says this explicitly on every resume.

Both halves of this are now gated. `I4` fails a run that dispatched after a compaction with no
bundle re-read in between — **and** a run where the re-read happened but the very next brief still
went out carrying none of the bundle. Re-reading the file and then briefing from memory anyway is the
exact shape of the silent degradation, so it is checked, not assumed.

## The review step reads its own rubric

`code-review-generic.instructions.md` is loaded **at the review step, not at core entry**. When you
dispatch `requesting-code-review` (or the stage-2 reviewer):

1. Read `.github/instructions/code-review-generic.instructions.md` in the main session.
2. Embed the parts that bear on this diff — review priorities, the comment format, the checklist
   sections that apply — into the reviewer's brief, **as content**, exactly like the governance
   bundle. The same "filenames transfer nothing" rule applies.
3. Add the governance bundle alongside it. The reviewer needs both: the rubric tells it *how* to
   review, the bundle tells it *what this project requires*.

On precedence, so the reviewer does not have to guess: `security-and-owasp.instructions.md` wins on
security, the matched language file wins on language specifics, and the rubric governs review process
and output format.

It stays out of the maker phase for two reasons: it restates the language files generically (~400
lines of duplication in every brief), and a rubric for judging finished work is noise in an
instruction to write it.

## Why it can't be delegated

- **Not a subagent task.** Subagents have isolated context. "Read the instructions, then brief
  yourself" does not survive the process boundary — whatever the subagent learned dies with it.
- **Not a filename reference.** Passing `go.instructions.md` to an agent that cannot open it, or
  whose context does not hold it, transfers nothing. Pass content.
- **Editor auto-injection does not propagate.** VS Code's `applyTo` injection populates the *main*
  session only; it reaches no dispatched subagent. Claude Code does not auto-inject at all. Both
  are why this procedure is skill-driven rather than editor-driven — the gate is identical on
  either surface.

## Checklist

- [ ] Constitution read, or explicitly noted absent
- [ ] `.github/instructions/` **listed** and every `applyTo`-matching file read — matched by glob at
      run time, not from a remembered list (a `SKILL.md` in the diff pulls in the two `ai-agent-*`
      files, whose globs cover it)
- [ ] Design artefacts read for any frontend surface, or noted absent
- [ ] `security-and-owasp.instructions.md` read for any trust-boundary surface
- [ ] `code-review-generic.instructions.md` **not** in the bundle — it is loaded at the review step
      and embedded in the reviewer brief instead
- [ ] `agent-skills.instructions.md` **not** in the bundle — it is a design-time authoring guide,
      read only when the task is explicitly to design or author a skill
- [ ] Constraints distilled and written to `runs/<RUN_ID>.governance.md` — each matched file's section
      carries ≥2 actionable bullets, not just a heading (`G5` fails a hollow section)
- [ ] `## Cluster → binding sections` map added when the core fans out to parallel makers
- [ ] `track-note.sh governance <path>` called — again after any mid-core re-distil
- [ ] Bundle content embedded in every maker and reviewer brief (`G6` counts it in the brief text);
      any dispatch that needs none declares `GOVERNANCE: n/a — <why>`
