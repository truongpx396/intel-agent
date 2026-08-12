# Governance & Feature-Context Discovery — the Persisted Bundle

Two things must reach a maker before it writes a line, and neither survives being remembered instead
of read: the standing rules a run must satisfy — the project **constitution**, the matched
**`.github/instructions/*`**, the **design artefacts** for frontend work — and, when a SpecKit layout
is present, **what the task actually means** — the scoped slice of `spec.md`/`plan.md`/`research.md`/
`data-model.md`/`contracts/` that bears on *this* task, not the whole feature. Neither is review
paperwork. They are *maker* constraints and *maker* context: the brief that produces the code must
already carry them, or you pay a review round-trip for every rule violation, or a
guess-the-requirement round-trip for every misread task. This reference owns the full procedure —
governance discovery is Step 1 items 1–5,
feature-context discovery is item 6 — sharing one persistence and brief-embedding mechanism for both.
The SKILL body carries only the summary and the hard rules.

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
3. **The feature context was read whole, not scoped.** Unique to item 6: a `spec.md`/`plan.md`
   covering five user stories, read in full for a task that touches one, buries the three lines that
   matter under forty that don't — a maker that "read the spec" but was never told which slice binds
   *this* task is functionally back at failure mode 1, just with a bigger file. It also burns the
   same context budget `security-and-owasp`'s ~1,100 lines already put pressure on, for content most
   of which this task doesn't need.

Reading the files fixes (1). Persisting the distilled bundle to disk fixes (2). Scoping discovery to
the task's own tags *before* distilling fixes (3) — see item 6 below.

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
6. **Feature/task context — SpecKit artifacts, when present.** Not a constraint like 1–4 above — it
   is *what the task means*: the requirements, acceptance criteria, design decisions, and contract
   shapes the maker must build against. Read from the SpecKit layout
   (`specs/<slug>/{spec.md,plan.md,research.md,data-model.md,contracts/,quickstart.md}`), when it
   exists. **Absent is a valid no-op** — a repo with no `specs/` tree, or tasks handed over as a
   plain list, has nothing to discover here; state that and move on, same as any other no-op check.

   **Locate the feature directory from what this run already knows — never guess.** This run's task
   IDs are authoritative: the `TASKS` value confirmed in Step 1's preflight summary (e.g.
   `T001-T009`, persisted to `runs/<RUN_ID>.dispatch` when set) if supplied, otherwise the task IDs
   named in the prompt that started this run. The `specs/*/tasks.md` naming those IDs is the feature
   directory. Exactly one `specs/*/` → that's it. More than one → grep each `specs/*/tasks.md` for
   this run's task IDs and take the directory that matches. Never infer it from the branch name or
   track slug alone — those can drift from the SpecKit slug, and a mismatch silently briefs makers
   from the wrong feature.

   **Scope to the task, never ingest the whole feature — this is the discipline that saves the
   context.** A single `spec.md`/`plan.md` commonly spans every user story in the feature; a
   `research.md` accumulates decisions across all of them; `contracts/` can hold every endpoint the
   feature will ever need. Reading all of it into the bundle — and from there into every brief — is
   the same context-pressure mistake the next section already guards against for `security-and-owasp`,
   worse here because most of a multi-story spec is irrelevant to any single task. Match the task's
   own tags, the same way item 2 matches `applyTo` globs — by task shape instead of by file glob:
   - **By user-story tag.** SpecKit tasks are conventionally tagged (`T012 [US2] ...`). Pull only the
     `spec.md` requirements and acceptance criteria filed under that story's heading — not the
     document, and not the other stories' sections.
   - **By named artifact.** A task line or `plan.md` reference naming a specific file
     (`contracts/rag-ingest.md`, a `data-model.md` entity) scopes discovery to that file or section,
     not the directory it lives in.
   - **When a task spans stories or names nothing specific**, read the surrounding section headings
     in `spec.md`/`plan.md` and use judgement — but still distil to the bullets that bear on *this*
     task; never transcribe a section wholesale because scoping it precisely was harder.
   - **Never re-author.** This is a read, not a planning step — spec-writing stays upstream (see
     Prerequisites in the SKILL body). If the spec is silent on something the task needs, that's a
     blocker to surface, not a gap the execution core improvises around.

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

Feature context (item 6) follows the identical discipline with one filter applied *first*: scope
**before** you read, not after. Locate the task's slice (user-story heading, named artifact) and read
only that slice — not the surrounding document — then distil it exactly like a matched instruction
file: concrete bullets a maker acts on (`chunks ≤ 800 tokens, preserve doc boundaries`, not `see
spec.md for chunking rules`).

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

## Feature context — specs/003-rag-ingest/ (task T012, [US2] chunked ingestion) — PRESENT
- spec.md §US2: chunks must preserve source-document boundaries; 800 tokens max per chunk
- plan.md "Architecture": ingestion runs as a queued worker, never inline on upload
- research.md: chunker = recursive-character-split (rejected fixed-token: loses semantic
  boundaries per spike 2026-06-02)
