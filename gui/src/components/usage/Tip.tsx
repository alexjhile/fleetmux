import { useState, useRef, useEffect } from 'react'
import { Info } from 'lucide-react'

type Props = {
  info: string
  technical: string
}

export function Tip({ info, technical }: Props) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    const handle = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', handle)
    return () => document.removeEventListener('mousedown', handle)
  }, [open])

  return (
    <span className="relative inline-flex" ref={ref}>
      <button
        onClick={(e) => { e.stopPropagation(); setOpen(!open) }}
        onMouseEnter={() => setOpen(true)}
        className="ml-1 opacity-40 hover:opacity-100 transition-opacity"
        aria-label="More info"
      >
        <Info className="w-3 h-3" />
      </button>

      {open && (
        <div
          className="absolute z-[100] left-1/2 -translate-x-1/2 top-full mt-2 w-[320px] bg-[#1a1d23] border border-border rounded-lg shadow-xl p-0 text-left"
          onClick={(e) => e.stopPropagation()}
        >
          <div className="px-3 py-2 border-b border-border">
            <div className="text-[10px] uppercase text-accent font-semibold mb-1 tracking-wider">Info</div>
            <div className="text-xs text-gray-200 leading-relaxed">{info}</div>
          </div>
          <div className="px-3 py-2">
            <div className="text-[10px] uppercase text-muted font-semibold mb-1 tracking-wider">Technical</div>
            <div className="text-[11px] text-gray-400 leading-relaxed font-mono">{technical}</div>
          </div>
        </div>
      )}
    </span>
  )
}
