import { describe, it, expect, vi, beforeEach } from 'vitest'
import { execSync } from 'child_process'
import { readFileSync, existsSync } from 'fs'

// Mock child_process and fs before importing module
vi.mock('child_process', () => ({
  execSync: vi.fn(),
  exec: vi.fn(),
}))

vi.mock('fs', () => ({
  readFileSync: vi.fn(),
  existsSync: vi.fn(),
}))

const mockExecSync = vi.mocked(execSync)
const mockReadFileSync = vi.mocked(readFileSync)
const mockExistsSync = vi.mocked(existsSync)

// Import after mocks are set up
const { readSessions, detectSessionInfo, getGitInfo, getGitDetail, readTasks, getLastTaskForSession, getSessionUptime, captureLogs } = await import('./aios.js')

const SAMPLE_SESSIONS = [
  { name: 'web', type: 'local', path: '/home/you/code/web-app', description: 'Web app', tags: ['core'], autostart: false, claude_flags: '--verbose' },
  { name: 'worker', type: 'remote', path: '/home/deploy/code/worker', host: 'deploy@203.0.113.10', local_path: '/home/you/code/worker', description: 'Worker', tags: [], autostart: true, claude_flags: '--verbose' },
]

describe('readSessions', () => {
  it('returns parsed sessions from file', () => {
    mockReadFileSync.mockReturnValue(JSON.stringify(SAMPLE_SESSIONS))
    const result = readSessions()
    expect(result).toHaveLength(2)
    expect(result[0].name).toBe('web')
    expect(result[1].type).toBe('remote')
  })

  it('returns empty array on file read error', () => {
    mockReadFileSync.mockImplementation(() => { throw new Error('ENOENT') })
    expect(readSessions()).toEqual([])
  })

  it('returns empty array on invalid JSON', () => {
    mockReadFileSync.mockReturnValue('not json')
    expect(readSessions()).toEqual([])
  })
})

describe('detectSessionInfo', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('returns stopped when tmux window does not exist', () => {
    mockExecSync.mockImplementation(() => { throw new Error('no window') })
    expect(detectSessionInfo('missing')).toEqual({ state: 'stopped', activity: null })
  })

  it('returns idle when window exists but pane is empty', () => {
    // First call: tmuxWindowExists (list-windows + grep)
    mockExecSync.mockImplementationOnce(() => 'web\n')
    // Second call: capture-pane
    mockExecSync.mockImplementationOnce(() => '   \n  \n')
    expect(detectSessionInfo('web')).toEqual({ state: 'idle', activity: null })
  })

  it('detects Thinking activity', () => {
    mockExecSync.mockImplementationOnce(() => 'web\n')
    mockExecSync.mockImplementationOnce(() => '⠋ Thinking...\nsome output here')
    expect(detectSessionInfo('web')).toEqual({ state: 'running', activity: 'Thinking' })
  })

  it('detects Reading activity', () => {
    mockExecSync.mockImplementationOnce(() => 'web\n')
    mockExecSync.mockImplementationOnce(() => '⠙ Reading /home/you/foo.ts')
    expect(detectSessionInfo('web')).toEqual({ state: 'running', activity: 'Reading' })
  })

  it('detects Writing/Editing activity', () => {
    mockExecSync.mockImplementationOnce(() => 'web\n')
    mockExecSync.mockImplementationOnce(() => '⠹ Writing to /tmp/test.ts')
    expect(detectSessionInfo('web')).toEqual({ state: 'running', activity: 'Writing' })
  })

  it('detects spinner as Working', () => {
    mockExecSync.mockImplementationOnce(() => 'web\n')
    mockExecSync.mockImplementationOnce(() => '⠋ doing something')
    expect(detectSessionInfo('web')).toEqual({ state: 'running', activity: 'Working' })
  })

  it('detects idle prompt', () => {
    mockExecSync.mockImplementationOnce(() => 'web\n')
    mockExecSync.mockImplementationOnce(() => 'some previous output\n>\n')
    expect(detectSessionInfo('web')).toEqual({ state: 'idle', activity: null })
  })

  it('returns stopped on capture-pane error', () => {
    mockExecSync.mockImplementationOnce(() => 'web\n')
    mockExecSync.mockImplementationOnce(() => { throw new Error('capture failed') })
    expect(detectSessionInfo('web')).toEqual({ state: 'stopped', activity: null })
  })
})

