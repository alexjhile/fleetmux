# afk-workflow

The stamp you apply to any project to make it AFK-ready.

This repo is a thin layer over two upstream tools:

- **[mattpocock/skills](https://github.com/mattpocock/skills)** — the engineering skills (`grill-me`, `to-prd`, `to-issues`, `tdd`, `triage`, etc.) that drive the pipeline
- **[ai-hero/sandcastle](https://github.com/mattpocock/sandcastle)** — the AFK execution backend (Docker / Podman / Vercel sandboxes for running coding agents)

It adds the glue: an opinionated pipeline, an adoption checklist, a Sandcastle template, and a place to capture lessons across projects.

## The Loop

```
vague idea
    │
    ▼
┌─────────────┐       ┌─────────────────────────────┐
│  grill-me   │ ◀──── │  grill-with-docs (preferred │
│             │       │  if project has CONTEXT.md) │
└──────┬──────┘       └─────────────────────────────┘
       ▼
┌─────────────┐
│   to-prd    │  Synthesize the conversation into a PRD; file as ready-for-agent issue
└──────┬──────┘
       ▼
┌─────────────┐       ┌─────────────────────────────┐
│  to-issues  │ ◀──── │  triage (state-machine on   │
│             │       │  any incoming issue)        │
└──────┬──────┘       └─────────────────────────────┘
       ▼
┌─────────────┐       ┌─────────────────────────────┐
│     tdd     │ ◀──── │  diagnose (when a bug       │
│             │       │  surfaces mid-flight)       │
└──────┬──────┘       └─────────────────────────────┘
       ▼
┌─────────────┐
│  Sandcastle │  AFK runs in isolated Docker; commits land on per-ticket branches
└──────┬──────┘
       ▼
   between drain waves: improve-codebase-architecture
   (catches horizontal-sprawl accretion before next wave)
```

The five pipeline skills run in order; the adjunct skills (`grill-with-docs`, `triage`, `diagnose`, `improve-codebase-architecture`, `prototype`, `zoom-out`, `caveman`) fire on signal. See [docs/agents/skill-map.md](docs/agents/skill-map.md) for the full taxonomy and when to fire each.

## Usage

After a project has been bootstrapped (see [adoption checklist](docs/adoption-checklist.md)), telling Claude Code:

> *"Use afk-workflow to add `<feature>` to `<project>`"*

is the natural-language entry point. Claude reads this README, runs the pipeline, hands AFK execution to Sandcastle.

## Repo layout

```
afk-workflow/
├── README.md                  # You are here
└── docs/
    ├── agents/                # Per-repo conventions (issue tracker, triage, domain)
    ├── install.md             # One-time install: matt skills + Sandcastle
    ├── adoption-checklist.md  # Per-project bootstrap checklist
    ├── tdd-defaults.md        # Heavy TDD is the default; opt-out is per-PRD
    └── sandcastle-template/   # Generic .sandcastle/ scaffold
```

## Status

**Pre-1.0.** The workflow is still being proven in practice; expect rough edges.

## Prior art & credit

This workflow stands entirely on **[Matt Pocock](https://github.com/mattpocock)'s** work:

- **[Sandcastle](https://www.npmjs.com/package/@ai-hero/sandcastle)** (`@ai-hero/sandcastle`) — the sandboxed autonomous-run harness this workflow drives. The `sandcastle-template/` here is adapted from its scaffold.
- **[mattpocock/skills](https://github.com/mattpocock/skills)** — the engineering skills (`grill-me`, `to-prd`, `to-issues`, …) that the pipeline applies. Read [matt's README](https://github.com/mattpocock/skills) for the philosophy.

This repo just answers "OK, what does that look like applied to my projects?" — it doesn't redistribute Sandcastle or the skills; you install them per their own instructions ([install.md](docs/install.md)).
