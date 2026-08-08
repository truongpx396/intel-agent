# Vendored: obra/superpowers

The 14 skill directories listed below are vendored verbatim from an upstream project.
They are **not** authored by this repo — do not edit them in place; see *Updating* below.

| | |
|---|---|
| Upstream | https://github.com/obra/superpowers |
| Version | `6.2.0` |
| Commit | `44c9b2d6e889982ac18c27d05a19fefe335194e1` (2026-07-28) |
| License | MIT — Copyright (c) 2025 Jesse Vincent — full text in [LICENSE-superpowers.txt](./LICENSE-superpowers.txt) |

## Vendored skills

`brainstorming` · `dispatching-parallel-agents` · `executing-plans` ·
`finishing-a-development-branch` · `receiving-code-review` · `requesting-code-review` ·
`subagent-driven-development` · `systematic-debugging` · `test-driven-development` ·
`using-git-worktrees` · `using-superpowers` · `verification-before-completion` ·
`writing-plans` · `writing-skills`

## Why these are here

`sso-single-branch-development` and `sso-executing-parallel-tracks` (both in this same
`.claude/skills/` directory) delegate their execution steps to these skills by name —
`using-git-worktrees` for isolation, `dispatching-parallel-agents` and
`subagent-driven-development` for the implement loop, `requesting-code-review` for the
review gate, and `verification-before-completion` for the evidence gate. Without them
installed, those pipelines reference skills that do not resolve.

The full set is vendored rather than only the five named above, because the skills
cross-reference each other with sibling-relative paths (e.g.
`../using-superpowers/references/codex-tools.md`); a partial copy leaves dangling links.

## Why `.claude/skills/`

Discovery support, verified empirically rather than assumed:

- **Claude Code** discovers **only** `.claude/skills/` (project) and `~/.claude/skills/`
  (personal). A valid `SKILL.md` placed under `.github/skills/` never registers —
  invoking it returns `Unknown skill`.
- **GitHub Copilot** discovers **both**, per
  [agent-skills.instructions.md](../../.github/instructions/agent-skills.instructions.md):
  `.claude/skills/` is its documented backward-compatible location.

All repo skills (this vendored set plus the project-authored ones) now live under
`.claude/skills/` for that reason — a single copy is readable by both harnesses, while a
copy under `.github/skills/` would be invisible to Claude Code, the harness that actually
runs these pipelines.

## Updating

Do not hand-edit these directories — local edits are silently lost on the next sync.
To move to a newer upstream release, replace the directories wholesale and update the
version/commit in the table above:

```bash
git clone --depth 1 https://github.com/obra/superpowers.git /tmp/superpowers
rm -rf .claude/skills/{brainstorming,dispatching-parallel-agents,executing-plans,\
finishing-a-development-branch,receiving-code-review,requesting-code-review,\
subagent-driven-development,systematic-debugging,test-driven-development,\
using-git-worktrees,using-superpowers,verification-before-completion,\
writing-plans,writing-skills}
cp -R /tmp/superpowers/skills/* .claude/skills/
cp /tmp/superpowers/LICENSE .claude/skills/LICENSE-superpowers.txt
```

### Alternative: the upstream plugin

Upstream's supported install path for Claude Code is the plugin marketplace:

```
/plugin install superpowers@claude-plugins-official
```

That auto-updates and needs no vendoring, but it is **per-developer** — it does not
travel with the repo, so a fresh clone or a CI/Copilot coding-agent run would not have
the skills. Vendoring is the trade: reproducible for everyone who clones, at the cost of
manual updates. If the team standardises on the plugin, delete these directories and this
file.
