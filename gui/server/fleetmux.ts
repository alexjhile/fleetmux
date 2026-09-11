import { execSync, exec } from 'child_process'
import { readFileSync, existsSync } from 'fs'
import path from 'path'
import os from 'os'

const HOME_DIR = process.env.HOME || os.homedir()
// Repo root holding the fleetmux CLI + sessions.json. This server lives in
// <repo>/gui/server, so the default is two levels up. Override with FLEETMUX_DIR.
const FLEETMUX_DIR = process.env.FLEETMUX_DIR || path.resolve(import.meta.dirname, '..', '..')
const FLEETMUX_CLI = process.env.FLEETMUX_CLI || path.join(FLEETMUX_DIR, 'fleetmux')
const TMUX_SESSION = 'fleetmux'

// Ensure tmux/git/ssh work when started via a minimal-env launcher (e.g. launchd).
const TMUX_SOCKET = `/tmp/tmux-${process.getuid!()}/default`
const EXEC_ENV: Record<string, string> = {
  ...process.env as Record<string, string>,
  PATH: process.env.PATH || '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin',
  TMUX_TMPDIR: `/tmp/tmux-${process.getuid!()}`,
  HOME: HOME_DIR,
  USER: process.env.USER || os.userInfo().username,
  SHELL: process.env.SHELL || '/bin/sh',
  TERM: 'xterm-256color',
  LANG: process.env.LANG || 'en_US.UTF-8',
  ...(process.env.SSH_AUTH_SOCK ? { SSH_AUTH_SOCK: process.env.SSH_AUTH_SOCK } : {}),
}

const SESSIONS_FILE = path.join(FLEETMUX_DIR, 'sessions.json')
const TASKS_FILE = path.join(FLEETMUX_DIR, 'tasks.json')
const USAGE_CACHE_FILE = path.join(FLEETMUX_DIR, 'usage-cache.json')
const LIMITS_CACHE_FILE = path.join(FLEETMUX_DIR, 'limits-cache.json')
const ACCOUNTS_MANIFEST = path.join(
  process.env.FLEETMUX_SECRETS_DIR || path.join(HOME_DIR, '.config', 'fleetmux', 'secrets'),
  'claude-accounts',
  'accounts.json'
)

// ── Async exec helper ────────────────────────────────────────────

function execAsync(cmd: string, timeout = 5000): Promise<string> {
  return new Promise((resolve, reject) => {
    exec(cmd, { timeout, env: EXEC_ENV, encoding: 'utf-8' }, (err, stdout) => {
      if (err) reject(err)
      else resolve(stdout)
    })
  })
}

// ── Session Registry ──────────────────────────────────────────────

export interface SessionConfig {
  name: string
  type: 'local' | 'remote'
  path: string
  host?: string
  local_path?: string
  description: string
  tags: string[]
  autostart: boolean
  claude_flags: string
  account?: string
}

// ── Accounts & Usage ──────────────────────────────────────────────

export interface AccountMeta {
  email?: string
  subscription?: string
  updated_at?: string
}

export interface AccountInfo {
  name: string
  email: string
  subscription: string
  usedBy: string[]
}

export interface UsageStats {
  turns: number
  input_tokens: number
  cache_creation_tokens: number
  cache_read_tokens: number
  output_tokens: number
  total_tokens: number
  tokens_24h: number
  tokens_7d: number
  turns_24h: number
  turns_7d: number
  conversations: number
  last_activity: string | null
}

export interface UsageCache {
  refreshed_at: string
  sessions: Array<{
    name: string
    type: string
    account: string
    usage: UsageStats
  }>
}

export function readAccountsManifest(): Record<string, AccountMeta> {
  try {
    return JSON.parse(readFileSync(ACCOUNTS_MANIFEST, 'utf-8'))
  } catch {
    return {}
  }
}

export function readUsageCache(): UsageCache | null {
  try {
    return JSON.parse(readFileSync(USAGE_CACHE_FILE, 'utf-8'))
  } catch {
    return null
  }
}

export function getAccountsList(): AccountInfo[] {
  const manifest = readAccountsManifest()
  const sessions = readSessions()
  const names = new Set<string>(Object.keys(manifest))
  // Also pick up any account referenced by a session that lacks metadata
  for (const s of sessions) {
    if (s.account) names.add(s.account)
  }
  return Array.from(names).sort().map((name) => ({
    name,
    email: manifest[name]?.email || '',
    subscription: manifest[name]?.subscription || '',
    usedBy: sessions.filter((s) => s.account === name).map((s) => s.name),
  }))
}

