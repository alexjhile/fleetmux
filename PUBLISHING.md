# Publishing checklist

Notes for putting fleetmux on GitHub (and helping people find it). Not part of the
tool — safe to delete after the repo is live.

## 1. Create the repo

Create an **empty** repo at `github.com/<you>/fleetmux` — **no** README, license, or
.gitignore (this repo already ships its own; an auto-generated one would conflict
with the clean single commit).

```bash
git remote add origin https://github.com/<you>/fleetmux.git
git push -u origin main
```

## 2. Set the description (the one-liner GitHub shows in search & at the top of the repo)

> Command a fleet of Claude Code sessions across local + remote hosts from one terminal — a tmux-based CLI with an optional web dashboard.

## 3. Add topics (drives GitHub search / discovery)

```
claude-code  ai-agents  tmux  cli  orchestration  developer-tools  bash  agent-orchestration
```

Set both via the ⚙️ "About" panel on the repo page, or with the CLI:

```bash
gh repo edit --description "Command a fleet of Claude Code sessions across local + remote hosts from one terminal — a tmux-based CLI with an optional web dashboard."
gh repo edit --add-topic claude-code,ai-agents,tmux,cli,orchestration,developer-tools,bash,agent-orchestration
```

## 4. Optional polish

- Pin the repo on your profile.
- Add a short demo GIF/asciinema to the README top (a `fleetmux list` + `watch` clip converts browsers to users).
- `npm audit fix` inside `gui/` and `gui/server/` to clear transitive-dependency advisories.

## 5. Verified state at first publish

- CLI: `make check` → shellcheck clean + 55 bats tests pass
- GUI: `cd gui && npm install && npm run build` ✓ · `cd gui/server && npm install && npm test` → 33/33 · `npx tsc --noEmit` clean
- No secrets, IPs, personal paths, or business names in the tree or history
