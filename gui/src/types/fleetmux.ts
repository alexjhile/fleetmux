export interface GitDetail {
  branch: string
  modified: number
  untracked: number
  ahead: number
  behind: number
  lastCommit?: string // ISO date
  syncStatus: 'synced' | 'ahead' | 'behind' | 'diverged' | 'unknown'
  dirtyFiles?: string[]
}

export interface FleetmuxSession {
  name: string
  type: 'local' | 'remote'
  path: string
  host?: string
  local_path?: string
  description: string
  tags: string[]
  autostart: boolean
  claude_flags: string
  state: 'running' | 'idle' | 'stopped'
  activity?: string | null
  lastTask?: {
    task: string
    status: 'dispatched' | 'completed' | 'failed'
    dispatched_at: string
    completed_at?: string
  }
  vpsHealth?: {
    disk?: string
    memory?: string
    status: 'ok' | 'unreachable'
  }
  gitInfo?: string
  gitDetail?: GitDetail
  uptime?: string // how long tmux window has been alive
  account?: string
  accountMeta?: {
    email?: string
    subscription?: string
    updated_at?: string
  }
  usage?: UsageStats
  live?: {
    liveTokens?: number | null
    liveModel?: string | null
    liveEffort?: string | null
    livePlan?: string | null
    liveVersion?: string | null
  }
}

export interface ConversationSummary {
  id: string
  first_prompt: string
  cwd: string | null
  gitBranch: string | null
  version: string | null
  model: string | null
  user_turns: number
  assistant_turns: number
  input_tokens: number
  cache_creation_tokens: number
  cache_creation_5m: number
  cache_creation_1h: number
  cache_read_tokens: number
  output_tokens: number
  total_tokens: number
  effective_tokens: number
  first_ts: string | null
  last_ts: string | null
  is_headless: boolean
}

export interface UsageStats {
  turns: number
  input_tokens: number
  cache_creation_tokens: number
  cache_read_tokens: number
  output_tokens: number
  total_tokens: number
  tokens_5m: number
  tokens_15m: number
  tokens_24h: number
  tokens_48h: number
  tokens_7d: number
  turns_5m: number
  turns_15m: number
  turns_24h: number
  turns_48h: number
  turns_7d: number
  conversations: number
  last_activity: string | null
  buckets?: {
    hourly_total: number[]
    hourly_effective: number[]
    daily_total: number[]
    daily_effective: number[]
  }
  top_conversations?: ConversationSummary[]
}

export interface AccountInfo {
  name: string
  email: string
  subscription: string
  usedBy: string[]
}

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

export interface UsageCache {
  refreshed_at: string | null
  sessions: Array<{
    name: string
    type: string
    account: string
    usage: UsageStats
  }>
}

export interface FleetmuxTask {
  id: string
  session: string
  task: string
  mode: 'run' | 'ssh' | 'exec'
  status: 'dispatched' | 'completed' | 'failed'
  dispatched_at: string
  completed_at: string
  duration_s: string
  output_preview: string
  source: string
}

export interface HealthData {
  vps: VpsHealth[]
  local: LocalHealth[]
}

export interface VpsHealth {
  name: string
  host: string
  status: 'ok' | 'unreachable'
  uptime?: string
  disk?: string
  memory?: string
  pm2?: string
}

export interface LocalHealth {
  name: string
  path: string
  branch: string
  dirty: number
  status: 'ok' | 'missing'
}