export async function setSessionAccount(session: string, account: string): Promise<void> {
  // Empty string clears the account (uses default auth).
  const cmd = account
    ? `${FLEETMUX_CLI} account set ${JSON.stringify(session)} ${JSON.stringify(account)}`
    : `${FLEETMUX_CLI} account unset ${JSON.stringify(session)}`
  await execAsync(cmd, 8000)
}

export async function refreshUsage(): Promise<void> {
  await execAsync(`${FLEETMUX_CLI} usage refresh`, 60000)
}

// ── Subscription Limits (5h / 7d from Anthropic headers) ─────────

export interface LimitsWindow {
  used_percentage: number | null
  resets_at: number | null
  status: string | null
}

export interface AccountLimits {
  account: string
  organization_id?: string | null
  five_hour?: LimitsWindow
  seven_day?: LimitsWindow
  seven_day_opus?: LimitsWindow
  representative?: string | null
  overage_status?: string | null
  overage_disabled_reason?: string | null
  checked_at?: string
  error?: string
  http_code?: number
}

export interface LimitsCache {
  refreshed_at: string | null
  accounts: AccountLimits[]
}

export function readLimitsCache(): LimitsCache | null {
  try {
    return JSON.parse(readFileSync(LIMITS_CACHE_FILE, 'utf-8'))
  } catch {
    return null
  }
}

export async function refreshLimits(): Promise<void> {
  await execAsync(`${FLEETMUX_CLI} account limits refresh`, 30000)
}

// ── Model Guard ───────────────────────────────────────────────────

export interface ModelGuardState {
  [session: string]: {
    original_model: string
    current_override: string
    overridden_at: string
  }
}

export function readModelGuardState(): ModelGuardState {
  try {
    return JSON.parse(readFileSync(path.join(FLEETMUX_DIR, 'model-guard-state.json'), 'utf-8'))
  } catch {
    return {}
  }
}

export function readModelGuardConfig() {
  const defaults = { enabled: true, curve: 7.5, min_usage: 0.50, haiku_usage: 0.85, emergency_usage: 0.95, restore_usage: 0.40, restore_hours: 0.5 }
  try {
    const cfg = JSON.parse(readFileSync(path.join(FLEETMUX_DIR, 'model-guard-config.json'), 'utf-8'))
    return { ...defaults, ...cfg, enabled: cfg.enabled !== false }
  } catch {
    return defaults
  }
}

export async function modelGuardToggle(enable: boolean): Promise<void> {
  await execAsync(`${FLEETMUX_CLI} model-guard ${enable ? 'on' : 'off'}`, 5000)
}

export async function modelGuardClear(): Promise<void> {
  await execAsync(`${FLEETMUX_CLI} model-guard clear`, 5000)
}

export function readSessions(): SessionConfig[] {
  try {
    return JSON.parse(readFileSync(SESSIONS_FILE, 'utf-8'))
  } catch {
    return []
  }
}

// ── Tmux State Detection ──────────────────────────────────────────

function tmuxWindowExists(name: string): boolean {
  try {
    const out = execSync(`tmux -S "${TMUX_SOCKET}" list-windows -t ${TMUX_SESSION} -F '#{window_name}' 2>/dev/null`, {
      encoding: 'utf-8',
      timeout: 3000,
      env: EXEC_ENV,
    })
    return out.split('\n').some((line) => line.trim() === name)
  } catch {
    return false
  }
}

export interface SessionInfo {
  state: 'running' | 'idle' | 'stopped'
  activity: string | null
}

