import { useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { FolderTree } from 'lucide-react'
import { FileTree } from '../components/files/FileTree'
import { FilePreview } from '../components/files/FilePreview'

const SHOW_HIDDEN_KEY = 'fleetmux-files-show-hidden'

export function FilesPage() {
  const [params, setParams] = useSearchParams()
  const selected = params.get('path')
  const isDirSelected = params.get('isDir') === '1'
  const [showHidden, setShowHidden] = useState<boolean>(() => localStorage.getItem(SHOW_HIDDEN_KEY) === '1')

  const toggleHidden = () => {
    const next = !showHidden
    setShowHidden(next)
    localStorage.setItem(SHOW_HIDDEN_KEY, next ? '1' : '0')
  }

  const handleSelect = (path: string, isDir: boolean) => {
    setParams({ path, isDir: isDir ? '1' : '0' }, { replace: true })
  }

  return (
    <div className="space-y-3 h-full flex flex-col">
      <div className="flex items-center gap-2">
        <FolderTree className="w-5 h-5 text-accent" />
        <h1 className="text-xl font-bold">Files</h1>
        <span className="text-xs text-muted ml-2">~/Claude_Code/ — read-only browser</span>
      </div>
      <div className="flex-1 grid grid-cols-1 md:grid-cols-[20rem_1fr] gap-3 min-h-0">
        <FileTree
          selected={selected}
          onSelect={handleSelect}
          showHidden={showHidden}
          onToggleHidden={toggleHidden}
        />
        <FilePreview relPath={selected && !isDirSelected ? selected : null} />
      </div>
    </div>
  )
}
