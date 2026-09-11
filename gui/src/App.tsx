import { Routes, Route, useLocation } from 'react-router-dom'
import { useState, useCallback, useEffect } from 'react'
import { Sidebar } from './components/layout/Sidebar'
import { DashboardPage } from './pages/DashboardPage'
import { SessionPage } from './pages/SessionPage'
import { TerminalsPage } from './pages/TerminalsPage'
import { TerminalPopout } from './pages/TerminalPopout'
import { HistoryPage } from './pages/HistoryPage'
import { HealthPage } from './pages/HealthPage'
import { UsagePage } from './pages/UsagePage'
import { AfkWatchPage } from './pages/AfkWatchPage'
import { FilesPage } from './pages/FilesPage'
import { api } from './services/api'
import { usePolling } from './hooks/usePolling'

const TERMINALS_KEY = 'fleetmux-open-terminals'
const ACTIVE_TERMINAL_KEY = 'fleetmux-active-terminal'

export default function App() {
  const location = useLocation()
  const fetchSessions = useCallback(() => api.sessions.list(), [])
  const { data: sessions, refresh } = usePolling(fetchSessions, 3000)

  // Terminal state — persisted in localStorage
  const [openTerminals, setOpenTerminals] = useState<string[]>(() => {
    try {
      const saved = localStorage.getItem(TERMINALS_KEY)
      return saved ? JSON.parse(saved) : []
    } catch { return [] }
  })

  const [activeTerminal, setActiveTerminal] = useState<string | null>(() => {
    try {
      return localStorage.getItem(ACTIVE_TERMINAL_KEY) || null
    } catch { return null }
  })

  // Persist terminal state
  useEffect(() => {
    localStorage.setItem(TERMINALS_KEY, JSON.stringify(openTerminals))
  }, [openTerminals])

  useEffect(() => {
    if (activeTerminal) {
      localStorage.setItem(ACTIVE_TERMINAL_KEY, activeTerminal)
    } else {
      localStorage.removeItem(ACTIVE_TERMINAL_KEY)
    }
  }, [activeTerminal])

  const openTerminal = useCallback((name: string) => {
    setOpenTerminals((prev) => {
      if (prev.includes(name)) return prev
      return [...prev, name]
    })
    setActiveTerminal(name)
  }, [])

  const closeTerminal = useCallback((name: string) => {
    setOpenTerminals((prev) => {
      const next = prev.filter((n) => n !== name)
      // Also update active terminal using the post-removal list (avoids stale closure)
      setActiveTerminal((activePrev) => {
        if (activePrev !== name) return activePrev
        return next.length > 0 ? next[next.length - 1] : null
      })
      return next
    })
  }, [])

  // Pop-out route — standalone, no sidebar
  if (location.pathname.startsWith('/terminal/')) {
    return (
      <Routes>
        <Route path="/terminal/:name" element={<TerminalPopout />} />
      </Routes>
    )
  }

  return (
    <div className="flex h-screen bg-surface">
      <Sidebar
        sessions={sessions || []}
        openTerminalCount={openTerminals.length}
        onOpenTerminal={openTerminal}
      />
      <main className="flex-1 overflow-y-auto p-6">
        <Routes>
          <Route path="/" element={<DashboardPage sessions={sessions || []} onRefresh={refresh} />} />
          <Route path="/session/:name" element={<SessionPage />} />
          <Route
            path="/terminals"
            element={
              <TerminalsPage
                openTerminals={openTerminals}
                activeTerminal={activeTerminal}
                onActivate={setActiveTerminal}
                onClose={closeTerminal}
              />
            }
          />
          <Route path="/history" element={<HistoryPage />} />
          <Route path="/health" element={<HealthPage />} />
          <Route path="/usage" element={<UsagePage />} />
          <Route path="/afk" element={<AfkWatchPage />} />
          <Route path="/files" element={<FilesPage />} />
        </Routes>
      </main>
    </div>
  )
}