describe('getGitInfo', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('returns dash when no .git directory', () => {
    mockExistsSync.mockReturnValue(false)
    expect(getGitInfo('/some/path')).toBe('-')
  })

  it('returns branch name when clean', () => {
    mockExistsSync.mockReturnValue(true)
    mockExecSync.mockImplementationOnce(() => 'main\n' as any)
    mockExecSync.mockImplementationOnce(() => '0\n' as any)
    expect(getGitInfo('/some/path')).toBe('main')
  })

  it('returns branch with dirty count', () => {
    mockExistsSync.mockReturnValue(true)
    mockExecSync.mockImplementationOnce(() => 'feature-x\n' as any)
    mockExecSync.mockImplementationOnce(() => '3\n' as any)
    expect(getGitInfo('/some/path')).toBe('feature-x (3 dirty)')
  })

  it('returns dash on git error', () => {
    mockExistsSync.mockReturnValue(true)
    mockExecSync.mockImplementation(() => { throw new Error('not a git repo') })
    expect(getGitInfo('/some/path')).toBe('-')
  })
})

describe('getGitDetail', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('returns null when no .git directory', () => {
    mockExistsSync.mockReturnValue(false)
    expect(getGitDetail('/some/path')).toBeNull()
  })

  it('returns full detail for clean repo', () => {
    mockExistsSync.mockReturnValue(true)
    mockExecSync
      .mockImplementationOnce(() => 'main\n' as any)
      .mockImplementationOnce(() => '\n' as any)
      .mockImplementationOnce(() => '0\t0\n' as any)
      .mockImplementationOnce(() => '2026-03-20T14:00:00+11:00\n' as any)
    const result = getGitDetail('/some/path')
    expect(result).toEqual({
      branch: 'main',
      modified: 0,
      untracked: 0,
      ahead: 0,
      behind: 0,
      lastCommit: '2026-03-20T14:00:00+11:00',
      syncStatus: 'synced',
    })
  })

  it('counts modified and untracked separately', () => {
    mockExistsSync.mockReturnValue(true)
    mockExecSync
      .mockImplementationOnce(() => 'dev\n' as any)
      .mockImplementationOnce(() => ' M file1.ts\n?? file2.ts\n M file3.ts\n' as any)
      .mockImplementationOnce(() => '2\t1\n' as any)
      .mockImplementationOnce(() => '2026-03-20T14:00:00+11:00\n' as any)
    const result = getGitDetail('/some/path')
    expect(result?.modified).toBe(2)
    expect(result?.untracked).toBe(1)
    expect(result?.ahead).toBe(2)
    expect(result?.behind).toBe(1)
    expect(result?.syncStatus).toBe('diverged')
    expect(result?.dirtyFiles).toHaveLength(3)
  })

  it('handles no upstream gracefully', () => {
    mockExistsSync.mockReturnValue(true)
    mockExecSync
      .mockImplementationOnce(() => 'main\n' as any)
      .mockImplementationOnce(() => '\n' as any)
      .mockImplementationOnce(() => { throw new Error('no upstream') })
      .mockImplementationOnce(() => '2026-03-20T14:00:00+11:00\n' as any)
    const result = getGitDetail('/some/path')
    expect(result?.ahead).toBe(0)
    expect(result?.behind).toBe(0)
    expect(result?.syncStatus).toBe('synced')
  })
})

