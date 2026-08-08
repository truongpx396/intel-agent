# Hooks Bundle (Optional, Composable)

This skill **ships the canonical hooks bundle** ([`../scripts/track-*.sh`](../scripts/) +
[`../templates/track-hooks.json`](../templates/track-hooks.json)). The quality gates in `SKILL.md`
are only as strong as the worker's compliance — unless you make them **mechanical**. Hooks turn the
*mechanical* gates (paths, forbidden commands, counters) into enforced ones; *judgement* gates (TDD
ordering, the maker/checker split, review quality) stay as prompt instructions because a hook cannot
tell which subagent reasoned about something.

Orchestrators that compose this skill reuse the same files and only layer extra env on top.

## How Copilot Hooks Work

Copilot's native [agent hooks](https://docs.github.com/en/copilot/concepts/agents/hooks) run shell
commands at lifecycle points (`PreToolUse`, `PostToolUse`, `SubagentStart`, `SubagentStop`, `Stop`,
…) and can **block a tool call before it happens**. Config lives in `.github/hooks/*.json`
(repo-scoped, so it travels with each worktree) and is read by VS Code Agent Mode, the Copilot CLI,
and the cloud agent. A `PreToolUse` hook receives the tool call as JSON on stdin and denies it via
exit code `2` (stderr → model) or `hookSpecificOutput.permissionDecision: "deny"`.

## Portability (No Matchers; Event Names Differ)

- **No `matcher` field.** Unlike Claude Code, Copilot hooks cannot scope to specific tools in
  config. A `PreToolUse` hook fires on **every** tool call, so the script must branch on `tool_name`
  from stdin and early-exit (allow) for tools it doesn't care about — which `track-guard.sh` already
  does.
- **Event names differ by surface.** The bundled `track-hooks.json` uses the VS Code keys
  (`preToolUse`, `postToolUse`, `subagentStart`, `subagentStop`, `stop`); the Copilot CLI /
  cloud-agent docs name the same events `agentStop` / `subagentStop` / `userPromptSubmitted` /
  `sessionEnd`. The *scripts* are surface-agnostic (they read stdin JSON); only the registration keys
  change if you run them under the CLI instead of VS Code.
- **Bash + `jq` only.** The bundle ships no PowerShell port; on non-bash surfaces run the scripts
  under a bash-compatible shell.

## Running Under Claude Code

The hook **scripts are surface-agnostic** — they already read Claude Code's stdin JSON
(`tool_name`, snake_case `tool_input.file_path` / `tool_input.command`, `hook_event_name`,
`stop_hook_active`, `transcript_path`) and already emit Claude Code's contracts
(`hookSpecificOutput.permissionDecision:"deny"` on `PreToolUse`; `{decision:"block", reason}` /
`{continue:false, stopReason}` on `Stop`). Only the **wiring** that registers the scripts differs,
and the bundle now ships both:

- **Copilot** → [`../templates/track-hooks.json`](../templates/track-hooks.json) copied into
  `.github/hooks/` (repo-scoped Copilot agent hooks).
- **Claude Code** → [`../templates/claude-settings.json`](../templates/claude-settings.json)
  merged into `.claude/settings.json`.

Install the Claude Code wiring with the same installer:

```bash
install-hooks.sh --surface claude --apply   # or omit --surface (default: both) to wire both surfaces
install-hooks.sh --surface claude --check   # reports whether .claude/settings.json is wired
```

`--apply` syncs the shared `track-*.sh` scripts, gitignores `runs/`, seeds `track-env.base.sh`, and
**appends** the hooks block into `.claude/settings.json` — append-only and dedup'd by block, so your
other settings and hooks are preserved and re-running is idempotent. The `track-*.sh` still live in
`.github/hooks/` and travel into every worktree exactly as under Copilot; only the registration moves
to `.claude/settings.json`.

### Event & matcher mapping

Claude Code **does** scope hooks by a `matcher` (an advantage over Copilot's fire-on-every-call
model), so the wiring is tighter than the Copilot manifest:

| Claude Code event | matcher | script(s) |
|---|---|---|
| `SessionStart` | — | `track-reconcile.sh` |
| `PreToolUse` | `Write\|Edit\|MultiEdit\|NotebookEdit\|Bash` | `track-guard.sh` |
| `PreToolUse` | `Task` | `track-brief.sh` |
| `PostToolUse` | `Bash` | `track-evidence.sh` |
| `PostToolUse` | `*` | `track-meter.sh` |
| `PostToolUse` | `Read\|Bash\|Grep` | `track-compact.sh` |
| `PreCompact` / `PostCompact` | — | `track-compact.sh` |
| `SubagentStart` / `SubagentStop` | — | `track-trace.sh` |
| `Stop` | — | `track-evidence-gate.sh`, `track-tokens.sh`, `track-sentinel.sh`, `track-audit.sh --hook`, `track-notify.sh` |

### One Claude Code delta to know

- **`SubagentStart` must be wired, or the trace has no "why".** It is a real Claude Code event
  (the Copilot manifest has always wired its `subagentStart` equivalent), but the Claude template
  omitted it for a long time on the belief that only `SubagentStop` existed. The cost is specific:
  `agent_description` — the subagent's one-line reason for being spawned — is carried on **start
  only**, and `SubagentStop` has `stop_reason` instead. With just the stop event wired, a trace
  reads `SubagentStop general-purpose (a9b0798…)` five times over and tells a reviewer nothing
  about what any of those agents were for. `track-trace.sh` already reads every known spelling of
  the field; it just needs the event.
- **No `applyTo` auto-injection.** VS Code auto-loads `.github/instructions/*` by their `applyTo`
  globs; Claude Code does not. This is a **no-op for correctness** because the skill's governance gate
  already mandates reading the matched instruction files in-session — the governance gate is driven by the
  skill body, not by editor auto-injection.
