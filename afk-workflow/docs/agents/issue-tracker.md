# Issue tracker: GitLab

Issues and PRDs for this repo (and adopting projects, by default) live as GitLab issues. Use the `glab` CLI for all operations.

## Conventions

- **Create an issue**: `glab issue create --title "..." --description "..." --label "..."`. Use a heredoc for multi-line descriptions.
- **Read an issue**: `glab issue view <number>` (add `--comments` for comments).
- **List issues**: `glab issue list --opened --label "<label>"` (or `--closed`, `--all`).
- **Comment on an issue**: `glab issue note <number> --message "..."`.
- **Apply / remove labels**: `glab issue update <number> --label "..."` / `--unlabel "..."`.
- **Close**: `glab issue close <number>`.
- **Open**: `glab issue reopen <number>`.

Infer the repo from `git remote -v` — `glab` does this automatically when run inside a clone.

## When a skill says "publish to the issue tracker"

Create a GitLab issue.

## When a skill says "fetch the relevant ticket"

Run `glab issue view <number>`.

## GitHub variant

If an adopting project uses GitHub instead of GitLab, replace every `glab` with `gh` and the same commands work — `gh issue create`, `gh issue view <N> --comments`, etc. Pick whichever the project's `git remote -v` actually points at.
