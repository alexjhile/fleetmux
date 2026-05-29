# Install

One-time setup for the workstation. Run these once; afterwards the workflow is invokable on any project via the [adoption checklist](adoption-checklist.md).

## 1. Install matt pocock's skills

```bash
npx skills@latest add mattpocock/skills
```

Pick the skills you want — at minimum select:

- `setup-matt-pocock-skills` *(non-negotiable; bootstraps every other skill per-repo)*
- `grill-me` and/or `grill-with-docs`
- `to-prd`
- `to-issues`
- `tdd`
- `triage`
- `diagnose` (recommended)
- `improve-codebase-architecture` (recommended)

The skills install to `~/.claude/skills/` (or your agent's equivalent skill directory).

**Verify:**

```bash
ls ~/.claude/skills/grill-me ~/.claude/skills/to-prd ~/.claude/skills/to-issues ~/.claude/skills/tdd
```

All four should exist with a `SKILL.md` inside.

## 2. Install Sandcastle prerequisites

Sandcastle needs a sandbox provider. Pick one:

- **Docker Desktop** — most common for local dev: <https://www.docker.com/>
- **Podman** — rootless alternative: <https://podman.io/>
- **Vercel** — cloud Firecracker microVMs: <https://vercel.com/>

You also need:

- **Node 20+** (Sandcastle is a Node CLI)
- **git** (Sandcastle creates worktrees)

Sandcastle itself installs per-project, not globally — see [adoption checklist](adoption-checklist.md) step 4.

## 3. Install the issue tracker CLI

For the canonical default (GitLab):

```bash
brew install glab
glab auth login
```

For GitHub-tracked projects, use `gh`:

```bash
brew install gh
gh auth login
```

You only need the one(s) that match your projects' `git remote -v`.

## 4. Done

Move on to [adoption-checklist.md](adoption-checklist.md) for any specific project you want to make AFK-ready.