export function detectSessionInfo(name: string): SessionInfo {
  if (!tmuxWindowExists(name)) return { state: 'stopped', activity: null }

  try {
    const content = execSync(
      `tmux -S "${TMUX_SOCKET}" capture-pane -t "${TMUX_SESSION}:${name}" -p -S -15 2>/dev/null`,
      { encoding: 'utf-8', timeout: 3000, env: EXEC_ENV },
    )
    if (!content.trim()) return { state: 'idle', activity: null }

    // Check for specific activity patterns (order matters — most specific first)
    if (/Thinking/.test(content)) return { state: 'running', activity: 'Thinking' }
    if (/Reading/.test(content)) return { state: 'running', activity: 'Reading' }
    if (/Writing|Editing/.test(content)) return { state: 'running', activity: 'Writing' }
    if (/Searching/.test(content)) return { state: 'running', activity: 'Searching' }
    if (/Executing/.test(content)) return { state: 'running', activity: 'Executing' }
    if (/Running/.test(content)) return { state: 'running', activity: 'Running' }
    if (/[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]/.test(content)) return { state: 'running', activity: 'Working' }

    // Idle: prompt waiting for input
    if (/^\s*>\s*$/m.test(content) || /waiting for input/.test(content) || /^\$\s*$/m.test(content)) {
      return { state: 'idle', activity: null }
    }

    return { state: 'idle', activity: null }
  } catch {
    return { state: 'stopped', activity: null }
  }
}

export function detectState(name: string): 'running' | 'idle' | 'stopped' {
  return detectSessionInfo(name).state
}

// ── Git Info ──────────────────────────────────────────────────────

export function getGitInfo(repoPath: string): string {
  try {
    if (!existsSync(path.join(repoPath, '.git'))) return '-'
    const branch = execSync(`git -C "${repoPath}" rev-parse --abbrev-ref HEAD 2>/dev/null`, {
      encoding: 'utf-8',
      timeout: 3000,
      env: EXEC_ENV,
    }).trim()
    const dirty = execSync(`git -C "${repoPath}" status --porcelain 2>/dev/null | wc -l`, {
      encoding: 'utf-8',
      timeout: 3000,
      env: EXEC_ENV,
    }).trim()
    const n = parseInt(dirty, 10)
    return n > 0 ? `${branch} (${n} dirty)` : branch
  } catch {
    return '-'
  }
}

export interface GitDetailResult {
  branch: string
  modified: number
  untracked: number
  ahead: number
  behind: number
  lastCommit?: string
  syncStatus: 'synced' | 'ahead' | 'behind' | 'diverged' | 'unknown'
  dirtyFiles?: string[] // actual file paths (status + name)
}

export function getGitDetail(repoPath: string): GitDetailResult | null {
  try {
    if (!existsSync(path.join(repoPath, '.git'))) return null
    const opts = { encoding: 'utf-8' as const, timeout: 5000, env: EXEC_ENV }

    const branch = execSync(`git -C "${repoPath}" rev-parse --abbrev-ref HEAD 2>/dev/null`, opts).trim()

    // Count modified vs untracked separately
    const porcelain = execSync(`git -C "${repoPath}" status --porcelain 2>/dev/null`, opts).trim()
    const lines = porcelain ? porcelain.split('\n') : []
    let modified = 0
    let untracked = 0
    for (const line of lines) {
      if (line.startsWith('??')) untracked++
      else modified++
    }

    // Ahead/behind origin (if tracking branch exists)
    let ahead = 0
    let behind = 0
    try {
      const ab = execSync(
        `git -C "${repoPath}" rev-list --left-right --count HEAD...@{upstream} 2>/dev/null`,
        opts,
      ).trim()
      const [a, b] = ab.split(/\s+/).map(Number)
      ahead = a || 0
      behind = b || 0
    } catch {
      // No upstream configured
    }

    // Last commit time
    let lastCommit: string | undefined
    try {
      lastCommit = execSync(
        `git -C "${repoPath}" log -1 --format=%cI 2>/dev/null`,
        opts,
      ).trim() || undefined
    } catch { /* empty repo */ }

    // Derive sync status
    let syncStatus: GitDetailResult['syncStatus'] = 'unknown'
    if (ahead === 0 && behind === 0) syncStatus = 'synced'
    else if (ahead > 0 && behind === 0) syncStatus = 'ahead'
    else if (ahead === 0 && behind > 0) syncStatus = 'behind'
    else if (ahead > 0 && behind > 0) syncStatus = 'diverged'

    // Capture actual dirty file names (max 20 to keep payload small)
    const dirtyFiles = lines.slice(0, 20).map((l) => l.trim())

    return { branch, modified, untracked, ahead, behind, lastCommit, syncStatus, dirtyFiles: dirtyFiles.length > 0 ? dirtyFiles : undefined }
  } catch {
    return null
  }
}

// ── Async Batch Operations (non-blocking) ────────────────────────

