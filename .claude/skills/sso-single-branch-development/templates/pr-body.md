<!--
  pr-body.md — completion / PR-body template for sso-single-branch-development.

  TWO ZONES, kept deliberately separate:

  1. AUTO  — machine-rendered facts. Do NOT hand-write this. Generate it with:
                 bash .github/hooks/track-report.sh            # uses $RUN_ID / newest breadcrumb
             and paste its output where {{AUTO_BLOCK}} sits below (or pipe it in).
             It renders: files changed (grouped by area, with a collapsible full list when the
             diff is large), evidence (fingerprint + pass/fail), a compliance-warnings check,
             the DISCIPLINE AUDIT (track-audit.sh verdicts — each finding with the remediation
             that clears it, plus a collapsed list of what it deliberately did NOT check),
             tool_calls, subagent trace, and (fenced off) any self-reported skills/loops.

             The audit section is why a reviewer does not have to take "I followed the
             pipeline" on trust: governance ordering, phase advance, real RED-before-green,
             convergence and test-weakening are re-derived from artifacts and shown inline.
             A ❌ row means this PR should not have been opened — resolve it or say plainly
             in the Asserted zone why it is waived.

  2. ASSERTED — the narrative you (the model) are CLAIMING. This is the only part you
             author by hand. Keep it clearly below the auto block so a reviewer can tell
             a verified fact from a model claim. Delete any section that doesn't apply —
             this template is a menu, not a mandate.
             Write plain GitHub Markdown: use real backticks (`like this`), NEVER escaped
             backticks (\` … \`) — escaping leaks literal backslashes into the rendered PR.

  The FOOTER at the very end (after "After merge") is the one fixed exception to "delete what
  doesn't apply" — keep it verbatim, as the last thing in the body, on every PR.

  Everything between {{ }} is a fill-in. Remove these HTML comments before publishing.
-->

## {{TITLE — e.g. "Stage 1: Setup — Three-Runtime Skeleton"}}

{{ONE-SENTENCE summary of what this PR does.}}

---

{{AUTO_BLOCK}}
<!-- ^ paste `track-report.sh` output here. Everything above the "ASSERTED" line is machine-derived. -->

---

### Asserted — narrative & compliance (model claim, verify before trusting)

#### What this adds
<!-- Prefer a TASK → files → intent table over prose — it maps the diff back to the plan and reads
     far better than a flat file-by-file list (the auto block already has the per-file/area breakdown).
     One row per task (or per merged task cluster). The "Files" column re-slices the diff BY TASK —
     git cannot attribute a file to a task, so this column is a MODEL CLAIM (that is why it lives in
     the Asserted zone, not the auto block). Mark each path's change type with a leading glyph:
       ＋ created   ~ modified   － deleted   → renamed (old→new)
     A file owned by two tasks (e.g. `pyproject.toml` = deps + lint) appears in the merged row, once.
     In scaffold mode every file is ＋created, so the glyphs matter most in story/refactor mode. -->
| Task | Files (＋new ~mod －del) | What it adds |
|------|-------------------------|--------------|
| {{T001}} | {{＋ backend-go/ ＋ backend-python/ ＋ frontend/ ＋ deploy/ (dirs)}} | {{three-runtime directory structure}} |
| {{T002}} | {{＋ `backend-go/go.mod`}} | {{Go 1.23 — Gin/GORM/NATS/Redis/OTel}} |
| {{T003+T009}} | {{＋ `backend-python/pyproject.toml`}} | {{deps + ruff/black config (one file, two tasks)}} |

#### Compliance
<!-- A TABLE of assertions, each citing the enforcing mechanism (a lint rule, a test, a config)
     so it is checkable, not just claimed. These are CLAIMS, not hook-verified facts. Delete rows N/A. -->
| ✓ | Principle / rule | How it's enforced |
|---|------------------|-------------------|
| ✅ | {{Principle I/II — kernel isolation}} | {{depguard bans kernel→internal (see `.golangci.yml`)}} |
| ✅ | {{OWASP A02/A03}} | {{credentials in env vars; images pinned}} |

#### Verification
<!-- Evidence has ONE canonical home: the AUTO block's "#### Evidence" table (Kind | Command |
     Result | Fingerprint), rendered by track-report.sh from the hook-captured evidence pack — that
     is the fingerprinted, machine-verified record. Do NOT duplicate it here.
     Author this section ONLY when the auto block shows "No evidence rows recorded" (evidence hooks
     off / empty pack). Then paste the real command output as a MANUAL table mirroring the auto shape,
     so a reviewer reads one consistent format. It is a model claim (unfingerprinted) — that is why it
     lives in the Asserted zone; call that out. Delete this whole section if the auto table is populated. -->
| Check | Command | Result |
|-------|---------|--------|
| {{compose parses}} | {{`docker compose config --quiet`}} | {{✅ OK}} |
| {{python deps}} | {{`uv sync` / tomllib parse}} | {{✅ 22 deps}} |
| {{go module}} | {{`go build ./...`}} | {{⚠️ not run — no packages yet}} |

#### Follow-ups / caveats
<!-- Anything a merger or the next stage must know: manual steps, deferred work, known gaps. -->
- {{e.g. "`go mod tidy` required in backend-go/ before first build (no go.sum in scaffold)"}}

#### After merge
{{What the next stage/PR should pick up. Delete if this is terminal.}}

---

 *Powered by 🌱 [Supspec Orchestration](https://github.com/truongpx396/supspec-orchestration)* 🤖
