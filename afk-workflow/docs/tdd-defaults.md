# TDD defaults

**Heavy TDD is the default in this workflow.** When you're not sure whether a change needs tests, add them.

This is opinionated. Other workflows leave TDD depth to the agent's judgement; this one doesn't. The reason: AFK runs are unsupervised, and untested code that lands on a branch is a hidden regression waiting to bite three weeks later when no human remembers what the agent intended. Tests are how the agent proves its intent matches reality.

## What heavy TDD means

For every `ready-for-agent` ticket, the AFK agent should:

1. **Plan the test list before writing code.** What behaviours does this slice introduce or change? Each becomes a failing test. Per matt's `tdd` skill: list behaviours, not implementation steps.
2. **Red → green → refactor, one behaviour at a time.** Vertical slicing inside the ticket. No batching tests up front, no batching implementation either.
3. **Test the public interface, not the implementation.** A good test survives a refactor; it fails only when behaviour changes. Asserting `lib/foo.sh exists` is testing implementation. Asserting `cli foo --bar` exits 0 with expected output is testing behaviour.
4. **Add a smoke test for any setup step.** Even one-time bootstrap work (Docker image build, dep install, secret wiring) gets a one-line smoke check. Cost: tiny. Value: catches regressions when someone tweaks the setup six months later.
5. **Add a regression test for every removed behaviour.** Deleting code is a change too. The regression test asserts the change holds — e.g. "feature X no longer responds at endpoint Y."

## When skipping tests is OK

Three explicit cases. Anything outside these requires a test:

- **Pure documentation changes.** Editing `README.md` / `CLAUDE.md` / ADRs. No code, no behaviour.
- **Pure deletion of obsolete code where existing tests already cover the public interface.** Example: removing internal helpers that aren't part of the public CLI, when CLI tests already exist. Justify in the issue body.
- **Trivial config changes audited by visual review.** Example: bumping a version number in a config file. Justify in the issue body.

If a slice claims one of these exemptions, the issue body must say so explicitly with a one-sentence reason. No exemption, no skip.

## Standard test infrastructure per language

The agent should use the project's existing test conventions. Don't introduce a new framework. Common defaults:

| Language / project type | Test framework |
| --- | --- |
| Bash CLI | `bats-core` |
| TypeScript / JavaScript | `vitest` (or whatever's in `package.json`) |
| Python | `pytest` |
| Go | built-in `testing` |
| Rust | built-in `#[test]` |

If the project has none, the AFK agent's first task on that project should be setting up a default framework — a separate `ready-for-human` ticket, since the choice is opinionated.

## Coverage expectations

No coverage percentage targets. They incentivise gaming. Instead:

- **Every public behaviour described in the PRD has at least one test.**
- **Every removed behaviour described in the PRD has at least one regression test.**
- **Every setup step has at least a one-line smoke check.**

## Opting out per-PRD

A PRD can opt out of heavy TDD by including a section:

```markdown
## TDD policy
LIGHT — see "When skipping tests is OK" in afk-workflow/docs/tdd-defaults.md.
Justification: <one-paragraph reason this PRD doesn't benefit from heavy TDD>
```

If a PRD has no `## TDD policy` section, the default is heavy. Slicing it via `to-issues` produces tickets that expect tests; AFK agents will fail loud if a slice closes without tests on a non-exempt change.