async function getAllWindowNames(): Promise<Set<string>> {
  try {
    const out = await execAsync(`tmux -S "${TMUX_SOCKET}" list-windows -t ${TMUX_SESSION} -F '#{window_name}' 2>/dev/null`, 3000)
    return new Set(out.trim().split('\n').map((l) => l.trim()).filter(Boolean))
  } catch {
    return new Set()
  }
}

async function detectSessionInfoAsync(name: string, windowNames: Set<string>): Promise<SessionInfo> {
  if (!windowNames.has(name)) return { state: 'stopped', activity: null }
  try {
    const content = await execAsync(
      `tmux -S "${TMUX_SOCKET}" capture-pane -t "${TMUX_SESSION}:${name}" -p -S -15 2>/dev/null`, 3000,
    )
    if (!content.trim()) return { state: 'idle', activity: null }
    if (/Thinking/.test(content)) return { state: 'running', activity: 'Thinking' }
    if (/Reading/.test(content)) return { state: 'running', activity: 'Reading' }
    if (/Writing|Editing/.test(content)) return { state: 'running', activity: 'Writing' }
    if (/Searching/.test(content)) return { state: 'running', activity: 'Searching' }
    if (/Executing/.test(content)) return { state: 'running', activity: 'Executing' }
    if (/Running/.test(content)) return { state: 'running', activity: 'Running' }
    if (/[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]/.test(content)) return { state: 'running', activity: 'Working' }
    if (/^\s*>\s*$/m.test(content) || /waiting for input/.test(content) || /^\$\s*$/m.test(content)) {
      return { state: 'idle', activity: null }
    }
    return { state: 'idle', activity: null }
  } catch {
    return { state: 'stopped', activity: null }
  }
}

// Extract live metadata from the tmux pane: token count from statusline,
// model/effort/plan from the startup banner (if still in scrollback).
async function getLiveSessionMeta(name: string, windowNames: Set<string>): Promise<LiveSessionMeta> {
  if (!windowNames.has(name)) return {}
  try {
    // Last 20 lines for statusline tokens + version
    const tail = await execAsync(
      `tmux -S "${TMUX_SOCKET}" capture-pane -t "${TMUX_SESSION}:${name}" -p -S -20 2>/dev/null`, 3000,
    )
    const result: LiveSessionMeta = {}

    // Token count: "366319 tokens" or "1.2M tokens" in the statusline
    const tokMatch = tail.match(/(\d[\d,]*)\s+tokens/)
    if (tokMatch) result.liveTokens = parseInt(tokMatch[1].replace(/,/g, ''), 10)

    // Version: "current: 2.1.109"
    const verMatch = tail.match(/current:\s*([\d.]+)/)
    if (verMatch) result.liveVersion = verMatch[1]

    // Banner search — go deeper into scrollback for model/effort/plan.
    // Only on first detection or when not yet cached (banner is at the top).
    const banner = await execAsync(
      `tmux -S "${TMUX_SOCKET}" capture-pane -t "${TMUX_SESSION}:${name}" -p -S -2000 2>/dev/null | grep -i "effort\\|Claude Code v" | tail -5`, 3000,
    )
    // Pattern: "Opus 4.6 (1M context) with high effort · Claude Max"
    const modelMatch = banner.match(/(Opus|Sonnet|Haiku)\s+([\d.]+)\s*\([^)]+\)\s*with\s+(\w+)\s+effort\s+·\s+(.+)/i)
    if (modelMatch) {
      result.liveModel = `${modelMatch[1]} ${modelMatch[2]}`
      result.liveEffort = modelMatch[3]
      result.livePlan = modelMatch[4].trim()
    }

    return result
  } catch {
    return {}
  }
}

async function getSessionUptimeAsync(name: string, windowNames: Set<string>): Promise<string | null> {
  if (!windowNames.has(name)) return null
  try {
    const created = (await execAsync(
      `tmux -S "${TMUX_SOCKET}" display-message -t "${TMUX_SESSION}:${name}" -p '#{window_activity}' 2>/dev/null`, 3000,
    )).trim()
    if (!created) return null
    const epoch = parseInt(created, 10)
    if (isNaN(epoch)) return null
    const diffS = Math.floor(Date.now() / 1000 - epoch)
    if (diffS < 60) return 'just now'
    if (diffS < 3600) return `${Math.floor(diffS / 60)}m`
    if (diffS < 86400) return `${Math.floor(diffS / 3600)}h ${Math.floor((diffS % 3600) / 60)}m`
    return `${Math.floor(diffS / 86400)}d ${Math.floor((diffS % 86400) / 3600)}h`
  } catch {
    return null
  }
}

