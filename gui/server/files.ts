/**
 * Filesystem explorer — VS-Code-style tree over ~/Claude_Code/.
 *
 * All paths are sandboxed under FS_ROOT. The API takes relative paths from
 * the root; absolute paths and any `..` segments are rejected.
 *
 * REST:
 *   GET  /api/fs/list?path=<rel>       — one directory level (lazy load)
 *   GET  /api/fs/read?path=<rel>       — file contents (size-capped at 1MB)
 *   POST /api/fs/open    body { path } — opens path in VS Code (`code <abs>`)
 */
import { readdirSync, readFileSync, statSync, existsSync } from 'fs'
import path from 'path'
import { execFile } from 'child_process'

const FS_ROOT = process.env.FS_ROOT || process.env.FLEETMUX_CLAUDE_CODE_ROOT || process.env.HOME || process.cwd()
const MAX_PREVIEW_BYTES = 1024 * 1024  // 1 MB

// Directories we never expand by default — they bloat the tree and are rarely the target.
const ALWAYS_HIDDEN = new Set([
  'node_modules', '.git', 'dist', 'build', '.next', '.turbo', '.cache',
  '.parcel-cache', 'coverage', '.nyc_output', '.pytest_cache', '__pycache__',
  '.venv', 'venv', '.tox', 'target', '.gradle',
])

// Resolve a user-supplied relative path to an absolute path under FS_ROOT.
// Returns null if the path escapes the root.
export function safeResolve(rel: string): string | null {
  // Normalize: strip leading slashes, collapse ../, etc.
  const cleaned = path.posix.normalize('/' + (rel || '').replace(/\\/g, '/')).replace(/^\/+/, '')
  const abs = path.resolve(FS_ROOT, cleaned)
  // Must be inside FS_ROOT (or equal to it).
  const rootWithSep = FS_ROOT.endsWith(path.sep) ? FS_ROOT : FS_ROOT + path.sep
  if (abs !== FS_ROOT && !abs.startsWith(rootWithSep)) return null
  return abs
}

export interface FsEntry {
  name: string
  type: 'dir' | 'file' | 'symlink' | 'other'
  size?: number
  modifiedMs?: number
  isHidden: boolean      // entry begins with `.` or matches ALWAYS_HIDDEN
}

export function listDir(rel: string): FsEntry[] {
  const abs = safeResolve(rel)
  if (!abs || !existsSync(abs)) return []
  let names: string[]
  try {
    names = readdirSync(abs)
  } catch {
    return []
  }
  const entries: FsEntry[] = []
  for (const name of names) {
    const full = path.join(abs, name)
    let st
    try {
      st = statSync(full)
    } catch {
      continue
    }
    let type: FsEntry['type'] = 'other'
    if (st.isDirectory()) type = 'dir'
    else if (st.isFile()) type = 'file'
    else if (st.isSymbolicLink()) type = 'symlink'
    const isHidden = name.startsWith('.') || ALWAYS_HIDDEN.has(name)
    entries.push({
      name,
      type,
      size: type === 'file' ? st.size : undefined,
      modifiedMs: st.mtimeMs,
      isHidden,
    })
  }
  // Dirs first, then files; alphabetical within each group, hidden after non-hidden.
  entries.sort((a, b) => {
    if (a.type !== b.type) {
      if (a.type === 'dir' && b.type !== 'dir') return -1
      if (b.type === 'dir' && a.type !== 'dir') return 1
    }
    if (a.isHidden !== b.isHidden) return a.isHidden ? 1 : -1
    return a.name.localeCompare(b.name)
  })
  return entries
}

export interface FileContent {
  path: string
  size: number
  truncated: boolean
  encoding: 'utf-8' | 'binary'
  content: string         // empty for binary
  language?: string       // best-effort hint for syntax highlighting
}

export function readFile(rel: string): FileContent | null {
  const abs = safeResolve(rel)
  if (!abs || !existsSync(abs)) return null
  let st
  try {
    st = statSync(abs)
  } catch {
    return null
  }
  if (!st.isFile()) return null
  const truncated = st.size > MAX_PREVIEW_BYTES
  const buf = readFileSync(abs, { flag: 'r' })
  const slice = truncated ? buf.subarray(0, MAX_PREVIEW_BYTES) : buf
  // Heuristic binary detection: presence of null byte in first 8KB.
  const sniff = slice.subarray(0, Math.min(slice.length, 8192))
  let isBinary = false
  for (let i = 0; i < sniff.length; i++) {
    if (sniff[i] === 0) { isBinary = true; break }
  }
  return {
    path: rel,
    size: st.size,
    truncated,
    encoding: isBinary ? 'binary' : 'utf-8',
    content: isBinary ? '' : slice.toString('utf-8'),
    language: detectLanguage(rel),
  }
}

function detectLanguage(rel: string): string | undefined {
  const ext = path.extname(rel).slice(1).toLowerCase()
  const base = path.basename(rel).toLowerCase()
  const map: Record<string, string> = {
    ts: 'typescript', tsx: 'tsx', js: 'javascript', jsx: 'jsx', mjs: 'javascript', cjs: 'javascript',
    py: 'python', rb: 'ruby', go: 'go', rs: 'rust', java: 'java', kt: 'kotlin', swift: 'swift',
    sol: 'solidity', sh: 'shell', zsh: 'shell', bash: 'shell', fish: 'shell',
    json: 'json', yaml: 'yaml', yml: 'yaml', toml: 'toml', xml: 'xml', html: 'html', css: 'css', scss: 'scss',
    md: 'markdown', mdx: 'markdown', sql: 'sql', graphql: 'graphql', gql: 'graphql',
    dockerfile: 'dockerfile', tf: 'hcl', hcl: 'hcl',
  }
  if (map[ext]) return map[ext]
  if (base === 'dockerfile' || base.endsWith('.dockerfile')) return 'dockerfile'
  if (base === 'makefile') return 'makefile'
  return undefined
}

export function openInVscode(rel: string): { ok: boolean; error?: string } {
  const abs = safeResolve(rel)
  if (!abs) return { ok: false, error: 'invalid path' }
  if (!existsSync(abs)) return { ok: false, error: 'not found' }
  try {
    // execFile is safer than exec — args are passed as separate argv entries, no shell interpolation.
    execFile('/usr/local/bin/code', [abs], (err) => {
      if (err) {
        // Fallback to PATH lookup if hard-coded path missing.
        execFile('code', [abs])
      }
    })
    return { ok: true }
  } catch (err: unknown) {
    return { ok: false, error: err instanceof Error ? err.message : 'unknown' }
  }
}

export const filesRoot = FS_ROOT
