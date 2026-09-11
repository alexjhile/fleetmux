import { useEffect } from 'react'
import { useParams } from 'react-router-dom'
import { TerminalView } from '../components/terminal/TerminalView'

export function TerminalPopout() {
  const { name } = useParams<{ name: string }>()

  useEffect(() => {
    document.title = `fleetmux — ${name}`
  }, [name])

  return (
    <div className="h-screen w-screen bg-surface p-2">
      <TerminalView sessionName={name!} />
    </div>
  )
}