async function getGitDetailAsync(repoPath: string): Promise<GitDetailResult | null> {
  try {
    if (!existsSync(path.join(repoPath, '.git'))) return null
    const [branchRaw, porcelainRaw, abRaw, commitRaw] = await Promise.all([
      execAsync(`git -C "${repoPath}" rev-parse --abbrev-ref HEAD 2>/dev/null`).catch(() => ''),
      execAsync(`git -C "${repoPath}" status --porcelain 2>/dev/null`).catch(() => ''),
      execAsync(`git -C "${repoPath}" rev-list --left-right --count HEAD...@{upstream} 2>/dev/null`).catch(() => ''),
      execAsync(`git -C "${repoPath}" log -1 --format=%cI 2>/dev/null`).catch(() => ''),
    ])
    const branch = branchRaw.trim()
    if (!branch) return null
    const lines = porcelainRaw.trim() ? porcelainRaw.trim().split('\n') : []
    let modified = 0, untracked = 0
    for (const line of lines) { if (line.startsWith('??')) untracked++; else modified++ }
    let ahead = 0, behind = 0
    if (abRaw.trim()) {
      const [a, b] = abRaw.trim().split(/\s+/).map(Number)
      ahead = a || 0; behind = b || 0
    }
    const lastCommit = commitRaw.trim() || undefined
    let syncStatus: GitDetailResult['syncStatus'] = 'unknown'
    if (ahead === 0 && behind === 0) syncStatus = 'synced'
    else if (ahead > 0 && behind === 0) syncStatus = 'ahead'
    else if (ahead === 0 && behind > 0) syncStatus = 'behind'
    else if (ahead > 0 && behind > 0) syncStatus = 'diverged'
    const dirtyFiles = lines.slice(0, 20).map((l) => l.trim())
    return { branch, modified, untracked, ahead, behind, lastCommit, syncStatus, dirtyFiles: dirtyFiles.length > 0 ? dirtyFiles : undefined }
  } catch {
    return null
  }
}

// ── Enriched Sessions Cache (async, non-blocking) ────────────────

export interface LiveSessionMeta {
  liveTokens?: number | null
  liveModel?: string | null
  liveEffort?: string | null
  livePlan?: string | null
  liveVersion?: string | null
}

export interface EnrichedSession extends SessionConfig {
  state: 'running' | 'idle' | 'stopped'
  activity: string | null
  gitInfo?: string
  gitDetail?: GitDetailResult
  uptime?: string | null
  lastTask?: { task: string; status: string; dispatched_at: string; completed_at?: string }
  vpsHealth?: { disk?: string; memory?: string; status: 'ok' | 'unreachable' } | null
  accountMeta?: AccountMeta
  usage?: UsageStats
  live?: LiveSessionMeta
}

let enrichedCache: EnrichedSession[] = []
let enrichRefreshing = false

export function getCachedEnrichedSessions(): EnrichedSession[] {
  return enrichedCache
}