- **Stop-block exit code.** Claude Code blocks a stop only on exit **2** (exit 1 is a *non-blocking*
  error that lets the stop proceed). The gates that block via `{decision:"block"}` JSON
  (`track-evidence-gate.sh`, `track-sentinel.sh`) are exit-code-agnostic; `track-tokens.sh` blocks via
  exit **2**, which is also non-zero so Copilot still blocks on it.

## Bundled Scripts

| Pipeline gate | Bundled script (event) | What it does |
|---|---|---|
| Start gate / mint-or-recover RUN_ID | `track-preflight.sh` (manual / skill Step 1) | **Start gate.** `inspect` mints a stable `RUN_ID` = `<UTC>_<track>` on a fresh start, or **recovers** it from an existing `runs/<id>.dispatch` breadcrumb (resume), then checks prerequisites (git tree, `runs/` writable, opt. `gh` auth + `PREFLIGHT_REQUIRE_TOOLCHAIN` bins). Prints a confirm summary + JSON; **hard-fails non-zero** on any unmet prereq — including under `--yes`, because a missing dep is not a preference. `--yes` (or `AUTO_CONFIRM=1`) waives **only** the interactive proceed-confirm and exists for one caller: an orchestrator-dispatched worker, which has no human to ask and whose human gate was taken upstream at the wave plan. The waiver is recorded (`auto_confirm:true` / `confirmed_by:"orchestrator-waiver"`) in both the JSON and the breadcrumb so an audit can tell an approved run from a waived one. `--persist` persists the breadcrumb (track, tasks, branch, base ref, plus the confirmed writable scope, frozen paths, required toolchain, and evidence floor with their `*_set` flags) so resume is self-recovering and the artifact records exactly what the human confirmed. `--persist` also persists `RUN_ID` as a managed block in the installed `.github/hooks/track-env.sh` (gated on the `track-env.base.sh` marker, so it never touches the skill's `scripts/` source mirror) — this **activates the recorder hooks for a solo run** with no manual export. The block is **self-retiring**: it adopts its id only while the run is **live** (no terminal `status` in the record, no `completed_utc` on the breadcrumb) **and** this checkout is on the run's own branch — an exported `RUN_ID` still outranks it. `--complete` removes the block outright, but completion is reached at draft-PR handoff *only*, so binding adoption to liveness is what retires a run that ended any other way (ceiling trip, `blocked`, crash, abandon). An unconditional `export RUN_ID=…` outlives the run it names and then governs **every later session in the checkout**: the meter re-reads a record whose `tool_calls` already exceeds the ceiling and halts every tool call, and the evidence gate demands the finished task's kinds against the new task's diff. `--complete` (at draft-PR handoff) stamps `completed_utc` + `duration_secs` (now − `created_utc`) onto the breadcrumb — write-once, the honest home for the run's total wall-clock. Run by the skill, not a hook, since it precedes RUN_ID. |
| Dependency version-lock + probe cache *(opt-in)* | `track-deps.sh` (manual / skill Step 1, invoked by `track-preflight.sh`) | Pins the tool versions a client checkout must use to stay aligned with the skill (`superpowers`, `speckit`, `git`, `jq`, …), so an install-target repo does not drift onto an incompatible toolchain. Reads the committed `skill-deps.json` manifest (seeded beside the hooks by `install-hooks.sh`, `git`/`jq` pinned + detected repo tools added `required:false`); each entry is `{range, probe, required}` where `range` is a space-separated AND-list of `>=`/`>`/`<=`/`<`/`=`/bare-`X.Y` bounds (empty = presence-only). Probes every declared tool, compares the extracted version, and **caches a fully-OK result** in `runs/.deps-cache.json` so heavy `--version` calls are not repeated every run — the cache invalidates on `PATH` change, manifest change, or TTL expiry (`TRACK_DEPS_CACHE_TTL_HOURS`, default 72; `0` = never cache). A **failing** environment is never cached (re-checked every run so a fix is seen immediately). `track-preflight.sh` runs it as part of the start gate and folds a lock violation into `missing`. A required tool missing, or (under `TRACK_DEPS_STRICT=1`) any pinned tool out of range, **hard-fails** with exit 3; out-of-range under the default `TRACK_DEPS_STRICT=0` is a non-blocking warning. **No-op** (exit 0) when the manifest is absent. The template seeds `superpowers` to `=6.2.0` and `speckit` to `=0.15.2`. Run by the skill, not a hook, since it precedes RUN_ID. |
| Resume / reconcile after interruption | `track-reconcile.sh` (`SessionStart`/`agentStart`) | Preflight report (read-only w.r.t. the tree/git; it stamps `last_reconcile` into the run record so the audit can prove it ran): from committed history + `runs/<RUN_ID>.json` only, emit `{head, dirty_worktree, evidence:{fresh,stale,missing,failed}, resumable}` at the current fingerprint — so a crashed/credit-out run resumes at the first not-done task and stashes untrusted uncommitted work, instead of the model guessing where it left off. Self-recovers `RUN_ID` from the `runs/<id>.dispatch` breadcrumb when none is exported — **ranked**, not newest-wins: a breadcrumb whose recorded `branch` is the one actually checked out here, then any run not yet stamped terminal, then the newest match. Taking the newest outright adopts a finished run on an unrelated branch just as readily as this session's own, and then every line of the report describes the wrong task. No-op unless a `RUN_ID` is set or recoverable. Mirrors `track-evidence-gate.sh`'s fingerprint logic exactly. |
| Compaction resilience — was the bundle re-read? | `track-compact.sh` (`PostCompact` + `PostToolUse`) | Records the two facts that make the post-compaction invariant auditable, both hook-observed and neither authored by the model: `compactions[]` (`{t, event, trigger}`) on every `PreCompact`/`PostCompact`, and `governance_reads[]` (`{t, tool, via}` — `via` is the matched path/command, truncated, so a real `cat` re-read is distinguishable from a command that merely names the path) whenever a tool call touches the **pinned** governance bundle — a `Read` of the path, or a `Bash`/`Grep` command naming it, since `cat runs/<id>.governance.md` is just as valid a re-read. With both on record, `track-audit.sh`'s `I4` reduces the checklist's highest-value manual item to arithmetic: between every compaction and the **next** subagent dispatch there must be a bundle re-read. No-op unless `RUN_ID` is set and a bundle has been pinned. This script proves the re-read happened; whether the next brief then *used* it is proved by `track-brief.sh` below, and `I4` fails on either half — a re-read followed by an empty brief is still a brief built from dropped context. |
| Did the brief actually carry the governance? | `track-brief.sh` (`PreToolUse`, dispatch tools) | Closes the pipeline's last unobserved hop. A `PreToolUse` hook on the dispatch tool receives the outgoing **brief text** (`tool_input.prompt`) before the subagent starts, so "did this brief embed the bundle's content, or just its filenames?" becomes countable: the script normalizes both sides (lowercase, punctuation collapsed — a re-wrapped or back-ticked line still matches) and records `briefs[]` = `{t, tool, bundle_sha, lines_total, lines_matched, min_lines, declared_na, thin, below_min, sections?}`. `track-audit.sh`'s `G6` reads it: **zero** constraint lines with a bundle pinned is a **FAIL** (the filename-passing mode the whole gate exists for); some-but-few is a WARN, because a fan-out brief legitimately embeds only its own cluster's sections and no hook can tell a correct slice from a lazy one; and a dispatch that genuinely needs none clears itself with an explicit `GOVERNANCE: n/a — <why>` line in the brief. `sections[]` records which bundle headings the brief *named* — recorded, never scored, since naming a section is precisely the failure mode. Tool-name matching is shape-based (`Task`, `*subagent*`, `*dispatch*`, …) plus a prompt-shaped payload, so it works on surfaces that cannot scope by matcher; when it recognises nothing while `trace[]` shows dispatches, `G6` WARNs that brief content is unverified rather than passing. **Recording only by default** — set `TRACK_BRIEF_DENY=1` to deny a zero-content dispatch outright, and `TRACK_BRIEF_MIN_LINES` (default 3) to tune the WARN threshold. **It proves content made the hop, never that it was the RIGHT content** — whether the sections sliced to a cluster were the ones binding its files stays the narrowed human check (`A5`). |
| Scope / never edit frozen entrypoints | `track-guard.sh` (`PreToolUse`) | **Deny** an edit whose target path is outside `TRACK_ALLOWED_PREFIXES` or hits a `TRACK_FROZEN_PATHS` entrypoint (deny-by-default, per worktree). |
| Never hand-edit generated or applied artifacts | `track-guard.sh` (`PreToolUse`) | **Deny** edits to any file carrying a `GENERATED — DO NOT EDIT` banner (re-run the generator), and to already-committed files under `TRACK_IMMUTABLE_PREFIXES` (e.g. applied migrations — add a NEW file instead). A brand-new file under the prefix is allowed. |
| No auto-merge from a worker | `track-guard.sh` (`PreToolUse`) | **Deny** `git push`, `gh pr merge`, `git reset --hard`, and `--force`/`--no-verify` **on a git/gh command** — scoped per shell segment, so `foo --force && git push --force` still trips, while a non-git tool that takes the same flag (`specify integration install --force`, `npm ci --force`) does not. Workers physically stop at `gh pr create --draft`. Opt-in `TRACK_ALLOW_FF_PUSH=1` permits a plain fast-forward `git push` (for a PR-rework flow) while still denying `--force`/merge/`--no-verify`/`reset --hard`. |
| No irreversible data/infra ops *(opt-in)* | `track-guard.sh` (`PreToolUse`) | When `TRACK_GUARD_DESTRUCTIVE` is set, **deny** `DROP`/`TRUNCATE`, unbounded `DELETE FROM` (no `WHERE`), Redis `FLUSHALL`/`FLUSHDB`, NATS stream/consumer teardown, and `rm -rf` on absolute/home paths. Stack-specific — tune the patterns. |
| Evidence gate (recorded test output) | `track-evidence.sh` (`PostToolUse`) | Append `{kind, cmd, response, fingerprint}` for test commands into the run record — captured by the tool, not claimed by the model. `fingerprint` (HEAD + tracked diff + untracked non-ignored content hashes) ties each entry to the exact code it tested. **`tool_response` is textual, not a numeric exit code** (CI stays the pass/fail authority). |
| Evidence pack complete + fresh *(opt-in)* | `track-evidence-gate.sh` (`Stop`) | The closing “missing rows = not done” assertion. The required-kind set is **diff-conditional**: `TRACK_EVIDENCE_RULES` (`glob:kind` pairs) selects kinds by the paths the branch touched — so a frontend-only diff needs `ts`, a migration diff needs `pg-explain` — unioned with the optional always-on floor `TRACK_REQUIRED_EVIDENCE`. **`decision:block`** unless every selected kind has an entry whose `fingerprint` matches the **current** tree and whose response shows no failure marker — reporting exactly which are MISSING / STALE / FAILING. Selection is mechanical glob-matching (no model call); no-ops when both vars are unset or the diff selects nothing. Honors `stop_hook_active`; failure markers extend via `TRACK_FAIL_PATTERN`. Mechanizes verification-before-completion; CI stays authoritative. |
| Tool-call counter + ceiling | `track-meter.sh` (`PostToolUse`) | Count tool calls into `tool_calls` and stamp the heartbeat on **every** call whenever `RUN_ID` is set (no ceiling required). When `TRACK_MAX_TOOL_CALLS` is *also* set, emit `continue:false` + set `status:no-progress` on trip. The count is **cumulative for the run**, so the trip is sticky — the halt message names both deliberate exits (raise the ceiling above the current count, or start a fresh run via `track-preflight.sh`) so a sticky halt can't read as an unrecoverable one. **Hook I/O carries no token/cost data**, so token/$ ceilings stay orchestrator-side. |
| Activation trace | `track-trace.sh` (`SubagentStart`/`SubagentStop`) | Append a `trace` entry per subagent spawn/stop, capturing the agent name and — on `SubagentStart` — its one-line `agent_description` (the **reason** it was spawned) as `reason`; `SubagentStop` records a `stop_reason` instead. Field names are read across surfaces (`agent_type`/`agentName`, `agent_description`/`agentDescription`). The `Run-Id:` *commit trailer* is NOT set here — add it in the worker's commit command or a git `prepare-commit-msg` hook. |
| Position / terminal state / governance pin | `track-note.sh` (manual, **not** a hook) | The model-asserted half of the record — everything a hook structurally cannot see. Five subcommands, all no-ops unless `RUN_ID` is set: `phase <mode> <step>` (**mandatory**, every core-step boundary — the compaction/crash anchor), `governance <file>` (**mandatory**, pins the persisted bundle + its sha, and appends to the `governance_stamps[]` history so a mid-core re-pin is on record), `status <success\|blocked\|no-progress\|budget-exceeded> [blocker] [next_step]` (terminal state — the only writer of `blocked`), `skill <name> [step]` and `loop [phase]` (optional trace). Everything it writes is provenance-tagged `self_reported:true`. |
| Discipline audit — did the run follow the pipeline? *(CLI always; blocking Stop gate opt-in)* | `track-audit.sh` (manual / `Stop --hook`) | Re-derives the pipeline's **discipline** invariants from durable artifacts only — the run record, the governance bundle, the diff — never from the model's account of itself. Checks: isolation — worked on the default branch is a FAIL, branch-in-place a WARN (`I1`), breadcrumb branch matches the working branch (`I2`), reconcile left its `last_reconcile` stamp (`I3`), every compaction was followed by a governance-bundle re-read before the next subagent dispatch **and** the first brief after it carried the bundle (`I4` — needs `track-compact.sh` + `track-brief.sh` wired, and WARNs plainly when they are not rather than passing an unobserved run); governance pinned + sha-stable against its latest pin (`G1`), bundle covers every `applyTo`-matched instruction file for the diff (`G2`), **every** subagent dispatch was preceded by a governance pin — read from the append-only `governance_stamps[]`, so a deliberate mid-core re-pin is legal (`G3`), trust-boundary surface pulls in `security-and-owasp` (`G4`), each matched file's bundle section carries ≥2 actionable constraints rather than a bare heading (`G5`), every dispatched brief carried the bundle's constraints as content or declared `GOVERNANCE: n/a` (`G6`), phase stamped + gate sequence advanced (`P1`/`P2`), ≥2 distinct subagent ids (`M1`), story mode recorded a genuine **RED before green** (`T1`), no `skip`/`only` added and no assertions removed from test files (`T2`), latest captures converged on one fingerprint (`E1`), no suspiciously short *passing* captures (`E2`), terminal state recorded (`F1`). Prints an explicit **NOT CHECKED HERE** list rather than implying a clean bill of health. CLI exits 2 on FAIL; `--hook` blocks the Stop with `{decision:"block"}` **only when `TRACK_AUDIT=1`** and honors `stop_hook_active`. |
| Pre-handoff secret/leftover scan *(opt-in)* | `track-sentinel.sh` (`Stop`) | When `TRACK_SENTINEL` is set, scan the **staged diff** and `decision:block` if it finds a likely secret or debug leftover (`console.log`, `debugger`, `TODO(claude)`, `FIXME`). Honors `stop_hook_active` so it can't loop; patterns override via `TRACK_SECRET_PATTERN`/`TRACK_LEFTOVER_PATTERN`. Defense-in-depth — CI/secret-scanning stays authoritative. |
| Token usage estimate + ceiling *(enforced by default)* | `track-tokens.sh` (`Stop`) | When `TRACK_MAX_TOKEN_ESTIMATE` is set to a positive integer (default: `200000` via `track-env.base.sh`), parse the `transcript_path` from the Stop payload, extract all text (user/assistant/tool-request fields), count chars, and write `token_estimate` (chars÷4) + `token_estimate_chars` + `token_estimate_method` into the run record. **Ceiling enforcement**: if the estimate exceeds `TRACK_MAX_TOKEN_ESTIMATE` and the run record does not already carry `status:"budget-exceeded"`, the hook writes that status, prints a message, and exits non-zero to block the stop — the agent must not open a PR. On the next stop attempt the status is already set so the hook exits 0, letting the run end cleanly. OVERWRITES on each Stop (transcript is cumulative; adding would double-count). The estimate **undercounts** — it cannot see the hidden system prompt, injected tool-schema definitions, or cached-token discounts. Disable by setting `TRACK_MAX_TOKEN_ESTIMATE=0`. |

## Install

**Recommended — the installer** ([`../scripts/install-hooks.sh`](../scripts/install-hooks.sh)).
Idempotent, consent-gated, drift-aware. It fixes the "install once, silently drift" footgun that
manual `cp` invites (a stale bundle runs the *old* hooks; a forgotten gitignore self-stales the
evidence fingerprint; a missing base preset runs the resume ungated):

```bash
install-hooks.sh --check   # exit 3 if installed bundle is missing/stale (drift probe)
install-hooks.sh           # DRY-RUN: print the plan, write nothing
install-hooks.sh --apply   # sync bundle + gitignore runs/ + seed stack-aware track-env.base.sh
                           #   + install the hook WIRING for the chosen surface(s)
```

By default the installer wires **both** surfaces (Copilot `track-hooks.json` + Claude Code
`.claude/settings.json`). Scope it with `--surface`: `--surface copilot`, `--surface claude`, or
`--surface both` (default). See [Running Under Claude Code](#running-under-claude-code) for the
Claude Code specifics.

It (1) syncs `scripts/track-*.sh` + `templates/track-hooks.json` into `.github/hooks/`, (2) ensures
`runs/` is gitignored, and (3) seeds `.github/hooks/track-env.base.sh` **only if absent**, pre-filled
from detected repo signals (`go.mod`→go-test, `pyproject.toml`→py, `package.json`→ts, `migrations/`,
default branch) — REPO-POLICY vars filled, TASK-DERIVED scope/floor left EMPTY so an unedited copy
fails loud. An existing base preset is never clobbered. `--apply` writes into shared repo config, so
the skill's first-run bootstrap runs the dry-run, gets consent, then applies.

### Manual install (equivalent)

Copy every [`../scripts/track-*.sh`](../scripts/) into the repo's `.github/hooks/` directory and
place [`../templates/track-hooks.json`](../templates/track-hooks.json) there too. Each script is
**opt-in and no-ops unless its env is set**, so dropping them in is safe before configuring anything.

### Bootstrap (recommended): commit one repo preset, override per-worktree as needed

Hand-exporting a dozen `TRACK_*` vars every run is the #1 footgun — a resume that forgets them runs
**silently ungated** (guard off, evidence gate trivially passes). Instead, bind the config to a file
the hooks auto-source. There are two layers, both living in `.github/hooks/` next to the scripts:

```bash
# 1. Repo-wide base — commit it once; it travels into every worktree automatically.
cp .github/hooks/track-env.sh.example .github/hooks/track-env.base.sh   # from templates/track-env.sh.example
$EDITOR .github/hooks/track-env.base.sh                                 # values common to the whole repo
git add .github/hooks/track-env.base.sh && git commit                   # committed, shared across all tracks

# 2. (Optional) per-worktree override — only when a branch must deviate from the base.
cp .github/hooks/track-env.sh.example .github/hooks/track-env.sh        # gitignored, local to this worktree
$EDITOR .github/hooks/track-env.sh                                      # just the vars that differ
```

Every `track-*.sh` **auto-sources both files sitting next to it** (right after `set -eufo pipefail`) —
`track-env.sh` first, then `track-env.base.sh`. Because `track-env.base.sh` is committed, a fresh
worktree (single-branch **or** a parallel track) already has it; nothing is copied at start. Every
line uses `export VAR="${VAR:-default}"`, so precedence is **exported env > worktree `track-env.sh` >
repo `track-env.base.sh` > script default**: a worktree override beats the repo base, and an
orchestrator (`sso-executing-parallel-tracks`) can still set per-track overrides on top of everything
without editing a file, keeping the composition contract intact. `RUN_ID` is deliberately **not** in
either *static* preset — it's minted per run by `track-preflight.sh`, recovered from the breadcrumb on
resume, and (at `--persist`) persisted as a managed block in the gitignored `.github/hooks/track-env.sh`
so the recorder hooks activate automatically; `--complete` retires that block.

### The vars (also settable manually)

The preset just wraps these — export them directly instead if you prefer, or to override the preset
for one run:

```bash
export TRACK_ALLOWED_PREFIXES="src/feature:test/feature"   # guard: this branch's writable scope
export RUN_ID="2026-06-27T14-03_feat"                       # <UTC-timestamp>_<track> — usually MINTED by track-preflight.sh at preflight, not hand-set; STABLE across restarts so reconcile resumes the same record
export TRACK_FROZEN_PATHS="cmd/main.go:internal/app/app.go" # guard: frozen entrypoints (see caveat)
export RUNS_DIR="runs"                                       # RUN_ID keys the record + runs/<id>.dispatch breadcrumb. GITIGNORE THIS DIR: it's local run state, and if tracked, evidence writes shift the fingerprint (gate sees its own capture as STALE) and reconcile reads the tree as dirty (see Gotchas).
# OPTIONAL — each stays off until set
export TRACK_ID="setup"                                     # preflight: track slug for breadcrumb resume-matching
export TRACK_BRANCH="feat/setup-foundation"                # preflight: target branch name to work to (empty = derive from the track slug); validated with git check-ref-format
export PREFLIGHT_REQUIRE_GH=1                               # preflight: require authenticated gh (0 to waive for early setup runs)
export PREFLIGHT_REQUIRE_TOOLCHAIN="go,uv"                  # preflight: extra bins that must be on PATH
export TRACK_IMMUTABLE_PREFIXES="migrations/"               # guard: committed files here are append-only
export TRACK_GUARD_DESTRUCTIVE=1                            # guard: deny DROP/TRUNCATE/FLUSHALL/etc.
export TRACK_SENTINEL=1                                     # Stop: scan staged diff for secrets/leftovers
export TRACK_TEST_CMD_PATTERN="go test|uv run pytest|npm (run )?test"  # evidence: SIMPLE mode — tag every matching test call as a single "test" kind. Use this OR TRACK_EVIDENCE_KINDS, not both: KINDS supersedes it with per-pack labels.
export TRACK_EVIDENCE_KINDS="go-test:go test -race;py:uv run pytest;ts:tsc --noEmit"  # evidence: MULTI-KIND mode — tag by pack row (label:pattern). Labels here MUST match the kinds used in TRACK_EVIDENCE_RULES / TRACK_REQUIRED_EVIDENCE (preflight warns on any mismatch).
export TRACK_EVIDENCE_RULES="*.go:go-test;*.py:py;*.tsx:ts;*.ts:ts;migrations/*:pg-explain"  # Stop gate: diff path → required kind
export TRACK_REQUIRED_EVIDENCE=""             # Stop gate: kinds required on EVERY diff (floor); empty = rules-only
export TRACK_EVIDENCE_SKIP_GLOBS="*.md;docs/*;specs/*"   # Stop gate: NON-CODE paths. The gate no-ops — floor INCLUDED — only when EVERY path the diff touches matches one of these. Exists because a prose-only diff cannot change a go/py/ts result, so the floor demands of it something no honest action can produce. ALL-or-nothing: one code file anywhere restores the full requirement set. Off (empty) by default; don't blanket-skip a docs/ tree that holds runnable examples.
export TRACK_BASE_REF="main"                  # Stop gate / reconcile: diff base. STRONGLY RECOMMENDED — without it, once work is COMMITTED the diff-vs-HEAD is empty so the gate requires nothing and silently passes (see Gotchas). Falls back to branch upstream, then HEAD-only.
export TRACK_DEFAULT_BRANCH=""                # audit I1 only: the branch work must NEVER land on. Empty = derived from origin/HEAD, then init.defaultBranch, then "main". Set it when neither exists (bare clone, no remote). NOT derived from TRACK_BASE_REF's fallback: an unset base falls back to the branch's OWN upstream, which would make I1 fail every correctly-isolated run.
export TRACK_MAX_TOOL_CALLS=200                                       # tool-call ceiling (hard stop). NOTE: counting/heartbeat are always-on when RUN_ID is set — this var only ADDS the halt.
export TRACK_MAX_TOKEN_ESTIMATE=200000        # Stop: chars÷4 transcript ceiling; blocks the stop + writes status:"budget-exceeded" on trip. 0 disables. UNDERCOUNTS (blind to system prompt + cached tokens).
export TRACK_AUDIT=1                          # make track-audit.sh a BLOCKING Stop gate. Unset = the CLI still works, it just never blocks a stop. Deliberately opt-in: a repo that adopts the hooks but not the governance discipline would otherwise be unable to end a session.
export TRACK_TRUST_BOUNDARY_PATTERN="auth|secret|token|..."   # audit G4: which diff paths demand security-and-owasp in the bundle. Defaults cover auth/secrets/network/persistence/deploy.
export TRACK_SELF_HEAL_ATTEMPTS=2             # retries per DISTINCT failure before halting `blocked`. PROMPT-enforced (no hook can count review rounds) — it lives here so the number survives a context compaction instead of only in the model's head. Distinct from the orchestrator's no-progress detector, which counts STALLED PASSES; this counts FIX ATTEMPTS.
export TRACK_NOTIFY_WEBHOOK="https://hooks.slack.com/services/..."     # notify
export TRACK_ALLOW_FF_PUSH=1                   # guard: permit a plain (fast-forward) git push — for a PR-rework flow updating an existing PR branch. --force/merge/--no-verify/reset --hard STAY denied. Leave unset for the default push lockout (worker stops at the draft PR).
```

### Triage: a hook is blocking and you don't know why

The three gates read **different** inputs, so they fail independently — and the fix for one is a
no-op for the others. Clearing `RUN_ID` does **not** widen the guard's writable scope; that is the
single most common wrong turn here, because all three can trip at once and *look* like one policy.

| Symptom | Which gate | Keyed to | Fix |
|---|---|---|---|
| Every write denied, incl. paths you own | `track-guard.sh` | `TRACK_ALLOWED_PREFIXES` — **not** `RUN_ID` | Set the scope for *this* task. Empty ⇒ fail-closed (denies all edits) by design. |
| Every tool call halted, "ceiling exceeded" | `track-meter.sh` | `RUN_ID` + the record's cumulative `tool_calls` | Raise `TRACK_MAX_TOOL_CALLS` above the current count, or start a fresh run. |
| Stop blocked demanding kinds your diff can't produce | `track-evidence-gate.sh` | `RUN_ID` + `TRACK_REQUIRED_EVIDENCE` / `_RULES` | Re-derive the floor for this task; for a prose-only diff see `TRACK_EVIDENCE_SKIP_GLOBS`. |

Scope prefixes are resolved against the **git worktree root**, never the hook's CWD — a `cd` into a
subdirectory earlier in the session does not reinterpret them. A path outside every worktree (a
scratch dir under `/tmp`, say) has no root to be relative to and stays **absolute**, so it is denied
by a scope of repo-relative prefixes: allow it explicitly if you want it, e.g.
`TRACK_ALLOWED_PREFIXES="specs/001-x/:/tmp/agent-scratch/"`.

**When the demands describe someone else's task** — another branch, another worktree, a task range
you never ran — you are looking at leftover run state, not policy. Check what the hooks actually
resolved before changing anything:

```bash
bash -c '. .github/hooks/track-env.sh 2>/dev/null; . .github/hooks/track-env.base.sh 2>/dev/null
         printf "RUN_ID=%s\nSCOPE=%s\nFLOOR=%s\n" "${RUN_ID:-<none>}" \
           "${TRACK_ALLOWED_PREFIXES:-<none>}" "${TRACK_REQUIRED_EVIDENCE:-<none>}"'
jq '{run_id, branch, tasks, completed_utc}' runs/*.dispatch   # whose run is this?
jq '{tool_calls, status, last_ts}'          runs/<RUN_ID>.json
```

A `RUN_ID` resolving to a run on a different branch, or one whose record already carries a terminal
`status`, is stale: `track-preflight.sh --complete` retires it, and the managed block declines to
re-adopt it on its own. **The scope and floor lines are separate** — they are `[TASK-DERIVED]` values
an operator wrote into `track-env.sh` / `track-env.base.sh`, so a finished task's values sit there
until re-derived. Export the correct ones for the new task rather than deleting the run state and
expecting the guard to open.

**Hooks are defense-in-depth, not the final gate.** They are local and bypassable. Layer them:
hooks (fast, in-session) → git `pre-push` (local backstop) → **CI (the unbypassable merge gate)**.

For foundation/bootstrap runs, avoid freezing paths too early. If entrypoints do not exist yet,
leave `TRACK_FROZEN_PATHS` unset for the bootstrap branch, then enable strict frozen entrypoints for
subsequent parallel tracks.

## What the Run Record Captures (and What It Deliberately Doesn't)

The run record `runs/<RUN_ID>.json` is written **per hook event, not per loop iteration**, and only
holds what hooks can actually observe. It is **opt-in**: every field below stays empty unless the
hook *and* its env are set — launch without them and the run still works but records nothing. The
one convenience: `track-preflight.sh --persist` persists `RUN_ID` into the installed `track-env.sh`, so
the **mechanical** fields (`tool_calls`, `trace[]`, heartbeat) record automatically even in a solo run;
the **self-reported** fields (`phase`, `governance_bundle`, `status`, `skills[]`, `iterations`) still
require the model to call `track-note.sh` — and the first two are **mandatory**, not decoration: they
are what a compacted or crashed session re-anchors on.

> **The guard resolves scope by worktree root, but reads env where the agent runs.**
> `track-guard.sh` checks each write path against the git worktree it belongs to
> (`git rev-parse --show-toplevel`), not `$PWD` — so writes into a **sibling** worktree are
> scope-checked normally. But it **sources `track-env.sh` from the checkout the agent process runs
> in**, so per-run overrides (`TRACK_ALLOWED_PREFIXES`, `TRACK_ALLOW_FF_PUSH=1`) must live in *that*
> checkout, not the target worktree's, or the guard never sees them. Simplest robust option: re-root
> the workspace **into** the worktree so `$PWD`, file tools and env all agree.

| Recorded | Field | Written on | Source |
|---|---|---|---|
| Schema version | `v` (integer, currently `1`) | first hook to touch the record | any writer — all seed the **same** canonical skeleton `{run_id, v, trace, evidence, tool_calls}` |
| Heartbeat | `started_ts` (first event) / `last_ts` (latest event) | **every** hook write (`track-meter.sh` / `track-trace.sh` / `track-evidence.sh`) | orchestrator derives **idle/staleness** = `now − last_ts` (a hung/crashed worker stops advancing it — the count-based caps can't see that) and **run wall-clock** = `last_ts − started_ts`. Resolution = frequency of whichever hooks are enabled: `track-trace.sh` (RUN_ID-only) stamps on subagent boundaries; `track-meter.sh` (also RUN_ID-only now) stamps on **every** tool call for finer granularity. |
| Tool-call count | `tool_calls` (running integer) | **every** `PostToolUse` | `track-meter.sh` — `+1` per call whenever `RUN_ID` is set; halts only if `TRACK_MAX_TOOL_CALLS` is also set |
| Subagent spawn/stop timeline | `trace[]` (`{t, kind, event, agent_id, agent_type, reason?, stop_reason?}`) | `SubagentStart` / `SubagentStop` | `track-trace.sh` — `reason` (the agent's `agent_description`) is present on **start** only; `stop_reason` on **stop** only. |
| **Self-reported** pipeline position | `phase` (`{mode, step, t, self_reported:true}`, overwritten) + `phase_log[]` (append-only) | skill calls `track-note.sh phase <mode> <step>` at **every** core-step boundary — **mandatory** | `track-note.sh` — the durable answer to "where am I?". No hook can see it, and evidence freshness cannot substitute (that says which test kinds are current, never which core you chose or whether the tests are frozen). `track-reconcile.sh` replays it as `position.phase` + a `resume_action`. **This is the compaction anchor** — see [Surviving a compaction](#surviving-a-compaction). |
| **Self-reported** governance bundle | `governance_bundle` (`{path, sha, t, self_reported:true}`, overwritten) + `governance_stamps[]` (append-only) | skill calls `track-note.sh governance <file>` once the bundle is persisted — **mandatory**, and again after any mid-core re-distil | `track-note.sh` — pins `runs/<RUN_ID>.governance.md` so a compacted session re-reads the binding constraints from disk. The `sha` reveals a bundle changed after briefs were built; reconcile reports `governance_bundle_present:false` if the file has since vanished. The **history** is what makes a legitimate re-pin distinguishable from late discovery: `G3` requires a pin at or before *each* dispatch instead of comparing one overwritten timestamp against the first. |
| Brief governance coverage | `briefs[]` (`{t, tool, bundle_sha, lines_total, lines_matched, min_lines, declared_na, thin, below_min, sections?}`) | `PreToolUse` on a dispatch tool | `track-brief.sh` — how much of the pinned bundle the outgoing brief actually contained, counted from the brief text the dispatch tool received. Feeds `G6` and the second half of `I4`. |
| **Self-reported** terminal state | `status` + `status_self_reported:true` (+ `blocker`, `next_step`) | skill calls `track-note.sh status <state> [blocker] [next_step]` | `track-note.sh` — constrained to `success\|blocked\|no-progress\|budget-exceeded`, the same set `sso-executing-parallel-tracks` routes on. This is the path for states no hook can observe (chiefly `blocked`, which nothing else ever writes). |
| **Self-reported** skill order | `skills[]` (`{t, skill, step, self_reported:true}`) | skill calls `track-note.sh skill …` at each core step (optional) | `track-note.sh` — the model's **own claim**, not hook-observed (no hook can see a skill name). Provenance-tagged so it can't be mistaken for verified truth. |
| **Self-reported** loop count | `iterations` (integer) + `iterations_self_reported:true` (+ optional `iteration_log[]`) | skill calls `track-note.sh loop …` once per RED→GREEN→review cycle | `track-note.sh` — asserted by the model; hooks never see a reasoning loop. `tool_calls` remains the only mechanical turns-proxy. |
| Test evidence | `evidence[]` (`{t, kind, cmd, response, fingerprint}`) | `PostToolUse` matching a **test** command only | `track-evidence.sh` |
| Terminal state | `status` (`no-progress` only) | when the tool-call ceiling trips | `track-meter.sh` — the **only** hook that writes `status` |
| Token estimate + ceiling *(enforced)* | `token_estimate` (integer) + `token_estimate_chars` + `token_estimate_method` | once per `Stop`, **overwritten** each time | `track-tokens.sh` (ceiling set via `TRACK_MAX_TOKEN_ESTIMATE=200000`) — chars÷4 heuristic off the transcript; blocks stop on first exceedance (writes `status:"budget-exceeded"`); undercounts system prompt + cached tokens; labelled as estimate so it can't be mistaken for billing data |

**Deliberately NOT recorded** (don't expect these in the file):

- **No loop / review-iteration count.** The TDD + 2-stage-review loop and the `self_heal_attempts`
  cap live inside SDD's in-context reasoning; hooks never see review rounds. `tool_calls` is the only
  (approximate) "turns" proxy. *(A skill may **self-report** a loop count via `track-note.sh loop` —
  stored as `iterations` + `iterations_self_reported:true` — but that is the model's claim, not a
  hook-observed fact.)*
- **No token or cost data.** Hook I/O carries none, so only a **tool-call** ceiling is enforceable
  here; token/$ ceilings stay orchestrator-side.
- **No per-tool `duration_ms`.** A `PostToolUse` hook fires only *after* a call and gets no start
  time, so a single call's duration isn't measurable here. Use `last_ts − started_ts` for run
  wall-clock and the gaps between consecutive `trace[]` timestamps to approximate per-step duration.
- **No per-tool argument log.** `tool_calls` is a bare counter; non-test tool calls (reads, `ls`,
  edits) tick it but are not itemized. Only **test** commands land in `evidence[]`.
- **`response` is textual, not an exit code.** `PostToolUse` exposes a (possibly truncated) text
  result, so CI — not the recorded string — remains the authoritative pass/fail.
- **No hook-observed `blocked`/`passed` status.** `track-evidence-gate.sh` enforces the Stop gate by
  **returning a block decision + message**, not by stamping a field — so a gate-blocked stop leaves no
  `status`, and a passing gate is **silent** (no positive marker). Of the hooks, only
  `track-meter.sh` (`no-progress`) and `track-tokens.sh` (`budget-exceeded`) write `status`. The
  `blocked` state is **model-asserted** via `track-note.sh status` — nothing observes it mechanically,
  which is exactly why the skill must write it rather than quietly opening a PR.

## Surviving a compaction

Everything above is written **per hook event**, and hooks fire on tool calls, subagent boundaries and
stops. **A context compaction is none of those.** It happens inside a live session, so no
`SessionStart` fires, `track-reconcile.sh` does not re-run, and nothing re-injects what the compaction
dropped — first to go being bulk pasted file content, i.e. the governance excerpts every subagent
brief depends on. The model's *belief* that it complied survives; the content does not.

The bundle's answer is to keep the three things a compaction can destroy in files instead:

| At risk | Kept in | Restored by |
|---|---|---|
| Where in the pipeline you are | `phase` / `phase_log[]` (`track-note.sh phase`) | `track-reconcile.sh` → `position.phase` + `resume_action` |
| The binding governance constraints | `runs/<RUN_ID>.governance.md` (pinned by `track-note.sh governance`) | re-read the file before the next dispatch |
| Retry budget, ceilings, scope | `track-env.base.sh` (`TRACK_SELF_HEAL_ATTEMPTS`, …) + the `.dispatch` breadcrumb | auto-sourced by every hook |

So after any compaction: re-run `track-reconcile.sh`, act on `resume_action`, re-read the governance
bundle. Never rebuild position by reading the worktree — that is the failure the reconcile step exists
to prevent, and it applies identically after a compaction and after a crash.

## Rendering a Completion / PR Report

`track-report.sh` (at the draft-PR boundary, run by the skill — not a hook) renders the **deterministic half** of a
PR/stage report straight from state that already exists, so the factual part cannot drift from reality:

```bash
bash .github/hooks/track-report.sh            # uses $RUN_ID, or recovers it from the newest runs/*.dispatch
bash .github/hooks/track-report.sh --json     # same facts as a JSON object, for tooling
```

It emits an **Auto block** (files changed + `--shortstat` from the `TRACK_BASE_REF` diff; `evidence[]`
as a fingerprint + pass/fail table; `tool_calls`; the `trace[]` subagent order; and — under a clearly
separate *self-reported* heading — `skills[]` / `iterations`). It also emits a **Compliance warnings**
section: if the record shows an *empty evidence pack* or *no `requesting-code-review` activation*, it
prints a ⚠️ for each (also surfaced as a `warnings[]` array in `--json`) so a skipped review gate or
an un-captured verification is visible in the PR body itself rather than in a later audit — the one
mechanical backstop for the two gaps a hook cannot otherwise observe. It is **read-only**: it never
mutates the record, the tree, or git. The **narrative half** (constitution/OWASP compliance, caveats,
"after merge") is a model *assertion* and is authored by hand into [`templates/pr-body.md`](../templates/pr-body.md),
whose `{{AUTO_BLOCK}}` placeholder is where the script's output goes. Keeping machine-rendered facts
and model claims in two visibly separate zones is the same discipline the record applies with
`self_reported:true`.

