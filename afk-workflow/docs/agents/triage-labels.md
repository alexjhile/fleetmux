# Triage labels

Five canonical triage roles. The `triage` skill uses these labels to drive its state machine.

| Role               | Label string        | Meaning                                  |
| ------------------ | ------------------- | ---------------------------------------- |
| `needs-triage`     | `needs-triage`      | Maintainer needs to evaluate this issue  |
| `needs-info`       | `needs-info`        | Waiting on reporter for more information |
| `ready-for-agent`  | `ready-for-agent`   | Fully specified, ready for an AFK agent  |
| `ready-for-human`  | `ready-for-human`   | Requires human implementation            |
| `wontfix`          | `wontfix`           | Will not be actioned                     |

Defaults are 1:1 — label string equals role name. Override the right-hand column if the project's tracker already uses different vocabulary (e.g. `bug:triage` instead of `needs-triage`).

## Bootstrapping these labels on a new project

Run the canonical-label setup command (`glab` example below; `gh` works the same shape):

```bash
glab label create --name "needs-triage"    --color "#FBCA04" --description "Maintainer needs to evaluate this issue"
glab label create --name "needs-info"      --color "#D4C5F9" --description "Waiting on reporter for more information"
glab label create --name "ready-for-agent" --color "#0E8A16" --description "Fully specified, ready for an AFK agent"
glab label create --name "ready-for-human" --color "#1D76DB" --description "Requires human implementation"
glab label create --name "wontfix"         --color "#CCCCCC" --description "Will not be actioned"
```
