// Anthropic model pricing — USD per million tokens.
// Updated for the Claude 4 series (Sonnet 4 / 4.5 / 4.6, Opus 4 / 4.6, Haiku 4.5).
// Cache multipliers:
//   cache_creation_5m : 1.25 × input
//   cache_creation_1h : 2.00 × input
//   cache_read        : 0.10 × input
//
// These are list-rate approximations for estimating relative burn. On a
// Claude Max / Pro subscription you don't pay per token — the number is
// useful for "if this were API spend, how much".

type ModelRate = {
  input: number
  output: number
  label: string
}

const RATES: Record<string, ModelRate> = {
  'claude-opus-4': { input: 15, output: 75, label: 'Opus 4' },
  'claude-opus-4-5': { input: 15, output: 75, label: 'Opus 4.5' },
  'claude-opus-4-6': { input: 15, output: 75, label: 'Opus 4.6' },
  'claude-sonnet-4': { input: 3, output: 15, label: 'Sonnet 4' },
  'claude-sonnet-4-5': { input: 3, output: 15, label: 'Sonnet 4.5' },
  'claude-sonnet-4-6': { input: 3, output: 15, label: 'Sonnet 4.6' },
  'claude-haiku-4-5': { input: 1, output: 5, label: 'Haiku 4.5' },
}

const DEFAULT_RATE: ModelRate = { input: 3, output: 15, label: 'Sonnet (assumed)' }

function rateFor(model: string | null | undefined): ModelRate {
  if (!model) return DEFAULT_RATE
  // Strip -YYYYMMDD suffix if present
  const base = model.replace(/-\d{8}$/, '').replace(/-latest$/, '')
  return RATES[base] || DEFAULT_RATE
}

export function modelLabel(model: string | null | undefined): string {
  return rateFor(model).label
}

export type TokenBreakdown = {
  input_tokens: number
  cache_creation_5m: number
  cache_creation_1h: number
  cache_read_tokens: number
  output_tokens: number
}

export function estimateCost(model: string | null | undefined, b: TokenBreakdown): number {
  const r = rateFor(model)
  const inputCost = (b.input_tokens / 1_000_000) * r.input
  const cw5mCost = (b.cache_creation_5m / 1_000_000) * r.input * 1.25
  const cw1hCost = (b.cache_creation_1h / 1_000_000) * r.input * 2.0
  const crCost = (b.cache_read_tokens / 1_000_000) * r.input * 0.1
  const outCost = (b.output_tokens / 1_000_000) * r.output
  return inputCost + cw5mCost + cw1hCost + crCost + outCost
}

export function fmtCost(usd: number): string {
  if (usd < 0.01) return '<$0.01'
  if (usd < 1) return `$${usd.toFixed(2)}`
  if (usd < 1000) return `$${usd.toFixed(2)}`
  if (usd < 1_000_000) return `$${(usd / 1000).toFixed(1)}k`
  return `$${(usd / 1_000_000).toFixed(2)}M`
}

export function costBreakdown(model: string | null | undefined, b: TokenBreakdown) {
  const r = rateFor(model)
  return {
    model: r.label,
    input: (b.input_tokens / 1_000_000) * r.input,
    cache_creation_5m: (b.cache_creation_5m / 1_000_000) * r.input * 1.25,
    cache_creation_1h: (b.cache_creation_1h / 1_000_000) * r.input * 2.0,
    cache_read: (b.cache_read_tokens / 1_000_000) * r.input * 0.1,
    output: (b.output_tokens / 1_000_000) * r.output,
  }
}
