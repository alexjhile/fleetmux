import { useState, useEffect } from 'react'
import { Link, useLocation, useNavigate } from 'react-router-dom'
import { LayoutDashboard, History, Activity, Monitor, Server, GripVertical, TerminalSquare, ExternalLink, Zap, Eye, FolderTree } from 'lucide-react'
import { api } from '../../services/api'
import {
  DndContext,
  closestCenter,
  PointerSensor,
  useSensor,
  useSensors,
  type DragEndEvent,
} from '@dnd-kit/core'
import {
  SortableContext,
  verticalListSortingStrategy,
  useSortable,
  arrayMove,
} from '@dnd-kit/sortable'
import { CSS } from '@dnd-kit/utilities'
import type { AiosSession } from '../../types/aios'

const STORAGE_KEY = 'aios-sidebar-order'

const stateColors = {
  running: 'bg-success',
  idle: 'bg-warning',
  stopped: 'bg-gray-600',
}

function SortableSession({
  session,
  isActive,
  onOpenTerminal,
}: {
  session: AiosSession
  isActive: boolean
  onOpenTerminal: (name: string) => void
}) {
  const {
    attributes,
    listeners,
    setNodeRef,
    transform,
    transition,
    isDragging,
  } = useSortable({ id: session.name })

  const style = {
    transform: CSS.Transform.toString(transform),
    transition,
    opacity: isDragging ? 0.5 : 1,
    zIndex: isDragging ? 10 : undefined,
  }

  return (
    <div ref={setNodeRef} style={style} className="flex items-center group">
      <div
        {...attributes}
        {...listeners}
        className="shrink-0 w-4 flex items-center justify-center cursor-grab active:cursor-grabbing opacity-0 group-hover:opacity-50 hover:!opacity-100 transition-opacity"
      >
        <GripVertical className="w-3 h-3 text-muted" />
      </div>
      <Link
        to={`/session/${session.name}`}
        onClick={() => {
          // Switch main Terminal.app to this session's tmux window
          api.sessions.attach(session.name).catch(() => {})
        }}
        className={`flex-1 flex items-center gap-2 px-2 py-1.5 rounded text-sm ${
          isActive
            ? 'bg-accent/20 text-accent'
            : 'text-gray-300 hover:text-white hover:bg-white/5'
        }`}
      >
        <span className={`w-2 h-2 rounded-full shrink-0 ${stateColors[session.state]} ${session.state === 'running' ? 'animate-pulse-dot' : ''}`} />
        {session.type === 'remote' ? (
          <span className="text-[10px] font-bold shrink-0 w-6" style={{ color: '#c084fc' }}>rem</span>
        ) : (
          <span className="text-[10px] font-bold shrink-0 w-6" style={{ color: '#22d3ee' }}>loc</span>
        )}
        <span className="truncate">{session.name}</span>
      </Link>
      <button
        onClick={async (e) => {
          e.preventDefault()
          e.stopPropagation()
          // Auto-start if stopped, then popout to Terminal.app
          if (session.state === 'stopped') {
            await api.sessions.start(session.name).catch(() => {})
            // Wait for tmux window to be created before popout
            await new Promise((r) => setTimeout(r, 1500))
          }
          api.sessions.popout(session.name).catch(() => {})
        }}
        className="shrink-0 p-1 rounded opacity-0 group-hover:opacity-60 hover:!opacity-100 hover:bg-white/10 transition-opacity"
        title={session.state === 'stopped' ? 'Start + open in Terminal.app' : 'Open in Terminal.app'}
      >
        <ExternalLink className="w-3.5 h-3.5 text-muted" />
      </button>
      <button
        onClick={(e) => {
          e.preventDefault()
          e.stopPropagation()
          onOpenTerminal(session.name)
        }}
        className="shrink-0 p-1 rounded opacity-0 group-hover:opacity-60 hover:!opacity-100 hover:bg-white/10 transition-opacity"
        title="Open in browser terminal"
      >
        <TerminalSquare className="w-3.5 h-3.5 text-muted" />
      </button>
    </div>
  )
}