- contracts/rag-ingest.md: POST /ingest {doc_id, source_uri} -> emits IngestCompleted{doc_id,
  chunk_count}

## Cluster → binding sections  (only when the core fans out to parallel makers)
- go cluster (cmd/, kernel/, internal/, go.mod): Constitution I/II, go, Feature context (US2 only)
- deploy cluster (compose.yml, Caddyfile, .env*): devops-cicd, backing-services, security-and-owasp
```

State **ABSENT** explicitly for every check that no-opped. An absent line is proof the check ran; a
missing line is indistinguishable from a skipped check — this applies to the Feature-context section
exactly as it does to Constitution/Design: no `specs/` tree found → `## Feature context — ABSENT (no
SpecKit layout in this repo)`, not a silently omitted heading.

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

The same map slices **Feature context** too, at the same per-cluster granularity, and it can be
*narrower* than the file-scoped map above — a cluster whose files touch only one user story lists
just that story's bullets, not the whole Feature-context section; a cluster spanning stories lists
each one it needs. This is the mechanical form of the "scope to the task" rule in item 6: the slicing
decision is made once, here, instead of every dispatch re-deciding how much of the spec to paste.

## Step 3 — Push it into every brief

Every subagent brief — `dispatching-parallel-agents` fan-out makers **and**
`subagent-driven-development` per-task makers and reviewers — embeds the **bundle's content**, and
says it is binding: the code it returns must *already* satisfy these (pinned image tags, no
committed default credentials, secure headers, strict type/lint, parameterized queries). Feature
context travels the identical way: the brief states the scoped requirement/acceptance-criteria/
contract text as what the maker must build, never a pointer like "see `spec.md`" or "per `contracts/
rag-ingest.md`" — that is the same filename-passing failure the governance half already forbids.

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
a run that started backend-only) — or a later task pulls in a user story or contract the first pass
did not scope — **do not** patch the file and move on: re-distil the new constraints (or the new
feature-context slice) into the bundle and call `track-note.sh governance <path>` again. Re-pinning is
append-only — `governance_stamps[]` keeps the history — so G3 asks whether *every* dispatch was
preceded by *some* pin rather than penalizing the re-pin, and G1 reports how many briefs were built
from the earlier version so a reviewer can confirm those clusters did not need the added constraints.
Editing the bundle **without** re-pinning is the case that still WARNs: the record then describes
constraints no brief provably carried.

## Step 4 — Re-anchor after a compaction

If the context was compacted (or the session crashed and resumed) at any point during the core:
**re-read `runs/<RUN_ID>.governance.md` from disk before dispatching the next subagent.** It is a
~50-line read, it is authoritative, and it costs nothing next to shipping an ungoverned — or
context-blind — brief. One file, one re-read: the Feature-context section is re-anchored the same
motion as the governance sections, since both live in the same pinned bundle.
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

This applies identically to governance discovery (items 1–5) and feature-context discovery (item 6) —
neither is a lesser cousin of the other's rule:

- **Not a subagent task.** Subagents have isolated context. "Read the instructions, then brief
  yourself" — or "read the spec, then brief yourself" — does not survive the process boundary;
  whatever the subagent learned dies with it.
- **Not a filename reference.** Passing `go.instructions.md`, or `spec.md#us2`, or
  `contracts/rag-ingest.md`, to an agent that cannot open it, or whose context does not hold it,
  transfers nothing. Pass content.
- **Editor auto-injection does not propagate.** VS Code's `applyTo` injection populates the *main*
  session only; it reaches no dispatched subagent, and has no equivalent for `specs/` content at all.
  Claude Code does not auto-inject either. Both are why this procedure is skill-driven rather than
  editor-driven — the gate is identical on either surface.

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
- [ ] Feature/task context (item 6) resolved from `specs/<slug>/` matched against this run's task
      IDs — never guessed from the branch name — or explicitly noted absent when no SpecKit layout
      exists
- [ ] Feature-context distilled to the task's own scope (user-story tag or named artifact) **before**
      reading, not transcribed from the whole `spec.md`/`plan.md`/`research.md`/`data-model.md`
- [ ] Constraints distilled and written to `runs/<RUN_ID>.governance.md` — each matched file's section
      carries ≥2 actionable bullets, not just a heading (`G5` fails a hollow section)
- [ ] `## Cluster → binding sections` map added when the core fans out to parallel makers, and it
      slices Feature-context sections per-cluster the same way it slices instruction sections
- [ ] `track-note.sh governance <path>` called — again after any mid-core re-distil (governance or
      feature-context)
- [ ] Bundle content embedded in every maker and reviewer brief (`G6` counts it in the brief text,
      governance and feature-context lines alike); any dispatch that needs none declares
      `GOVERNANCE: n/a — <why>`
