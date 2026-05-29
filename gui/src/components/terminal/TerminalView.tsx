import { useEffect, useRef } from 'react'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { WebLinksAddon } from '@xterm/addon-web-links'
import '@xterm/xterm/css/xterm.css'

interface Props {
  sessionName: string
  isActive?: boolean
}

export function TerminalView({ sessionName, isActive = true }: Props) {
  const containerRef = useRef<HTMLDivElement>(null)
  const termRef = useRef<Terminal | null>(null)
  const wsRef = useRef<WebSocket | null>(null)
  const fitRef = useRef<FitAddon | null>(null)

  useEffect(() => {
    if (!containerRef.current) return

    // Create terminal
    const term = new Terminal({
      cursorBlink: true,
      cursorStyle: 'bar',
      fontSize: 13,
      lineHeight: 1.2,
      fontFamily: '"SF Mono", "Fira Code", "Cascadia Code", Menlo, Consolas, monospace',
      allowProposedApi: true,
      scrollback: 50000,
      theme: {
        background: '#0f1117',
        foreground: '#e4e4e7',
        cursor: '#3b82f6',
        selectionBackground: '#3b82f644',
        black: '#0f1117',
        red: '#ef4444',
        green: '#22c55e',
        yellow: '#eab308',
        blue: '#3b82f6',
        magenta: '#a855f7',
        cyan: '#06b6d4',
        white: '#e4e4e7',
        brightBlack: '#6b7280',
        brightRed: '#f87171',
        brightGreen: '#4ade80',
        brightYellow: '#facc15',
        brightBlue: '#60a5fa',
        brightMagenta: '#c084fc',
        brightCyan: '#22d3ee',
        brightWhite: '#ffffff',
      },
    })

    const fitAddon = new FitAddon()
    term.loadAddon(fitAddon)
    term.loadAddon(new WebLinksAddon())

    term.open(containerRef.current)
    fitAddon.fit()

    termRef.current = term
    fitRef.current = fitAddon

    // WebSocket connection
    const isTauri = !!(window as Record<string, unknown>).__TAURI_INTERNALS__
    const wsProtocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
    const wsUrl = isTauri
      ? `ws://localhost:9035/ws/terminal/${sessionName}`
      : `${wsProtocol}//${window.location.host}/ws/terminal/${sessionName}`

    term.write('\x1b[90mConnecting to session...\x1b[0m\r\n')
    const ws = new WebSocket(wsUrl)
    wsRef.current = ws

    ws.onopen = () => {
      // Send initial terminal size
      ws.send(JSON.stringify({ type: 'resize', cols: term.cols, rows: term.rows }))
    }

    ws.onmessage = (event) => {
      term.write(event.data)
    }

    ws.onclose = () => {
      term.write('\r\n\x1b[31m[Disconnected]\x1b[0m\r\n')
    }

    ws.onerror = () => {
      term.write('\r\n\x1b[31m[Connection error — is the backend running?]\x1b[0m\r\n')
    }

    // Cmd+C (copy) / Cmd+V (paste) — let browser handle these natively
    term.attachCustomKeyEventHandler((event) => {
      // Cmd+C with selection → browser copies to clipboard
      if (event.metaKey && event.key === 'c' && term.hasSelection()) {
        return false // let browser handle
      }
      // Cmd+V → browser paste (onData will send pasted text to PTY)
      if (event.metaKey && event.key === 'v') {
        return false
      }
      // Cmd+A → select all in terminal
      if (event.metaKey && event.key === 'a') {
        term.selectAll()
        return false
      }
      return true // all other keys → send to PTY
    })

    // Terminal input → WebSocket
    term.onData((data) => {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(data)
      }
    })

    // Handle resize
    const resizeObserver = new ResizeObserver(() => {
      fitAddon.fit()
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'resize', cols: term.cols, rows: term.rows }))
      }
    })
    resizeObserver.observe(containerRef.current)

    // Focus terminal
    term.focus()

    return () => {
      resizeObserver.disconnect()
      ws.close()
      term.dispose()
    }
  }, [sessionName])

  // Re-fit terminal when tab becomes active (display:none → display:block)
  useEffect(() => {
    if (isActive && fitRef.current && termRef.current) {
      requestAnimationFrame(() => {
        fitRef.current?.fit()
        termRef.current?.focus()
        // Also send resize to backend so PTY dimensions match
        if (wsRef.current?.readyState === WebSocket.OPEN && termRef.current) {
          wsRef.current.send(JSON.stringify({
            type: 'resize',
            cols: termRef.current.cols,
            rows: termRef.current.rows,
          }))
        }
      })
    }
  }, [isActive])

  return (
    <div
      ref={containerRef}
      className="w-full h-full rounded-lg overflow-hidden border border-border"
      style={{ minHeight: '400px' }}
    />
  )
}
