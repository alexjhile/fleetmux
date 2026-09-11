# Skill map

Which upstream skills the workflow uses, when to fire them, and which are non-obvious adjuncts that the 5-step pipeline diagram in `README.md` doesn't surface.

All skills live upstream at [`mattpocock/skills`](https://github.com/mattpocock/skills). This repo never forks or vendors them; see `CLAUDE.md` for the no-fork rule.

## Pipeline skills (the five in the README loop)

These run in order. Each is a hard dependency on `setup-matt-pocock-skills` having scaffolded `docs/agents/{issue-tracker,triage-labels,domain}.md` in the target project.

| Skill | Consumes | Produces | Hard-dep on setup |
|---|---|---|---|
| `grill-me` | A half-formed plan or design from the human | Shared understanding in conversation context | No (soft) |
| `to-prd` | Conversation context + repo state | A markdown PRD published as a `ready-for-agent` issue | **Yes** |
| `to-issues` | A PRD (inline or by issue ref) | Multiple tracer-bullet vertical-slice issues, dependency-ordered, labelled HITL or AFK | **Yes** |
| `tdd` | A single AFK issue (typically inside Sandcastle) | Red → green → refactor cycles, one behaviour at a time, vertical not horizontal | No (soft) |
| `triage` | An incoming issue or "what needs attention?" request | Label transitions in the canonical state machine, plus a brief comment | **Yes** |

The README loop diagram shows `grill-me → to-prd → to-issues → tdd → sandcastle`. `triage` is the meta-skill that keeps the issue tracker honest before and after the pipeline runs — apply it to any incoming bug or feature request before it enters the loop.

## Adjunct skills (fire on signal, not on schedule)

These don't appear in the pipeline diagram but are part of the same upstream skill set. Use them when the signal fires; ignore them otherwise.

### `improve-codebase-architecture`
**Fire when.** After a heavy merge wave (≥5 streams shipping into one branch), or when cross-stream file contention shows up in conflict-resolution diffs. Also: before any "mainnet-readiness" or "v1.0" gate.

**Consumes.** The project's `CONTEXT.md` + `docs/adr/*` + the current code. The skill reads the domain language and looks for deepening opportunities — modules that should consolidate, abstractions that should compress, names that should align with the glossary.

**Produces.** Concrete refactor proposals as issues (labelled `ready-for-agent` or `ready-for-human` depending on shape).

**Why it matters here.** A pipeline that ships many tracer-bullet vertical slices is structurally biased toward horizontal sprawl: every slice touches every layer, so over a dozen slices the same files (e.g. `spread_capture.py`, `metrics.py`) collect un-architected accretion. Running this skill between drain waves catches the accretion before it forces manual merge conflict resolution.

### `grill-with-docs`
**Fire when.** Any time you'd reach for `grill-me` AND the target project has a `CONTEXT.md` + ADRs. This variant grills against the existing domain model and updates `CONTEXT.md` / writes new ADRs inline as decisions crystallise.

**Why prefer it over `grill-me`.** `grill-me` produces shared understanding in conversation only. `grill-with-docs` persists what's worth keeping. For any project past tracer-bullet, this is the better default.

### `diagnose`
**Fire when.** A bug surfaces in production or in CI. Especially: multi-layer bugs where the surface symptom doesn't point at the cause.

**Loop.** Reproduce → minimise → hypothesise → instrument → fix → regression-test. The regression-test step is mandatory — every fix gets a test that would have caught the bug before deploy.

### `prototype`
**Fire when.** A design decision needs a runnable artifact before committing. Two modes:
- **State / business-logic** — a terminal app that exercises the state machine or data model.
- **UI variants** — several radically different mockups toggleable from one route.

**Output.** Throwaway code; the goal is shared understanding, not a foundation. The prototype gets deleted after the design is locked.

### `zoom-out`
**Fire when.** An AFK sub-agent's stream events show "I don't understand X" or "where does X live" patterns. Or when you're reviewing an agent's work and the change looks locally correct but globally off.

**Effect.** Re-orients the agent to system-wide context (the `CONTEXT.md` glossary + ADRs + adjacent modules) rather than the narrow file it was editing.

### `caveman`
**Fire when.** Token budget is tight. Drops filler, articles, hedging while keeping technical substance (~75% reduction). Particularly useful for dispatch briefs that have to fit in a sub-agent's context budget.

## Skills the orchestration layer should know about

Some skills aren't fired by `afk-workflow` directly — they're fired by the orchestration host (e.g. `homebase` Claude Code) and act on this workflow's outputs. Document them here so adopting projects know they exist:

- `review` — pre-landing code review against `origin/main`. Run before merge.
- `ship` — full automated ship: merge main, run tests, review diff, push, create MR.
- `plan-ceo-review` — founder-mode plan review (scope expansion / hold / reduction).
- `plan-eng-review` — eng-manager-mode plan review (architecture, edge cases, perf).
- `retro` — engineering retrospective with commit analysis.
- `verify-feature` — end-to-end feature verification.
- `exploration` — structured checkpoint protocol for open-ended debugging.

These are upstream skills too; the orchestration host invokes them. The workflow doesn't need to do anything special — they consume issue history, branch state, and PRs that this workflow produces.

## Setup prerequisite

All skills above assume `setup-matt-pocock-skills` ran against the project. The hard-dep skills (`to-prd`, `to-issues`, `triage`) silently produce wrong output without it; soft-dep skills (`tdd`, `diagnose`, `improve-codebase-architecture`, `zoom-out`) degrade quietly. Adoption checklist Step 1 verifies setup; don't skip it.

## Foundational vocabulary

Terms like *session*, *turn*, *context window*, *harness*, *MCP*, *AFK*, *HITL*, *tracer bullet* are defined upstream in [mattpocock/dictionary-of-ai-coding](https://github.com/mattpocock/dictionary-of-ai-coding). Defer to that glossary rather than redefining; only project-specific vocabulary belongs in this repo's `CONTEXT.md`.
