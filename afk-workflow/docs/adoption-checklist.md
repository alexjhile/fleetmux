# Adoption checklist

How to "stamp" a project so it's AFK-ready. Assumes you've completed [install.md](install.md) once for the workstation.

This checklist takes 15–30 minutes the first time, ~10 minutes for subsequent projects.

## Where matt's skills need to be installed

Matt's skills are loaded by Claude Code at session startup, so they must be installed **everywhere a Claude Code session can run**:

| Location | Install command | When |
| --- | --- | --- |
| **Local workstation (M1, dev laptop, etc.)** | `npx skills@latest add mattpocock/skills -y -g` | Once per machine, in [install.md](install.md) step 1 |
| **Each VPS hosting a Claude Code session** | Same, run remotely via `aios ssh <vps> "..."` or your provisioning script | Per VPS, ideally baked into provisioning |
| **Sandcastle Docker containers** | `RUN npx -y skills@latest add mattpocock/skills -y -g` in the project's `.sandcastle/Dockerfile` | Once per image build (already in template) |

If you skip any of these, that environment will have Claude Code but no skills — the agent there can read inlined skill prompts in `prompt.md` but can't invoke `/tdd`, `/grill-me`, etc. natively. You'll get degraded behaviour, silently.

## Pre-check

- [ ] Project has a git remote (`git remote -v` returns a real URL — GitHub or GitLab)
- [ ] You can push to that remote (your auth works: `glab auth status` or `gh auth status`)
- [ ] Project has at least one of: `package.json`, `go.mod`, `Cargo.toml`, `pyproject.toml`, or a clear language convention an agent will recognise
- [ ] You have an `ANTHROPIC_API_KEY` available somewhere on disk you trust (e.g. a shared-secrets repo, 1Password CLI, env)

## Step 1 — Run `setup-matt-pocock-skills` against the project

