import { X, ExternalLink, TerminalSquare } from 'lucide-react'
import { TerminalView } from '../components/terminal/TerminalView'

interface Props {
  openTerminals: string[]
  activeTerminal: string | null
  onActivate: (name: string) => void
  onClose: (name: string) => void
}

export function TerminalsPage({ openTerminals, activeTerminal, onActivate, onClose }: Props) {
  const handlePopout = (name: string) => {
    window.open(
      `/terminal/${name}`,
      `terminal_${name}`,
      'width=960,height=640,menubar=no,toolbar=no,location=no,status=no',
    )
  }

  if (openTerminals.length === 0) {
    return (
      <div className="flex-1 flex items-center justify-center h-full">
        <div className="text-center">
          <TerminalSquare className="w-12 h-12 text-muted mx-auto mb-4" />
          <p className="text-muted mb-2">No terminals open</p>
          <p className="text-xs text-gray-500">
            Click the terminal icon next to any session in the sidebar to open it here
          </p>
        </div>
      </div>
    )
  }

  return (
    <div className="flex flex-col h-full">
      {/* Tab bar */}
      <div className="flex items-center gap-0.5 shrink-0 mb-2 overflow-x-auto">
        {openTerminals.map((name) => (
          <div
            key={name}
            className={`flex items-center gap-1.5 px-3 py-1.5 rounded-t text-sm cursor-pointer select-none ${
              name === activeTerminal
                ? 'bg-card border border-b-0 border-border text-white'
                : 'text-muted hover:text-gray-300 hover:bg-white/5'
            }`}
          >
            <button
              onClick={() => onActivate(name)}
              className="truncate max-w-[140px]"
            >
              {name}
            </button>
            <button
              onClick={() => handlePopout(name)}
              className="p-0.5 rounded hover:bg-white/10 text-muted hover:text-white"
              title="Pop out to new window"
            >
              <ExternalLink className="w-3 h-3" />
            </button>
            <button
              onClick={() => onClose(name)}
              className="p-0.5 rounded hover:bg-white/10 text-muted hover:text-white"
              title="Close terminal"
            >
              <X className="w-3 h-3" />
            </button>
          </div>
        ))}
      </div>

      {/* Terminal panels — all mounted, only active is visible */}
      <div className="flex-1 min-h-0 relative">
        {openTerminals.map((name) => (
          <div
            key={name}
            className="absolute inset-0"
            style={{ display: name === activeTerminal ? 'block' : 'none' }}
          >
            <TerminalView sessionName={name} isActive={name === activeTerminal} />
          </div>
        ))}
      </div>
    </div>
  )
}