interface SidebarProps {
  sessions: AiosSession[]
  openTerminalCount: number
  onOpenTerminal: (name: string) => void
}

export function Sidebar({ sessions, openTerminalCount, onOpenTerminal }: SidebarProps) {
  const location = useLocation()
  const navigate = useNavigate()
  const running = sessions.filter((s) => s.state === 'running').length
  const idle = sessions.filter((s) => s.state === 'idle').length

  // Load saved order from localStorage
  const [order, setOrder] = useState<string[]>(() => {
    try {
      const saved = localStorage.getItem(STORAGE_KEY)
      return saved ? JSON.parse(saved) : []
    } catch {
      return []
    }
  })

  // Sort sessions by saved order, new sessions go to end
  const sortedSessions = [...sessions].sort((a, b) => {
    const ai = order.indexOf(a.name)
    const bi = order.indexOf(b.name)
    if (ai === -1 && bi === -1) return 0
    if (ai === -1) return 1
    if (bi === -1) return -1
    return ai - bi
  })

  // Persist order to localStorage
  useEffect(() => {
    if (order.length > 0) {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(order))
    }
  }, [order])

  const sensors = useSensors(
    useSensor(PointerSensor, {
      activationConstraint: { distance: 5 },
    }),
  )

  const handleDragEnd = (event: DragEndEvent) => {
    const { active, over } = event
    if (!over || active.id === over.id) return

    const names = sortedSessions.map((s) => s.name)
    const oldIndex = names.indexOf(active.id as string)
    const newIndex = names.indexOf(over.id as string)
    const newOrder = arrayMove(names, oldIndex, newIndex)
    setOrder(newOrder)
  }

  const handleOpenTerminal = (name: string) => {
    onOpenTerminal(name)
    navigate('/terminals')
  }

  return (
    <aside className="w-56 bg-card border-r border-border flex flex-col h-full shrink-0">
      {/* Header */}
      <div className="p-4 border-b border-border">
        <h1 className="text-lg font-bold tracking-tight">fleetmux</h1>
        <p className="text-xs text-muted mt-0.5">
          {running} running, {idle} idle
        </p>
      </div>

      {/* Nav */}
      <nav className="p-2 space-y-0.5">
        {[
          { to: '/', icon: LayoutDashboard, label: 'Dashboard' },
          { to: '/terminals', icon: TerminalSquare, label: 'Terminals', badge: openTerminalCount },
          { to: '/afk', icon: Eye, label: 'AFK' },
          { to: '/files', icon: FolderTree, label: 'Files' },
          { to: '/usage', icon: Zap, label: 'Usage' },
          { to: '/history', icon: History, label: 'History' },
          { to: '/health', icon: Activity, label: 'Health' },
        ].map(({ to, icon: Icon, label, badge }) => (
          <Link
            key={to}
            to={to}
            className={`flex items-center gap-2 px-3 py-1.5 rounded text-sm ${
              location.pathname === to ? 'bg-accent/20 text-accent' : 'text-muted hover:text-white hover:bg-white/5'
            }`}
          >
            <Icon className="w-4 h-4" />
            {label}
            {badge ? (
              <span className="ml-auto text-[10px] bg-accent/20 text-accent px-1.5 py-0.5 rounded-full font-medium">
                {badge}
              </span>
            ) : null}
          </Link>
        ))}
      </nav>

      {/* Sessions list — draggable */}
      <div className="flex-1 overflow-y-auto p-2 border-t border-border mt-2">
        <p className="px-3 py-1 text-xs font-semibold text-muted uppercase tracking-wider">Sessions</p>
        <DndContext sensors={sensors} collisionDetection={closestCenter} onDragEnd={handleDragEnd}>
          <SortableContext items={sortedSessions.map((s) => s.name)} strategy={verticalListSortingStrategy}>
            {sortedSessions.map((s) => (
              <SortableSession
                key={s.name}
                session={s}
                isActive={location.pathname === `/session/${s.name}`}
                onOpenTerminal={handleOpenTerminal}
              />
            ))}
          </SortableContext>
        </DndContext>
      </div>
    </aside>
  )
}
