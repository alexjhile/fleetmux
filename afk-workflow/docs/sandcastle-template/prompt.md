# Sandcastle prompt template

Drop this in your project's `.sandcastle/prompt.md` and customise. The placeholders below are the variables you'll typically interpolate via `promptArgs` or `!\`command\`` expansion.

---

You are working on issue #{{ISSUE_NUMBER}} on branch `{{SOURCE_BRANCH}}`. The target branch (the host's HEAD when this run started) is `{{TARGET_BRANCH}}`.

## Context

Read the project's `CLAUDE.md` and `CONTEXT.md` first to anchor your vocabulary and understand the conventions.

## Issue

!`glab issue view {{ISSUE_NUMBER}}`

(For GitHub-tracked projects, replace with `!\`gh issue view {{ISSUE_NUMBER}} --comments\``.)

## Your job

1. **Read the issue carefully.** Note the acceptance criteria and any "Blocked by" references — those should already be merged before this ticket runs.
2. **If the issue references a PRD parent**, read that too: `!\`glab issue view <parent-number>\``.
3. **Use TDD per matt's `tdd` skill** — red/green/refactor, one behaviour at a time. Don't write all tests up front.
   - **Heavy TDD is the default in this workflow** — see `afk-workflow/docs/tdd-defaults.md`.
   - Every new behaviour gets a failing test before implementation. Every removed behaviour gets a regression test. Every setup step gets a smoke check.
   - The only exemptions are: pure docs changes, pure deletion already covered by existing tests, or trivial config bumps. If you claim an exemption, say so explicitly in the commit message.
4. **Commit incrementally.** One logical change per commit. Bisectable.
5. **Stay in scope.** Don't expand beyond the acceptance criteria. If you find an unrelated issue, file it; don't fix it here.
6. **When all acceptance criteria are met**, output `<promise>COMPLETE</promise>` to end the iteration loop.

## Constraints

- Don't commit secrets, `.env` files, or anything in `.sandcastle/.env`.
- Don't modify `CLAUDE.md` or other project documentation unless the issue explicitly calls for it.
- Don't skip pre-commit hooks (`--no-verify`) — fix the underlying issue if a hook fails.
- If you're stuck after 2 attempts at the same fix, output what you tried and what's still failing rather than spinning further.