describe('readTasks', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  const SAMPLE_TASKS = [
    { id: '1', session: 'web', task: 'test', status: 'completed' },
    { id: '2', session: 'api', task: 'build', status: 'completed' },
    { id: '3', session: 'web', task: 'deploy', status: 'failed' },
  ]

  it('returns all tasks when no session filter', () => {
    mockReadFileSync.mockReturnValue(JSON.stringify(SAMPLE_TASKS))
    expect(readTasks()).toHaveLength(3)
  })

  it('filters by session name', () => {
    mockReadFileSync.mockReturnValue(JSON.stringify(SAMPLE_TASKS))
    const result = readTasks('web')
    expect(result).toHaveLength(2)
    expect(result.every((t) => t.session === 'web')).toBe(true)
  })

  it('respects limit', () => {
    mockReadFileSync.mockReturnValue(JSON.stringify(SAMPLE_TASKS))
    expect(readTasks(undefined, 2)).toHaveLength(2)
  })

  it('returns empty array on read error', () => {
    mockReadFileSync.mockImplementation(() => { throw new Error('ENOENT') })
    expect(readTasks()).toEqual([])
  })
})

describe('getLastTaskForSession', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('returns first matching task', () => {
    const tasks = [
      { id: '1', session: 'api', task: 'newest' },
      { id: '2', session: 'web', task: 'old' },
      { id: '3', session: 'api', task: 'older' },
    ]
    mockReadFileSync.mockReturnValue(JSON.stringify(tasks))
    const result = getLastTaskForSession('api')
    expect(result?.task).toBe('newest')
  })

  it('returns null for unknown session', () => {
    mockReadFileSync.mockReturnValue(JSON.stringify([{ id: '1', session: 'web', task: 'x' }]))
    expect(getLastTaskForSession('nonexistent')).toBeNull()
  })

  it('returns null on read error', () => {
    mockReadFileSync.mockImplementation(() => { throw new Error('ENOENT') })
    expect(getLastTaskForSession('web')).toBeNull()
  })
})

describe('getSessionUptime', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('returns null on tmux error', () => {
    mockExecSync.mockImplementation(() => { throw new Error('no session') })
    expect(getSessionUptime('missing')).toBeNull()
  })

  it('returns null for non-numeric timestamp', () => {
    mockExecSync.mockReturnValue('notanumber\n' as any)
    expect(getSessionUptime('web')).toBeNull()
  })

  it('returns "just now" for recent activity', () => {
    const now = Math.floor(Date.now() / 1000) - 10
    mockExecSync.mockReturnValue(`${now}\n` as any)
    expect(getSessionUptime('web')).toBe('just now')
  })

  it('returns minutes for < 1 hour', () => {
    const thirtyMinAgo = Math.floor(Date.now() / 1000) - 1800
    mockExecSync.mockReturnValue(`${thirtyMinAgo}\n` as any)
    expect(getSessionUptime('web')).toBe('30m')
  })
})

describe('captureLogs', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('returns empty string when window does not exist', () => {
    mockExecSync.mockImplementation(() => { throw new Error('no window') })
    expect(captureLogs('missing')).toBe('')
  })

  it('returns captured output when window exists', () => {
    // First call: tmuxWindowExists (list-windows)
    mockExecSync.mockImplementationOnce(() => 'web\n' as any)
    // Second call: capture-pane
    mockExecSync.mockImplementationOnce(() => 'line1\nline2\nline3\n' as any)
    expect(captureLogs('web')).toBe('line1\nline2\nline3\n')
  })
})

describe('shellEscape (via dispatchTask)', () => {
  // We test the shell escaping indirectly by checking the command passed to exec
  it('escapes dangerous shell characters in task input', async () => {
    const { exec } = await import('child_process')
    const mockExec = vi.mocked(exec)
    // Make exec call the callback with success
    mockExec.mockImplementation((_cmd: any, _opts: any, cb: any) => {
      if (cb) cb(null, 'ok', '')
      return {} as any
    })

    const { dispatchTask } = await import('./aios.js')
    await dispatchTask('web', 'test "quoted" $VAR `backtick` \\backslash')

    expect(mockExec).toHaveBeenCalledWith(
      expect.stringContaining('test \\"quoted\\" \\$VAR \\`backtick\\` \\\\backslash'),
      expect.any(Object),
      expect.any(Function),
    )
  })
})
