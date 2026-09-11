import { useEffect, useState } from 'react'
import { ExternalLink, Copy, Check } from 'lucide-react'
import hljs from 'highlight.js/lib/common'
import 'highlight.js/styles/github-dark.css'
import { api } from '../../services/api'

interface FilePreviewProps {
  relPath: string | null
}

interface FileBody {
  path: string
  size: number
  truncated: boolean
  encoding: 'utf-8' | 'binary'
  content: string
  language?: string
}

export function FilePreview({ relPath }: FilePreviewProps) {
  const [body, setBody] = useState<FileBody | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    if (!relPath) { setBody(null); setError(null); return }
    let cancelled = false
    setLoading(true); setError(null)
    api.fs.read(relPath).then(
      (b) => { if (!cancelled) { setBody(b); setLoading(false) } },
      (e) => { if (!cancelled) { setError(e?.message || 'failed'); setLoading(false) } },
    )
    return () => { cancelled = true }
  }, [relPath])

  if (!relPath) {
    return (
      <div className="h-full flex items-center justify-center text-muted text-sm">
        Select a file in the tree.
      </div>
    )
  }
  if (loading) return <div className="text-muted text-sm p-4">Loading…</div>
  if (error) return <div className="text-error text-sm p-4">Error: {error}</div>
  if (!body) return null

  const baseName = relPath.split('/').pop() || relPath

  if (body.encoding === 'binary') {
    return (
      <PreviewFrame
        relPath={relPath}
        baseName={baseName}
        size={body.size}
        truncated={false}
        copied={copied}
        setCopied={setCopied}
        contentText=""
      >
        <div className="h-full flex items-center justify-center text-muted text-sm">
          Binary file ({fmtSize(body.size)}). Open in editor for full content.
        </div>
      </PreviewFrame>
    )
  }

  let highlighted = body.content
  try {
    if (body.language) {
      highlighted = hljs.highlight(body.content, { language: body.language, ignoreIllegals: true }).value
    } else {
      highlighted = hljs.highlightAuto(body.content).value
    }
  } catch {
    highlighted = escapeHtml(body.content)
  }

  return (
    <PreviewFrame
      relPath={relPath}
      baseName={baseName}
      size={body.size}
      truncated={body.truncated}
      copied={copied}
      setCopied={setCopied}
      contentText={body.content}
    >
      <pre className="m-0 text-[11px] leading-snug font-mono">
        <code className="hljs" dangerouslySetInnerHTML={{ __html: highlighted }} />
      </pre>
    </PreviewFrame>
  )
}

function PreviewFrame({
  relPath, baseName, size, truncated, copied, setCopied, contentText, children,
}: {
  relPath: string
  baseName: string
  size: number
  truncated: boolean
  copied: boolean
  setCopied: (v: boolean) => void
  contentText: string
  children: React.ReactNode
}) {
  const onCopy = () => {
    navigator.clipboard.writeText(contentText).then(() => {
      setCopied(true)
      setTimeout(() => setCopied(false), 1500)
    }).catch(() => {})
  }
  const onOpen = () => {
    api.fs.open(relPath).catch(() => {})
  }
  return (
    <div className="flex flex-col h-full bg-card border border-border rounded overflow-hidden">
      <div className="flex items-center gap-2 px-2 py-1.5 border-b border-border bg-black/20 text-xs">
        <span className="truncate font-mono text-[11px] flex-1" title={relPath}>
          {baseName}
          <span className="text-muted ml-2">{fmtSize(size)}{truncated ? ' · truncated to 1MB' : ''}</span>
        </span>
        <button
          onClick={onCopy}
          className="p-0.5 rounded hover:bg-white/10 text-muted hover:text-white transition-colors"
          title="Copy contents"
        >
          {copied ? <Check className="w-3 h-3 text-success" /> : <Copy className="w-3 h-3" />}
        </button>
        <button
          onClick={onOpen}
          className="p-0.5 rounded hover:bg-white/10 text-muted hover:text-white transition-colors"
          title="Open in VS Code"
        >
          <ExternalLink className="w-3 h-3" />
        </button>
      </div>
      <div className="flex-1 overflow-auto p-2 bg-black/40">
        {children}
      </div>
    </div>
  )
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!))
}

function fmtSize(b: number): string {
  if (b < 1024) return `${b} B`
  if (b < 1024 * 1024) return `${(b / 1024).toFixed(1)} KB`
  return `${(b / 1024 / 1024).toFixed(2)} MB`
}
