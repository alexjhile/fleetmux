import { Terminal, MessageSquare, Clock, GitBranch, Folder } from 'lucide-react'
import type { ConversationSummary } from '../../types/fleetmux'
import { estimateCost, fmtCost, modelLabel } from './pricing'
import { Tip } from './Tip'

function fmtTokens(n: number): string {
  if (!n || n < 0) return '0'
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(0)}k`
  return String(n)
}

function fmtRelative(iso: string | null): string {
  if (!iso) return '—'
  const t = new Date(iso).getTime()
  if (isNaN(t)) return '—'
  const diff = Date.now() - t
  const s = Math.floor(diff / 1000)
  if (s < 60) return 'just now'
  if (s < 3600) return `${Math.floor(s / 60)}m ago`
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`
  return `${Math.floor(s / 86400)}d ago`
}

type Props = {
  sessionName: string
  sessionPath: string
  conversations?: ConversationSummary[]
}

export function SessionDrillDown({ sessionName, sessionPath, conversations }: Props) {
  if (!conversations || conversations.length === 0) {
    return (
      <div className="p-4 text-xs text-muted bg-surface">
        No conversations found for <span className="font-mono">{sessionName}</span>. If this session has been used,
        try clicking <strong>Refresh</strong> at the top of the page.
      </div>
    )
  }

  return (
    <div className="bg-surface border-t border-border overflow-x-auto">
      <div className="px-4 py-2 flex items-center justify-between min-w-[900px]">
        <div className="text-[11px] uppercase text-muted">
          Top {conversations.length} conversations — sorted by estimated cost
        </div>
        <div className="text-[10px] text-muted flex items-center gap-3">
          <span className="inline-flex items-center gap-1">
            <Terminal className="w-3 h-3" /> headless (claude -p)
          </span>
          <span className="inline-flex items-center gap-1">
            <MessageSquare className="w-3 h-3" /> interactive
          </span>
          <span className="pl-2 border-l border-border">
            cost = list-rate approximation of API spend (Max/Pro = unlimited)
          </span>
        </div>
      </div>

      <table className="w-full text-xs min-w-[900px]">
        <thead>
          <tr className="border-b border-border">
            <th className="text-left px-3 py-1.5 text-[10px] uppercase text-muted w-6"></th>
            <th className="text-left px-2 py-1.5 text-[10px] uppercase text-muted">First prompt</th>
            <th className="text-left px-2 py-1.5 text-[10px] uppercase text-muted">Model</th>
            <th className="text-left px-2 py-1.5 text-[10px] uppercase text-muted">
              CWD
              <Tip
                info="The working directory Claude was launched from. Highlighted yellow if it differs from the session's configured path — means cross-project work."
                technical="From .cwd field on the first message in the JSONL file. Claude Code records the CWD at invocation time."
              />
            </th>
            <th className="text-right px-2 py-1.5 text-[10px] uppercase text-muted">
              U/A
              <Tip
                info="User turns / Assistant turns. Higher numbers = longer interactive conversation. A headless (claude -p) call typically has 1/1."
                technical="Count of messages with type='user' (excluding sidechain/subagent) and type='assistant' in the conversation JSONL."
              />
            </th>
            <th className="text-right px-2 py-1.5 text-[10px] uppercase text-muted">
              Input
              <Tip
                info="Fresh input tokens — the new text you send to Claude each turn (your message + tool results). Usually a small number because most context is cached."
                technical="Sum of .message.usage.input_tokens across all assistant messages. Priced at full model rate ($3/M Sonnet, $15/M Opus)."
              />
            </th>
            <th className="text-right px-2 py-1.5 text-[10px] uppercase text-muted">
              C-Write
              <Tip
                info="Cache creation tokens — Claude caching your conversation history so it doesn't re-read everything from scratch. Costs 1.25x-2x input rate but saves money long-term."
                technical="Sum of cache_creation_input_tokens. Split into 5-min TTL (1.25x input rate) and 1-hour TTL (2x input rate). Hover the cell to see the split. Cached context is re-used via C-Read on subsequent turns."
              />
            </th>
            <th className="text-right px-2 py-1.5 text-[10px] uppercase text-muted">
              C-Read
              <Tip
                info="Cache read tokens — Claude re-reading previously cached conversation history. This is cheap (~10% of input rate) but dominates the total count in long sessions."
                technical="Sum of cache_read_input_tokens. Priced at 0.1x the model's input rate. A 400M-token session might be 97% cache_read — that's ~$60 in reads vs ~$600 if it were fresh input."
              />
            </th>
            <th className="text-right px-2 py-1.5 text-[10px] uppercase text-muted">
              Output
              <Tip
                info="Assistant output tokens — Claude's responses, tool calls, and code. This is the most expensive token type (5x input rate for Sonnet, 5x for Opus)."
                technical="Sum of .message.usage.output_tokens. Priced at $15/M (Sonnet), $75/M (Opus), $5/M (Haiku). Includes all text, tool_use JSON, and thinking content."
              />
            </th>
            <th className="text-right px-2 py-1.5 text-[10px] uppercase text-muted">
              Cost
              <Tip
                info="Estimated USD cost if this were billed at API list rates. On Max/Pro subscriptions you don't actually pay per token — this shows relative burn weight across conversations."
                technical="Formula: (input × model_input_rate) + (cache_write_5m × rate × 1.25) + (cache_write_1h × rate × 2.0) + (cache_read × rate × 0.1) + (output × model_output_rate). Model auto-detected from JSONL assistant messages."
              />
            </th>
            <th className="text-right px-4 py-1.5 text-[10px] uppercase text-muted">Last</th>
          </tr>
        </thead>
        <tbody>
          {conversations.map((c) => {
            const cwdDifferent = c.cwd && c.cwd !== sessionPath
            const cost = estimateCost(c.model, c)
            return (
              <tr key={c.id} className="border-b border-border hover:bg-white/5">
                <td className="px-3 py-1.5">
                  {c.is_headless ? (
                    <Terminal className="w-3.5 h-3.5 text-purple-400" aria-label="headless" />
                  ) : (
                    <MessageSquare className="w-3.5 h-3.5 text-cyan-400" aria-label="interactive" />
                  )}
                </td>
                <td className="px-2 py-1.5">
                  <div className="text-gray-200 truncate max-w-[360px]" title={c.first_prompt}>
                    {c.first_prompt || '(no prompt captured)'}
                  </div>
                  <div className="text-[10px] text-muted font-mono">
                    {c.id.substring(0, 8)}
                    {c.version && <span className="ml-2">cc v{c.version}</span>}
                  </div>
                </td>
                <td className="px-2 py-1.5">
                  <div className="text-gray-300 text-[10px]">{modelLabel(c.model)}</div>
                </td>
                <td className="px-2 py-1.5">
                  {c.cwd && (
                    <div
                      className={`flex items-center gap-1 text-[10px] truncate max-w-[180px] ${cwdDifferent ? 'text-yellow-400' : 'text-muted'}`}
                      title={cwdDifferent ? `CWD differs: ${c.cwd}` : c.cwd}
                    >
                      <Folder className="w-3 h-3 shrink-0" />
                      <span className="truncate">{c.cwd.replace(/^\/(?:Users|home)\/[^/]+\//, '~/')}</span>
                    </div>
                  )}
                  {c.gitBranch && (
                    <div className="flex items-center gap-1 text-[10px] text-muted">
                      <GitBranch className="w-3 h-3 shrink-0" />
                      <span>{c.gitBranch}</span>
                    </div>
                  )}
                </td>
                <td className="px-2 py-1.5 text-right tabular-nums text-muted">
                  {c.user_turns}/{c.assistant_turns}
                </td>
                <td className="px-2 py-1.5 text-right tabular-nums text-gray-300">
                  {fmtTokens(c.input_tokens)}
                </td>
                <td className="px-2 py-1.5 text-right tabular-nums text-gray-300" title={`5m: ${fmtTokens(c.cache_creation_5m)}, 1h: ${fmtTokens(c.cache_creation_1h)}`}>
                  {fmtTokens(c.cache_creation_tokens)}
                </td>
                <td className="px-2 py-1.5 text-right tabular-nums text-muted">
                  {fmtTokens(c.cache_read_tokens)}
                </td>
                <td className="px-2 py-1.5 text-right tabular-nums text-gray-300 font-medium">
                  {fmtTokens(c.output_tokens)}
                </td>
                <td className="px-2 py-1.5 text-right tabular-nums text-green-400 font-medium">
                  {fmtCost(cost)}
                </td>
                <td className="px-4 py-1.5 text-right text-muted">
                  <div className="flex items-center gap-1 justify-end whitespace-nowrap">
                    <Clock className="w-3 h-3" />
                    {fmtRelative(c.last_ts)}
                  </div>
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>

      <div className="px-4 py-2 border-t border-border text-[10px] text-muted">
        <strong className="text-gray-300">Pricing basis:</strong>{' '}
        Input × model rate · Cache-Write 5m × 1.25 · Cache-Write 1h × 2.0 · Cache-Read × 0.10 · Output × model output rate.{' '}
        Sonnet 4.x ≈ $3/M in, $15/M out · Opus 4.x ≈ $15/M in, $75/M out · Haiku 4.5 ≈ $1/M in, $5/M out.
      </div>
    </div>
  )
}
