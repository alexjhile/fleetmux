# fleetmux on Windows (WSL2)

fleetmux is built on `tmux`, and tmux doesn't run natively on Windows. So on Windows, fleetmux runs inside **WSL2** (a real Linux userland), and you drive it from Windows through PowerShell, cmd, Windows Terminal, or the browser dashboard.

```
 Windows                               WSL2 (Ubuntu)
 ─────────────────────────────         ──────────────────────────────────────
 PowerShell:  fleetmux run api "…" ──▶ fleetmux ─▶ tmux ─▶ claude (per session)
 Windows Terminal "fleetmux" tab  ──▶ fleetmux.command (Claude + dashboard)
 Browser  http://localhost:9035   ──▶ GUI server (node) ─▶ fleetmux / tmux
                                        └─ssh─▶ remote hosts (unchanged)
```

Everything runs inside WSL: the CLI, tmux, Claude Code, and the GUI server. The Windows side only has a thin `fleetmux.cmd` shim, a Windows Terminal profile, and your browser.

## 1. Install WSL2 + Ubuntu (one time, needs admin + reboot)

In an **admin** PowerShell:

```powershell
wsl --install -d Ubuntu
```

Reboot when asked, then open "Ubuntu" from the Start menu and create your Linux user.

## 2. Install the prerequisites *inside* Ubuntu

```bash
sudo apt-get update
sudo apt-get install -y tmux jq git curl build-essential python3

# Claude Code — install it inside WSL. The Windows claude.exe can't drive tmux sessions.
curl -fsSL https://claude.ai/install.sh | bash
claude            # run once and sign in

# Node 20.11+ for the web GUI (Ubuntu's apt nodejs is too old)
curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
exec bash && nvm install --lts
```

## 3. Get fleetmux into the WSL filesystem and run setup

Clone into your WSL home dir. It also works from `/mnt/c/...`, but git, npm and file watching are much slower across the Windows/Linux boundary.

```bash
git clone https://github.com/alexjhile/fleetmux.git ~/fleetmux
cd ~/fleetmux
./setup.sh
```

If you already have a copy on the Windows side, copy it in instead: `cp -r /mnt/c/Users/<you>/Fleetmux ~/fleetmux`.

Under WSL, `setup.sh` does the usual setup (CLI on PATH, `sessions.json`, GUI build, server on :9035, opens your Windows browser). It also:

- **writes `fleetmux.cmd`** into `%USERPROFILE%\.local\bin` if that folder is on your Windows PATH, and into `%USERPROFILE%\bin` otherwise (it prints how to add it to PATH). Override the location with `FLEETMUX_WIN_BIN`. After that, `fleetmux list` works straight from PowerShell.
- **adds a "fleetmux" Windows Terminal profile.** Pick it from the tab dropdown to get Claude Code with the dashboard docked. This is the Windows equivalent of double-clicking `fleetmux.command` on macOS.
- **puts a "fleetmux homebase" shortcut on your desktop.** It opens the same thing: the `homebase` controller session with the dashboard, in Windows Terminal if it's installed. If homebase is already running, it reattaches instead of starting a second copy.

## 4. Daily use

| From | Do |
|---|---|
| PowerShell / cmd | `fleetmux list`, `fleetmux run api "…"`, `fleetmux attach api` |
| Windows Terminal | open the **fleetmux** profile (Claude + dashboard, reattaches if running) |
| Browser | http://localhost:9035. The "Master Terminal" and popout buttons open Windows Terminal tabs. |

## Things that differ from macOS

- **Paths.** Local sessions run inside WSL, so their `path` is a Linux path. Keep repos under `~` (fast) or use `/mnt/c/...`. `fleetmux add` also accepts `C:\...` paths and converts them for you.
- **SSH keys.** WSL has its own `~/.ssh`. Copy your keys in (`cp /mnt/c/Users/<you>/.ssh/id_* ~/.ssh/ && chmod 600 ~/.ssh/id_*`) or generate new ones. Remote sessions are otherwise unchanged.
- **Auth.** Claude Code inside WSL stores its login in `~/.claude/.credentials.json` (there's no macOS Keychain). Multi-account tokens (`fleetmux account …`) work the same.
- **Clipboard.** With `tmux.conf`, a mouse selection is copied to the Windows clipboard through OSC 52, which Windows Terminal supports. `pbcopy` is only used on macOS.
- **Keep-awake for AFK runs.** `fleetmux afk` holds a Windows "system required" power request for the duration of the run (the equivalent of `caffeinate -i`), so an overnight drain won't be cut off by idle sleep. It doesn't stop a manual sleep or a closed lid.
- **WSL shutting down.** WSL may stop the distro, including tmux and every session in it, when no Windows process is using it. How long it waits depends on the WSL version. Keeping a fleetmux tab or the GUI open in Windows Terminal keeps it alive.
- **Desktop app (optional).** The Tauri app is only a window onto `localhost:9035`, so build it natively on Windows (Rust + WebView2) with `cd gui && npm run tauri:build -- --bundles nsis`. It talks to the server running in WSL.