export async function refreshEnrichedSessions(): Promise<void> {
  if (enrichRefreshing) return // prevent overlapping refreshes
  enrichRefreshing = true
  try {
    const sessions = readSessions()
    backgroundGitFetch(sessions)
    const allTasks = readTasks(undefined, 1000)
    const windowNames = await getAllWindowNames()
    const accountsManifest = readAccountsManifest()
    const usageCache = readUsageCache()
    const usageBySession = new Map<string, UsageStats>()
    if (usageCache) {
      for (const row of usageCache.sessions) {
        usageBySession.set(row.name, row.usage)
      }
    }

    const enriched = await Promise.all(sessions.map(async (s) => {
      const gitPath = s.type === 'local' ? s.path : s.local_path
      const [info, gitDetail, uptime, live] = await Promise.all([
        detectSessionInfoAsync(s.name, windowNames),
        gitPath ? getGitDetailAsync(gitPath) : Promise.resolve(null),
        detectSessionInfoAsync(s.name, windowNames).then((i) =>
          i.state !== 'stopped' ? getSessionUptimeAsync(s.name, windowNames) : null
        ),
        detectSessionInfoAsync(s.name, windowNames).then((i) =>
          i.state !== 'stopped' ? getLiveSessionMeta(s.name, windowNames) : {}
        ),
      ])
      const sessionTask = allTasks.find((t) => t.session === s.name) || null
      return {
        ...s,
        state: info.state,
        activity: info.activity,
        gitDetail: gitDetail || undefined,
        uptime: uptime || undefined,
        lastTask: sessionTask ? {
          task: sessionTask.task as string,
          status: sessionTask.status as string,
          dispatched_at: sessionTask.dispatched_at as string,
          completed_at: sessionTask.completed_at as string | undefined,
        } : undefined,
        vpsHealth: s.type === 'remote' ? getCachedVpsHealth(s.name) : undefined,
        accountMeta: s.account ? accountsManifest[s.account] : undefined,
        usage: usageBySession.get(s.name),
        live: (live && Object.keys(live).length > 0) ? live : undefined,
      } as EnrichedSession
    }))
    enrichedCache = enriched
  } catch (err) {
    console.error('[enrichment] refresh failed:', err)
  } finally {
    enrichRefreshing = false
  }
}

// ── Session Uptime ───────────────────────────────────────────────

export function getSessionUptime(name: string): string | null {
  try {
    // Get tmux window activity timestamp (epoch)
    const created = execSync(
      `tmux -S "${TMUX_SOCKET}" display-message -t "${TMUX_SESSION}:${name}" -p '#{window_activity}' 2>/dev/null`,
      { encoding: 'utf-8', timeout: 3000, env: EXEC_ENV },
    ).trim()
    if (!created) return null
    const epoch = parseInt(created, 10)
    if (isNaN(epoch)) return null
    const diffS = Math.floor(Date.now() / 1000 - epoch)
    if (diffS < 60) return 'just now'
    if (diffS < 3600) return `${Math.floor(diffS / 60)}m`
    if (diffS < 86400) return `${Math.floor(diffS / 3600)}h ${Math.floor((diffS % 3600) / 60)}m`
    return `${Math.floor(diffS / 86400)}d ${Math.floor((diffS % 86400) / 3600)}h`
  } catch {
    return null
  }
}

// ── Git Fetch Cache (background, 60s) ────────────────────────────

let lastFetchTime = 0
export function backgroundGitFetch(sessions: SessionConfig[]) {
  if (Date.now() - lastFetchTime < 60000) return
  lastFetchTime = Date.now()
  const locals = sessions.filter((s) => s.type === 'local')
  for (const s of locals) {
    if (!existsSync(path.join(s.path, '.git'))) continue
    exec(`git -C "${s.path}" fetch --quiet 2>/dev/null`, { timeout: 15000, env: EXEC_ENV }, () => {})
  }
  // Also fetch local clones of VPS sessions
  const remotes = sessions.filter((s) => s.type === 'remote' && s.local_path)
  for (const s of remotes) {
    if (!existsSync(path.join(s.local_path!, '.git'))) continue
    exec(`git -C "${s.local_path}" fetch --quiet 2>/dev/null`, { timeout: 15000, env: EXEC_ENV }, () => {})
  }
}

// ── Tasks ─────────────────────────────────────────────────────────

export function readTasks(session?: string, limit = 50): Record<string, unknown>[] {
  try {
    let tasks = JSON.parse(readFileSync(TASKS_FILE, 'utf-8'))
    if (session) tasks = tasks.filter((t: Record<string, unknown>) => t.session === session)
    return tasks.slice(0, limit)
  } catch {
    return []
  }
}

export function getLastTaskForSession(sessionName: string): Record<string, unknown> | null {
  try {
    const tasks = JSON.parse(readFileSync(TASKS_FILE, 'utf-8'))
    return tasks.find((t: Record<string, unknown>) => t.session === sessionName) || null
  } catch {
    return null
  }
}

// ── Cached VPS Health ────────────────────────────────────────────

export function getCachedVpsHealth(name: string): { disk?: string; memory?: string; status: 'ok' | 'unreachable' } | null {
  if (!healthCache) return null
  const vps = healthCache.vps.find(v => v.name === name)
  if (!vps) return null
  return { disk: vps.disk, memory: vps.memory, status: vps.status }
}

// ── Logs ──────────────────────────────────────────────────────────

