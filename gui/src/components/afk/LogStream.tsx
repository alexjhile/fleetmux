import { useEffect, useRef, useState } from 'react'
import { Play, Pause, Maximize2, Minimize2 } from 'lucide-react'

interface LogStreamProps {
  sessionName: string
  logFile: string
  isRecent: boolean
  onZoom?: () => void
  isZoomed?: boolean
}

const isTauri = !!(window as Record<string, unknown>).__TAURI_INTERNALS__
const WS_BASE = isTauri
  ? 'ws://localhost:9035'
  : `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}`

export function LogStream({ sessionName, logFile, isRecent, onZoom, isZoomed }: LogStreamProps) {
  const containerRef = useRef<HTMLDivElement>(null)
  const wsRef = useRef<WebSocket | null>(null)
  const [paused, setPaused] = useState(false)
  const [connected, setConnected] = useState(false)
  const [autoScroll, setAutoScroll] = useState(true)
  const pausedRef = useRef(paused)
  pausedRef.current = paused

  useEffect(() => {
    const url = `${WS_BASE}/ws/afk-log/${sessionName}/${logFile}`
    const ws = new WebSocket(url)
    wsRef.current = ws

    ws.onopen = () => setConnected(true)
    ws.onclose = () => setConnected(false)
    ws.onerror = () => setConnected(false)
    ws.onmessage = (ev) => {
      if (pausedRef.current) return
      const el = containerRef.current
      if (!el) return
      const data = typeof ev.data === 'string' ? ev.data : ''
      const wasAtBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 40
      const span = document.createElement('span')
      span.textContent = data
      el.appendChild(span)
      // Trim to last ~5000 lines worth (rough — by character count) to bound memory.
      while (el.childNodes.length > 0 && el.textContent && el.textContent.length > 600_000) {
        el.removeChild(el.firstChild!)
      }
      if (wasAtBottom && autoScroll) {
        el.scrollTop = el.scrollHeight
      }
    }

    return () => {
      ws.close()
      wsRef.current = null
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionName, logFile])

  // Detect manual scroll-up to disable auto-scroll until user scrolls back to bottom
  useEffect(() => {
    const el = containerRef.current
    if (!el) return
    const onScroll = () => {
      const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 40
      setAutoScroll(atBottom)
    }
    el.addEventListener('scroll', onScroll)
    return () => el.removeEventListener('scroll', onScroll)
  }, [])

  const streamLabel = logFile.replace(/^feat-/, '').replace(/\.log$/, '')

  return (
    <div className={`flex flex-col bg-card border border-border rounded overflow-hidden ${isZoomed ? 'h-full' : 'h-72'}`}>
      <div className="flex items-center gap-2 px-2 py-1.5 border-b border-border bg-black/20 text-xs">
        <span className={`w-2 h-2 rounded-full shrink-0 ${connected ? (isRecent ? 'bg-success animate-pulse-dot' : 'bg-warning') : 'bg-gray-600'}`} />
        <span className="truncate font-mono text-[11px] flex-1" title={logFile}>{streamLabel}</span>
        <button
          onClick={() => setPaused((p) => !p)}
          className="p-0.5 rounded hover:bg-white/10 text-muted hover:text-white transition-colors"
          title={paused ? 'Resume' : 'Pause'}
        >
          {paused ? <Play className="w-3 h-3" /> : <Pause className="w-3 h-3" />}
        </button>
        {onZoom ? (
          <button
            onClick={onZoom}
            className="p-0.5 rounded hover:bg-white/10 text-muted hover:text-white transition-colors"
            title={isZoomed ? 'Restore' : 'Zoom'}
          >
            {isZoomed ? <Minimize2 className="w-3 h-3" /> : <Maximize2 className="w-3 h-3" />}
          </button>
        ) : null}
      </div>
      <div
        ref={containerRef}
        className="flex-1 overflow-y-auto p-2 font-mono text-[10px] leading-tight whitespace-pre-wrap text-gray-200 bg-black/40"
        style={{ wordBreak: 'break-word' }}
      />
      {paused ? (
        <div className="px-2 py-1 bg-warning/20 text-warning text-[10px] border-t border-warning/30">
          Paused — click play to resume
        </div>
      ) : !autoScroll ? (
        <div className="px-2 py-1 bg-accent/10 text-accent text-[10px] border-t border-accent/20">
          Scroll down to re-enable auto-follow
        </div>
      ) : null}
    </div>
  )
}
