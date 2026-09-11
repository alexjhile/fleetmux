# Domain docs

How the engineering skills should consume this repo's domain documentation.

## Layout

This repo (and the default for adopting projects) is **single-context**:

```
/
├── CONTEXT.md
├── docs/adr/
│   ├── 0001-some-decision.md
│   └── 0002-another-decision.md
└── ...
```

If `CONTEXT-MAP.md` exists at the repo root, the project is **multi-context** (typically a monorepo) and skills should read each context-scoped `CONTEXT.md` separately.

## Before exploring a repo, read these

- `CONTEXT.md` at the repo root — the domain glossary.
- `docs/adr/` — architectural decision records that touch the area you're about to work in.

If any of these don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. They get created lazily as terms and decisions resolve (via `grill-with-docs`).

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `CONTEXT.md`. Don't drift to synonyms.

If the concept you need isn't in the glossary, that's a signal: either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for the next grill session).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly:

> _Contradicts ADR-0007 (event-sourced orders) — but worth reopening because…_