In Claude Code (or any agent that has matt's skills installed):

```
/setup-matt-pocock-skills
```

Answer the three prompts:

1. **Issue tracker** — pick the one matching your `git remote -v` (GitHub or GitLab). Other trackers are supported as freeform prose.
2. **Triage labels** — accept the five canonical defaults unless your tracker already uses different label names.
3. **Domain docs** — single-context unless you're in a monorepo with `CONTEXT-MAP.md`.

The skill writes:

- `docs/agents/issue-tracker.md`
- `docs/agents/triage-labels.md`
- `docs/agents/domain.md`
- An `## Agent skills` block in the project's `CLAUDE.md` (or `AGENTS.md`)

Commit and push.

## Step 1.5 — Verify adjunct skills are available

The five pipeline skills (`grill-me`, `to-prd`, `to-issues`, `tdd`, `triage`) are what `setup-matt-pocock-skills` wires up. The adjuncts (`improve-codebase-architecture`, `grill-with-docs`, `diagnose`, `prototype`, `zoom-out`, `caveman`) are part of the same upstream skill set but fire on signal, not on schedule.

Sanity-check that all of them are available in the Claude Code session you're using for this bootstrap:

```bash
ls ~/.claude/skills/ | grep -E "grill-me|to-prd|to-issues|tdd|triage|improve-codebase-architecture|grill-with-docs|diagnose|prototype|zoom-out|caveman"
```

If any are missing, re-run `npx skills@latest add mattpocock/skills -y -g` (per [install.md](install.md)). Don't proceed without all eleven — the adjuncts are how you handle the off-spine cases (bug diagnosis, architecture passes, design prototypes) that arise mid-pipeline.

See [docs/agents/skill-map.md](agents/skill-map.md) for the full taxonomy and when-to-fire heuristics.

## Step 2 — Create the canonical triage labels

If your tracker doesn't already have them, create the five canonical labels:

```bash
# GitLab
glab label create --name "needs-triage"    --color "#FBCA04" --description "Maintainer needs to evaluate this issue"
glab label create --name "needs-info"      --color "#D4C5F9" --description "Waiting on reporter for more information"
glab label create --name "ready-for-agent" --color "#0E8A16" --description "Fully specified, ready for an AFK agent"
glab label create --name "ready-for-human" --color "#1D76DB" --description "Requires human implementation"
glab label create --name "wontfix"         --color "#CCCCCC" --description "Will not be actioned"

# GitHub equivalent: replace `glab label create --name X --color Y --description Z`
# with `gh label create X --color Y --description "Z"`
```

## Step 3 — Add a `CONTEXT.md` (if missing)

If the project doesn't already have a `CONTEXT.md`:

- Run `grill-with-docs` to draft one — it'll interrogate you about domain terms and produce the file.
- Or seed it manually with 5–10 terms unique to the project. Don't invent vocabulary; lift it from existing READMEs / code / docs.

## Step 4 — Initialise Sandcastle in the project

```bash
npx sandcastle init
```

Pick:

- **Provider**: Docker (default) unless you have a reason to pick Podman / Vercel.
- **Backlog manager**: matches your tracker (GitHub Issues or local; GitLab support varies).
- **Template**: start with `blank` or `simple-loop`.

This scaffolds `.sandcastle/{Dockerfile, prompt.md, .env.example, .gitignore}` and builds an image.

**Customise the Dockerfile.** Add anything the project needs that isn't in the default base (language runtimes, build tools, project-specific CLIs). Reference: [`docs/sandcastle-template/Dockerfile`](sandcastle-template/Dockerfile) here for a generic starting point.

Commit `.sandcastle/Dockerfile` and `.sandcastle/prompt.md`. Do **not** commit `.sandcastle/.env`.

## Step 5 — Wire the API key

Populate `.sandcastle/.env` from your secrets store. Two acceptable patterns:

- **Symlink / copy at setup time** from `~/path/to/shared-secrets/ai.env` to `.sandcastle/.env` (uncommitted; gitignored).
- **Inject at runtime** via the `env: { ANTHROPIC_API_KEY: process.env.ANTHROPIC_API_KEY }` provider option in `.sandcastle/main.ts`.

Either way: no key in git, no key in Docker image layers.

## Step 6 — Tracer-bullet AFK run

Before running real work, prove the loop with a no-op:

```typescript
// .sandcastle/main.ts (or main.mts)
import { run, claudeCode } from "@ai-hero/sandcastle";
import { docker } from "@ai-hero/sandcastle/sandboxes/docker";

await run({
  agent: claudeCode("claude-opus-4-7"),
  sandbox: docker(),
  prompt: "Add a single line `Tracer bullet succeeded` to docs/sandcastle-tracer.md, then commit.",
  branchStrategy: { type: "branch", branch: "agent/sandcastle-tracer" },
});
```

```bash
npx tsx .sandcastle/main.ts
```

Verify:

- A commit landed on `agent/sandcastle-tracer`
- The branch pushed (or can push) to origin
- `result.commits.length >= 1`

If anything fails, fix it before moving on. The tracer is the cheapest place to catch setup issues.

## Step 7 — Project is AFK-ready

You can now drive real work via the pipeline:

> *"Use afk-workflow to add `<feature>` to `<project>`"*

Claude Code reads the project's `CLAUDE.md` + `CONTEXT.md`, runs `grill-me` → `to-prd` → `to-issues`, then Sandcastle picks up the `ready-for-agent` issues and runs them AFK.

**TDD defaults to heavy.** Every new behaviour gets a failing test before implementation. Every removed behaviour gets a regression test. Every setup step gets a smoke check. See [`tdd-defaults.md`](tdd-defaults.md) for the full policy and the three explicit cases where skipping tests is OK. To opt out per-PRD, include a `## TDD policy` section in the PRD body declaring `LIGHT` with a justification.

## Step 8 — Schedule the first `improve-codebase-architecture` pass

Once the project has ≥5 issues shipped via AFK (i.e. the first drain wave has cleared), run `improve-codebase-architecture` against the integration branch. Vertical-slice pipelines structurally produce horizontal sprawl — every slice touches every layer, so over a dozen slices the same files accumulate un-architected accretion. This skill catches that accretion before it forces manual merge conflict resolution on the next wave.

Cadence going forward: fire it once per drain wave, not once per issue. See [`docs/agents/skill-map.md`](agents/skill-map.md#improve-codebase-architecture) for when-to-fire signals.

## Common gotchas

- **`docker build` fails on M-series Macs** — make sure your base image supports `arm64` (most do; check `FROM` line).
- **`launchctl` not present in CI** — bats tests that assert LaunchAgent absence should `skip` when `command -v launchctl` returns nothing.
- **`glab` and `gh` both missing** — at least one is required for issue ops. Install via brew.
- **Sandcastle iteration count = 0** — usually means the agent didn't emit `<promise>COMPLETE</promise>`. Check `completionSignal` in your `run()` options.