export function captureLogs(name: string, lines = 80): string {
  if (!tmuxWindowExists(name)) return ''
  try {
    return execSync(
      `tmux -S "${TMUX_SOCKET}" capture-pane -t "${TMUX_SESSION}:${name}" -p -S -${lines} 2>/dev/null`,
      { encoding: 'utf-8', timeout: 5000, env: EXEC_ENV },
    )
  } catch {
    return ''
  }
}

// ── fleetmux CLI Wrappers ─────────────────────────────────────────────

export function fleetmuxExec(command: string): Promise<string> {
  return new Promise((resolve, reject) => {
    console.log(`[fleetmux] exec: ${FLEETMUX_CLI} ${command}`)
    exec(`${FLEETMUX_CLI} ${command}`, { timeout: 30000, env: EXEC_ENV }, (err, stdout, stderr) => {
      if (err) {
        console.log(`[fleetmux] error: ${stderr || err.message}`)
        reject(new Error(stderr || err.message))
      } else {
        console.log(`[fleetmux] ok: ${stdout.trim()}`)
        resolve(stdout)
      }
    })
  })
}

export function startSession(name: string) {
  return fleetmuxExec(`start ${name}`)
}

export function stopSession(name: string) {
  return fleetmuxExec(`stop ${name}`)
}

// Shell-escape a string for safe embedding in double quotes
function shellEscape(s: string): string {
  return s.replace(/[\\"$`!]/g, '\\$&')
}

export function dispatchTask(name: string, task: string) {
  return fleetmuxExec(`run ${name} "${shellEscape(task)}"`)
}

export function sshCommand(name: string, command: string) {
  return fleetmuxExec(`ssh ${name} "${shellEscape(command)}"`)
}

// ── Health ─────────────────────────────────────────────────────────

export interface VpsHealthResult {
  name: string
  host: string
  status: 'ok' | 'unreachable'
  uptime?: string
  disk?: string
  memory?: string
  pm2?: string
}

export interface LocalHealthResult {
  name: string
  path: string
  branch: string
  dirty: number
  status: 'ok' | 'missing'
}

function sshCheck(host: string): Promise<{ uptime: string; disk: string; memory: string; pm2: string } | null> {
  return new Promise((resolve) => {
    exec(
      `ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no ${host} "uptime -p 2>/dev/null || uptime; df -h / | tail -1 | awk '{print \\$5}'; free -h 2>/dev/null | awk '/^Mem/{print \\$3,\\$2}' | tr ' ' '/' || echo '-'; pm2 list 2>/dev/null | grep -c online || echo 0"`,
      { timeout: 15000, env: EXEC_ENV },
      (err, stdout) => {
        if (err) { resolve(null); return }
        const lines = stdout.trim().split('\n')
        resolve({
          uptime: lines[0] || '-',
          disk: lines[1] || '-',
          memory: lines[2] || '-',
          pm2: lines[3] || '0',
        })
      },
    )
  })
}

let healthCache: { vps: VpsHealthResult[]; local: LocalHealthResult[]; ts: number } | null = null

export async function getHealth(sessions: SessionConfig[], force = false) {
  if (!force && healthCache && Date.now() - healthCache.ts < 60000) {
    return { vps: healthCache.vps, local: healthCache.local }
  }

  const remotes = sessions.filter((s) => s.type === 'remote')
  const locals = sessions.filter((s) => s.type === 'local')

  const vpsResults = await Promise.all(
    remotes.map(async (s) => {
      const result = await sshCheck(s.host!)
      return {
        name: s.name,
        host: s.host!,
        status: result ? 'ok' as const : 'unreachable' as const,
        ...(result || {}),
      }
    }),
  )

  const localResults = locals.map((s) => {
    const exists = existsSync(s.path)
    const gitInfo = exists ? getGitInfo(s.path) : '-'
    const dirtyMatch = gitInfo.match(/\((\d+) dirty\)/)
    return {
      name: s.name,
      path: s.path,
      branch: gitInfo.replace(/ \(\d+ dirty\)/, ''),
      dirty: dirtyMatch ? parseInt(dirtyMatch[1], 10) : 0,
      status: exists ? 'ok' as const : 'missing' as const,
    }
  })

  healthCache = { vps: vpsResults, local: localResults, ts: Date.now() }
  return { vps: vpsResults, local: localResults }
}
