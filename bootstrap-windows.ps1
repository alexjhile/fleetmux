#Requires -Version 5.1
<#
    fleetmux - one-paste Windows bootstrap.

    Run in an *administrator* PowerShell:

        irm https://raw.githubusercontent.com/alexjhile/fleetmux/main/bootstrap-windows.ps1 | iex

    or, from a clone:  powershell -ExecutionPolicy Bypass -File .\bootstrap-windows.ps1

    It installs WSL2 + Ubuntu (reboot needed the first time), then inside the
    distro installs the prerequisites, clones fleetmux and runs ./setup.sh.
    Safe to re-run: every step is skipped when it is already done.

    Two things stay manual, by design - they are Claude Code's own security
    gates: signing in (`claude`), and trusting each project folder.
#>
[CmdletBinding()]
param(
    [string]$Distro  = 'Ubuntu',
    [string]$RepoUrl = 'https://github.com/alexjhile/fleetmux.git',
    [string]$RepoDir = 'fleetmux'
)

$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'   # wsl.exe otherwise prints UTF-16, which breaks matching

function Say  ($m) { Write-Host "`n>> $m" -ForegroundColor Cyan }
function Ok   ($m) { Write-Host "   OK  $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "   !   $m" -ForegroundColor Yellow }
function Die  ($m) { Write-Host "`n   X   $m`n" -ForegroundColor Red; exit 1 }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

Write-Host @'
  __ _          _
 / _| |___ ___ | |_ _ __ _  _ _  _ ___
|  _| / -_) -_)|  _| '  \ || \ \/ /_-<
|_| |_\___\___| \__|_|_|_\_,_/_/\_\___/   Windows bootstrap
'@ -ForegroundColor Magenta

# -- 1. WSL2 + the distro ----------------------------------------------------
Say 'Checking WSL2'
$wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
if (-not $wsl) {
    if (-not (Test-Admin)) { Die 'WSL is not installed. Re-run this in an ADMINISTRATOR PowerShell.' }
    Say "Installing WSL2 + $Distro (this reboots Windows)"
    wsl.exe --install -d $Distro
    Warn 'Reboot, open Ubuntu from the Start menu to create your Linux user, then re-run this script.'
    exit 0
}
Ok 'wsl.exe present'

$installed = @()
try { $installed = @(wsl.exe -l -q 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } catch { }
if ($installed -notcontains $Distro) {
    if (-not (Test-Admin)) { Die "$Distro is not installed. Re-run this in an ADMINISTRATOR PowerShell." }
    Say "Installing $Distro"
    wsl.exe --install -d $Distro
    Warn "Open $Distro from the Start menu to create your Linux user, then re-run this script."
    exit 0
}
Ok "$Distro installed"

# A distro with no user yet answers as root; setup.sh must not run as root.
$who = (wsl.exe -d $Distro -e whoami 2>$null | Out-String).Trim()
if (-not $who)        { Die "$Distro did not start. Open it from the Start menu once, then re-run." }
if ($who -eq 'root')  { Die "$Distro has no normal user yet. Open it from the Start menu, create your user, then re-run." }
Ok "Linux user: $who"

# -- 2. Everything else, inside the distro -----------------------------------
# Passed base64 so no quoting survives the Windows->WSL argv hop, and run on
# the console (not piped) so sudo can still ask for a password.
$bash = @"
set -e
say() { printf '\n>> %s\n' "`$1"; }

say 'Installing git (needed to clone fleetmux)'
if ! command -v git >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y git
fi

REPO="`$HOME/$RepoDir"
if [ -d "`$REPO/.git" ]; then
  say "Updating existing clone at `$REPO"
  git -C "`$REPO" pull --ff-only || echo '   !   could not fast-forward; leaving your checkout alone'
else
  say "Cloning $RepoUrl into `$REPO"
  git clone $RepoUrl "`$REPO"
fi

say 'Running setup (installs prerequisites, builds the GUI, starts it)'
cd "`$REPO"
./setup.sh --install-deps --yes
"@

$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($bash -replace "`r`n", "`n")))
Say "Setting up fleetmux inside $Distro (sudo may ask for your Linux password)"
wsl.exe -d $Distro -e bash -lc "echo $b64 | base64 -d > /tmp/fleetmux-bootstrap.sh && bash /tmp/fleetmux-bootstrap.sh"
if ($LASTEXITCODE -ne 0) { Die "setup failed inside $Distro - scroll up for the error, then re-run this script." }

# -- 3. What is left for a human ---------------------------------------------
Write-Host ''
Ok 'fleetmux is installed.'
Write-Host @"

Two steps only you can do:

  1. Sign in to Claude Code - in Ubuntu (or any terminal), run:
         wsl -d $Distro -e bash -lc claude
     and follow the browser prompt. Once per machine.

  2. The first time a session opens a folder, Claude asks
     "Do you trust this folder?" - answer Yes.

Then:
  * Desktop icon  "fleetmux homebase"   - Claude Code + the fleet dashboard
  * Dashboard     http://localhost:9035 - comes back on its own after a reboot
  * PowerShell    fleetmux list         - the CLI, straight from Windows

"@ -ForegroundColor Gray
