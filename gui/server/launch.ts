// Native terminal windows for the "Master Terminal" and per-session popout
// buttons. macOS: Terminal.app via `open` on a .command file. WSL (fleetmux on
// Windows): a Windows Terminal tab — or a plain console window if Windows
// Terminal isn't installed — running the script inside this distro.
import { exec, spawn } from 'child_process'
import os from 'os'

export const IS_MAC = process.platform === 'darwin'
export const IS_WSL =
  process.platform === 'linux' && (!!process.env.WSL_DISTRO_NAME || /microsoft/i.test(os.release()))

// Extension the popout script needs so the platform opener will run it.
export const TERMINAL_SCRIPT_EXT = IS_MAC ? 'command' : 'sh'

// Spawn detached; resolves false if the binary can't be launched at all.
function launchDetached(cmd: string, args: string[]): Promise<boolean> {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, { detached: true, stdio: 'ignore' })
    child.once('error', () => resolve(false))
    child.once('spawn', () => {
      child.unref()
      resolve(true)
    })
  })
}

// Open a new native terminal window running `scriptPath` with bash.
// `login` runs it as a login shell so ~/.local/bin (claude) and ~/bin are on PATH.
export async function openTerminalWithScript(scriptPath: string, title: string, login = false): Promise<void> {
  if (IS_MAC) {
    exec(`open "${scriptPath}"`)
    return
  }
  if (IS_WSL) {
    const distro = process.env.WSL_DISTRO_NAME
    const wslArgs = [...(distro ? ['-d', distro] : []), '-e', 'bash', ...(login ? ['-l'] : []), scriptPath]
    if (await launchDetached('wt.exe', ['-w', '0', 'new-tab', '--title', title, 'wsl.exe', ...wslArgs])) return
    if (await launchDetached('cmd.exe', ['/c', 'start', 'wsl.exe', ...wslArgs])) return
    throw new Error('Could not launch Windows Terminal (wt.exe) or cmd.exe from WSL')
  }
  throw new Error('No native terminal launcher for this platform — use the in-browser terminal')
}
