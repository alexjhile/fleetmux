import { useEffect, useState } from 'react'
import { KeyRound, ChevronDown } from 'lucide-react'
import { api } from '../../services/api'
import type { AccountInfo } from '../../types/aios'

// Shared cache — avoid refetching from every card that mounts.
let cachedAccounts: AccountInfo[] | null = null
let pendingFetch: Promise<AccountInfo[]> | null = null

async function loadAccounts(): Promise<AccountInfo[]> {
  if (cachedAccounts) return cachedAccounts
  if (pendingFetch) return pendingFetch
  pendingFetch = api.accounts.list().then((list) => {
    cachedAccounts = list
    pendingFetch = null
    return list
  })
  return pendingFetch
}

export function invalidateAccountCache() {
  cachedAccounts = null
}

type Props = {
  sessionName: string
  currentAccount?: string
  currentEmail?: string
  currentTier?: string
  onChange: () => void
}

export function AccountPicker({ sessionName, currentAccount, currentEmail, currentTier, onChange }: Props) {
  const [accounts, setAccounts] = useState<AccountInfo[]>([])
  const [open, setOpen] = useState(false)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  useEffect(() => {
    if (open && accounts.length === 0) {
      loadAccounts().then(setAccounts).catch(() => setAccounts([]))
    }
  }, [open, accounts.length])

  const apply = async (accountName: string) => {
    setBusy(true)
    setErr(null)
    try {
      await api.accounts.setForSession(sessionName, accountName)
      setOpen(false)
      onChange()
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'Failed')
    } finally {
      setBusy(false)
    }
  }

  const label = currentEmail || currentAccount || 'default auth'
  const tier = currentTier ? ` (${currentTier})` : ''

  return (
    <div className="relative inline-block">
      <button
        onClick={() => setOpen(!open)}
        disabled={busy}
        title="Change Claude account"
        className="flex items-center gap-1 text-[10px] px-1.5 py-0.5 rounded bg-white/5 text-gray-300 hover:bg-white/10 disabled:opacity-50"
      >
        <KeyRound className="w-3 h-3" />
        <span className="truncate max-w-[140px]">{label}{tier}</span>
        <ChevronDown className="w-3 h-3" />
      </button>

      {open && (
        <div className="absolute left-0 top-full mt-1 min-w-[220px] bg-card border border-border rounded shadow-lg z-50">
          <div className="px-2 py-1 text-[10px] uppercase text-muted border-b border-border">
            Claude account
          </div>

          <button
            onClick={() => apply('')}
            className={`block w-full text-left px-2 py-1.5 text-xs hover:bg-white/5 ${
              !currentAccount ? 'bg-white/5 text-accent' : 'text-gray-300'
            }`}
          >
            <span className="font-mono">default</span>
            <span className="text-muted text-[10px] ml-1.5">(stored login)
          </button>

          {accounts.map((a) => (
            <button
              key={a.name}
              onClick={() => apply(a.name)}
              className={`block w-full text-left px-2 py-1.5 text-xs hover:bg-white/5 ${
                currentAccount === a.name ? 'bg-white/5 text-accent' : 'text-gray-300'
              }`}
            >
              <div className="flex items-center justify-between gap-2">
                <span className="font-mono">{a.name}</span>
                {a.subscription && (
                  <span className="text-[10px] px-1 py-0.5 rounded bg-purple-500/20 text-purple-300">
                    {a.subscription}
                  </span>
                )}
              </div>
              {a.email && (
                <div className="text-[10px] text-muted truncate">{a.email}</div>
              )}
            </button>
          ))}

          {err && (
            <div className="px-2 py-1.5 text-[10px] text-danger border-t border-border">{err}</div>
          )}
        </div>
      )}
    </div>
  )
}
