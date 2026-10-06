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

## 0. One-paste bootstrap (does sections 1-3 for you)

In an **administrator** PowerShell:

```powershell
irm https://raw.githubusercontent.com/alexjhile/fleetmux/main/bootstrap-windows.ps1 | iex
```

`bootstrap-windows.ps1` installs WSL2 + Ubuntu if missing (Windows reboots once; open Ubuntu afterwards to create your Linux user, then re-run the same line), then installs the prerequisites inside the distro, clones fleetmux to `~/fleetmux` and runs `./setup.sh --install-deps --yes`. `sudo` asks for your Linux password once. Every step is skipped if already done, so re-running is safe.

Prefer to do it by hand, or not on a fresh machine? Sections 1-3 are the manual equivalent.

## 1. Install WSL2 + Ubuntu (one time, needs admin + reboot)

In an **admin** PowerShell:

```powershell
wsl --install -d Ubuntu
```

Reboot when asked, then open "Ubuntu" from the Start menu and create your Linux user.

## 2. Install the prerequisites *inside* Ubuntu

```bash
# Or skip this whole section: ./setup.sh --install-deps does it (asking first).
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
- **starts the dashboard at boot.** It installs a systemd *user* unit (`fleetmux-gui`) and turns on user lingering, so `localhost:9035` comes back by itself after a Windows restart. This needs systemd inside WSL (`[boot] systemd=true` in `/etc/wsl.conf`, then `wsl --shutdown`); without it, opening homebase starts the dashboard instead. Check with `fleetmux gui status`.
- **links `tmux.conf` to `~/.tmux.conf`** (50k scrollback, mouse select, OSC 52 clipboard), unless you already have one — then it prints the `source-file` line to add.
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
- **WSL shutting down.** By default WSL stops Ubuntu a few seconds after the last terminal attached to it closes, even while tmux, your Claude sessions and the GUI server are still running, and that kills them all. `setup.sh` turns this off by adding `instanceIdleTimeout=-1` under `[general]` in `%USERPROFILE%\.wslconfig`. It leaves any existing setting alone, and the change takes effect after `wsl --shutdown`. The trade-off: Ubuntu keeps running (and keeps its memory) until you run `wsl --shutdown` or restart Windows. Delete that line to get WSL's default back.
- **Desktop app (optional).** The Tauri app is only a window onto `localhost:9035`, so build it natively on Windows (Rust + WebView2) with `cd gui && npm run tauri:build -- --bundles nsis`. It talks to the server running in WSL.
