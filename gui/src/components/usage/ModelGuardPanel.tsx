import { useEffect, useState } from 'react'
import { Shield, ShieldOff, Trash2 } from 'lucide-react'
import { Tip } from './Tip'

const BASE = !!(window as Record<string, unknown>).__TAURI_INTERNALS__
  ? 'http://localhost:9035/api' : '/api'

interface GuardConfig {
  enabled: boolean
  curve: number
  min_usage: number
  haiku_usage: number
  emergency_usage: number
  restore_usage: number
  restore_hours: number
  // Legacy fields (backwards compat)
  threshold_sonnet?: number
  threshold_haiku?: number
  restore_below?: number
  min_reset_secs?: number
}

interface GuardOverride {
  original_model: string
  current_override: string
  overridden_at: string
  reason?: string
}

interface GuardData {
  config: GuardConfig
  state: Record<string, GuardOverride>
}

export function ModelGuardPanel() {
  const [data, setData] = useState<GuardData | null>(null)

  const load = async () => {
    try {
      const res = await fetch(`${BASE}/model-guard`)
      if (res.ok) setData(await res.json())
    } catch { /* ignore */ }
  }

  useEffect(() => {
    load()
    const t = setInterval(load, 15000)
    return () => clearInterval(t)
  }, [])

  const toggle = async () => {
    if (!data) return
    await fetch(`${BASE}/model-guard/toggle`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ enabled: !data.config.enabled }),
    })
    load()
  }

  const clear = async () => {
    await fetch(`${BASE}/model-guard/clear`, { method: 'POST' })
    load()
  }

  if (!data) return null

  const overrides = Object.entries(data.state)
  const { config } = data

  return (
    <div className="mb-6 p-4 rounded bg-card border border-border">
      <div className="flex items-center justify-between mb-3">
        <div className="flex items-center gap-2">
          {config.enabled ? (
            <Shield className="w-4 h-4 text-green-400" />
          ) : (
            <ShieldOff className="w-4 h-4 text-gray-500" />
          )}
          <span className="text-sm font-semibold">Model Guard</span>
          <Tip
            info="Automatically downgrades Opus → Sonnet when your 5-hour session limit is running high. Restores the original model when usage drops. Runs every 5 minutes after each limits probe. Never uses Haiku."
            technical="Sends '/model sonnet' into running tmux sessions via tmux send-keys. Trigger curve: hours_remaining >= 7.5 × (1 - usage%). At 95%+ forces sonnet regardless. Restores at <40% or <30min to reset. State in model-guard-state.json."
          />
          <span className={`text-[10px] px-1.5 py-0.5 rounded ${config.enabled ? 'bg-green-500/20 text-green-400' : 'bg-gray-500/20 text-gray-400'}`}>
            {config.enabled ? 'active' : 'disabled'}
          </span>
        </div>
        <div className="flex items-center gap-2">
          {overrides.length > 0 && (
            <button
              onClick={clear}
              className="flex items-center gap-1 px-2 py-1 rounded text-xs bg-danger/20 text-danger hover:bg-danger/30"
              title="Restore all sessions to their original model"
            >
              <Trash2 className="w-3 h-3" /> Clear overrides
            </button>
          )}
          <button
            onClick={toggle}
            className={`px-2.5 py-1 rounded text-xs ${config.enabled ? 'bg-gray-500/20 text-gray-300 hover:bg-gray-500/30' : 'bg-green-500/20 text-green-400 hover:bg-green-500/30'}`}
          >
            {config.enabled ? 'Disable' : 'Enable'}
          </button>
        </div>
      </div>

      {/* Graduated curve table */}
      {(() => {
        const curve = config.curve || 7.5
        const minU = config.min_usage || 0.50
        const emergU = config.emergency_usage || 0.95
        const steps = [50, 60, 70, 80, 85, 90, 95].filter((p) => p / 100 >= minU)
        return (
          <div className="mb-2">
            <div className="flex gap-4 flex-wrap text-[10px] text-muted">
              {steps.map((p) => {
                const pf = p / 100
                const hrs = pf >= emergU ? 0 : curve * (1 - pf)
                return (
                  <span key={p} className="whitespace-nowrap">
                    {p}% + {pf >= emergU ? 'any' : `≥${hrs.toFixed(1)}h`} →{' '}
                    <span className="text-yellow-400">sonnet</span>
                    {pf < emergU && (
                      <span className="text-muted"> · &lt;{hrs.toFixed(1)}h → <span className="text-green-400">opus</span></span>
                    )}
                  </span>
                )
              })}
            </div>
            <div className="text-[10px] text-muted mt-1">
              Re-evaluates every 5 min. Auto-restores to Opus when the curve no longer triggers — no separate restore threshold.
            </div>
          </div>
        )
      })()}

      {/* Active overrides */}
      {overrides.length > 0 ? (
        <div className="mt-2">
          <div className="text-[10px] uppercase text-muted mb-1">Active overrides</div>
          {overrides.map(([session, o]) => (
            <div key={session} className="flex items-center gap-2 text-xs py-1 border-t border-border">
              <span className="font-mono text-gray-200">{session}</span>
              <span className="text-muted">was</span>
              <span className="text-purple-300">{o.original_model}</span>
              <span className="text-muted">→ now</span>
              <span className="text-yellow-400 font-medium">{o.current_override}</span>
              {o.reason && <span className="text-muted text-[10px]">({o.reason})</span>}
              <span className="text-muted ml-auto text-[10px]">
                since {new Date(o.overridden_at).toLocaleTimeString()}
              </span>
            </div>
          ))}
        </div>
      ) : (
        <div className="text-[11px] text-muted mt-1">
          No sessions currently overridden. All running at their configured model.
        </div>
      )}
    </div>
  )
}
