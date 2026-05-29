import { useEffect, useState, useCallback } from 'react'
import { ChevronRight, ChevronDown, Folder, FolderOpen, FileText, Eye, EyeOff } from 'lucide-react'
import { api } from '../../services/api'

export interface FsEntry {
  name: string
  type: 'dir' | 'file' | 'symlink' | 'other'
  size?: number
  modifiedMs?: number
  isHidden: boolean
}

interface NodeState {
  entries: FsEntry[] | null  // null = not yet loaded
  loading: boolean
  expanded: boolean
}

interface FileTreeProps {
  selected: string | null
  onSelect: (path: string, isDir: boolean) => void
  showHidden: boolean
  onToggleHidden: () => void
}

export function FileTree({ selected, onSelect, showHidden, onToggleHidden }: FileTreeProps) {
  // path → state. '' = root.
  const [tree, setTree] = useState<Record<string, NodeState>>({ '': { entries: null, loading: false, expanded: true } })

  const loadDir = useCallback(async (relPath: string) => {
    setTree((t) => ({ ...t, [relPath]: { ...(t[relPath] ?? { entries: null, expanded: true }), loading: true } }))
    try {
      const { entries } = await api.fs.list(relPath)
      setTree((t) => ({
        ...t,
        [relPath]: { entries, loading: false, expanded: t[relPath]?.expanded ?? true },
      }))
    } catch {
      setTree((t) => ({ ...t, [relPath]: { entries: [], loading: false, expanded: t[relPath]?.expanded ?? true } }))
    }
  }, [])

  // Load root on mount
  useEffect(() => {
    loadDir('')
  }, [loadDir])

  const toggle = (relPath: string, isDir: boolean) => {
    if (!isDir) {
      onSelect(relPath, false)
      return
    }
    setTree((t) => {
      const cur = t[relPath]
      if (!cur || cur.entries === null) {
        // Load + expand
        loadDir(relPath)
        return { ...t, [relPath]: { entries: null, loading: true, expanded: true } }
      }
      return { ...t, [relPath]: { ...cur, expanded: !cur.expanded } }
    })
    onSelect(relPath, true)
  }

  return (
    <div className="flex flex-col h-full bg-card border border-border rounded overflow-hidden">
      <div className="flex items-center gap-2 px-2 py-1.5 border-b border-border bg-black/20 text-xs">
        <Folder className="w-3.5 h-3.5 text-accent" />
        <span className="font-mono text-[11px] text-muted">~/Claude_Code</span>
        <button
          onClick={onToggleHidden}
          className="ml-auto p-0.5 rounded hover:bg-white/10 text-muted hover:text-white transition-colors"
          title={showHidden ? 'Hide dotfiles + node_modules etc.' : 'Show dotfiles + node_modules etc.'}
        >
          {showHidden ? <Eye className="w-3 h-3" /> : <EyeOff className="w-3 h-3" />}
        </button>
      </div>
      <div className="flex-1 overflow-y-auto py-1 font-mono text-[12px]">
        <TreeLevel
          relPath=""
          tree={tree}
          depth={0}
          selected={selected}
          showHidden={showHidden}
          toggle={toggle}
          loadDir={loadDir}
        />
      </div>
    </div>
  )
}

interface TreeLevelProps {
  relPath: string
  tree: Record<string, NodeState>
  depth: number
  selected: string | null
  showHidden: boolean
  toggle: (path: string, isDir: boolean) => void
  loadDir: (path: string) => Promise<void>
}

function TreeLevel({ relPath, tree, depth, selected, showHidden, toggle, loadDir }: TreeLevelProps) {
  const node = tree[relPath]
  if (!node) return null
  if (node.loading && node.entries === null) {
    return (
      <div className="text-muted text-[10px] pl-2" style={{ paddingLeft: depth * 12 + 8 }}>loading…</div>
    )
  }
  if (!node.entries || node.entries.length === 0) return null
  const visible = showHidden ? node.entries : node.entries.filter((e) => !e.isHidden)
  return (
    <>
      {visible.map((entry) => {
        const childPath = relPath ? `${relPath}/${entry.name}` : entry.name
        const isDir = entry.type === 'dir' || entry.type === 'symlink'
        const childNode = tree[childPath]
        const isSelected = selected === childPath
        return (
          <div key={childPath}>
            <button
              type="button"
              onClick={() => toggle(childPath, isDir)}
              className={`w-full flex items-center gap-1 py-0.5 hover:bg-white/5 text-left ${
                isSelected ? 'bg-accent/15 text-accent' : 'text-gray-300'
              } ${entry.isHidden ? 'opacity-60' : ''}`}
              style={{ paddingLeft: depth * 12 + 4 }}
            >
              {isDir ? (
                childNode?.expanded ? (
                  <ChevronDown className="w-3 h-3 shrink-0 text-muted" />
                ) : (
                  <ChevronRight className="w-3 h-3 shrink-0 text-muted" />
                )
              ) : (
                <span className="w-3 shrink-0" />
              )}
              {isDir ? (
                childNode?.expanded ? (
                  <FolderOpen className="w-3.5 h-3.5 shrink-0 text-accent" />
                ) : (
                  <Folder className="w-3.5 h-3.5 shrink-0 text-accent/80" />
                )
              ) : (
                <FileText className="w-3.5 h-3.5 shrink-0 text-muted" />
              )}
              <span className="truncate">{entry.name}</span>
            </button>
            {isDir && childNode?.expanded ? (
              <TreeLevel
                relPath={childPath}
                tree={tree}
                depth={depth + 1}
                selected={selected}
                showHidden={showHidden}
                toggle={toggle}
                loadDir={loadDir}
              />
            ) : null}
          </div>
        )
      })}
    </>
  )
}
