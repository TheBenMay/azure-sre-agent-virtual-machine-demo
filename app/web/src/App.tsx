import { useCallback, useEffect, useState } from 'react'
import { AnimatePresence, motion } from 'framer-motion'
import { AlertTriangle, MemoryStick } from 'lucide-react'
import { Button } from '@/components/ui/button'
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { getStatus, postErrors, postStressMemory } from './api'
import { useDemoStore, type ActionId } from './store'
import type { StatusResponse } from './types'

interface ActionButtonDef {
  id: ActionId
  label: string
  icon: React.ReactNode
  run: () => Promise<{ message: string }>
}

function App() {
  const { lastAction, inFlight, activityLog, startAction, finishAction } =
    useDemoStore()
  const [status, setStatus] = useState<StatusResponse | null>(null)
  const [sizeMB, setSizeMB] = useState(1024)
  const [durationSec, setDurationSec] = useState(600)

  const refreshStatus = useCallback(() => {
    getStatus()
      .then(setStatus)
      .catch(() => {
        /* status polling is best-effort for the demo */
      })
  }, [])

  useEffect(() => {
    refreshStatus()
    const interval = setInterval(refreshStatus, 3000)
    return () => clearInterval(interval)
  }, [refreshStatus])

  const actions: ActionButtonDef[] = [
    {
      id: 'errors-10',
      label: 'Generate 10 Errors',
      icon: <AlertTriangle className="text-amber-500" />,
      run: async () => {
        const res = await postErrors({ count: 10 })
        return { message: res.message }
      },
    },
    {
      id: 'errors-30',
      label: 'Generate 30 Errors',
      icon: <AlertTriangle className="text-amber-500" />,
      run: async () => {
        const res = await postErrors({ count: 30 })
        return { message: res.message }
      },
    },
  ]

  const handleClick = async (def: ActionButtonDef) => {
    startAction(def.id)
    try {
      const { message } = await def.run()
      finishAction(def.id, def.label, true, message)
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Request failed'
      finishAction(def.id, def.label, false, message)
    } finally {
      refreshStatus()
    }
  }

  const memoryActive = status?.memory.active ?? false
  const maxSizeMB = status?.maxSizeMB
  const maxDurationSec = status?.maxDurationSec ?? 3600

  const sizeValid =
    Number.isInteger(sizeMB) && sizeMB >= 1 && (!maxSizeMB || sizeMB <= maxSizeMB)
  const durationValid =
    Number.isInteger(durationSec) &&
    durationSec >= 1 &&
    durationSec <= maxDurationSec

  const handleMemoryTest = () =>
    handleClick({
      id: 'memory',
      label: `Memory Test (${sizeMB}MB for ${durationSec}s)`,
      icon: null,
      run: async () => {
        const res = await postStressMemory({ sizeMB, durationSec })
        return {
          message: `Allocated ${res.sizeMB}MB, holding for ${res.durationSec}s`,
        }
      },
    })

  return (
    <div className="min-h-svh flex items-center justify-center bg-background p-4 sm:p-8">
      <Card className="w-full max-w-3xl">
        <CardHeader>
          <CardTitle className="text-2xl">SRE Agent Demo Console</CardTitle>
          <CardDescription>
            Simulate Windows Event Log errors and memory pressure so Azure
            Monitor Agent, Log Analytics alerts, and the Azure SRE Agent have
            something real to investigate.
          </CardDescription>
          <div className="flex gap-2 pt-2">
            <Badge variant={memoryActive ? 'default' : 'secondary'}>
              Memory job: {memoryActive ? 'running' : 'idle'}
            </Badge>
          </div>
        </CardHeader>
        <CardContent className="space-y-6">
          <div className="grid grid-cols-2 sm:grid-cols-3 gap-3">
            {actions.map((def) => (
              <motion.div
                key={def.id}
                whileTap={{ scale: 0.95 }}
                transition={{ type: 'spring', stiffness: 400, damping: 20 }}
              >
                <Button
                  className="w-full h-16 flex-col gap-1"
                  variant="outline"
                  disabled={Boolean(inFlight[def.id])}
                  onClick={() => handleClick(def)}
                >
                  {def.icon}
                  <span className="text-xs font-medium">
                    {inFlight[def.id] ? 'Working…' : def.label}
                  </span>
                </Button>
              </motion.div>
            ))}
          </div>

          <div className="rounded-md border p-4 space-y-3">
            <h2 className="text-sm font-semibold flex items-center gap-2">
              <MemoryStick className="size-4 text-violet-500" />
              Memory Test
            </h2>
            <p className="text-sm text-muted-foreground">
              Allocate a specific amount of memory and hold it for a set
              duration.
            </p>
            <div className="flex flex-wrap items-end gap-4">
              <label className="text-sm space-y-1">
                <span className="block font-medium">Amount (MB)</span>
                <input
                  type="number"
                  min={1}
                  max={maxSizeMB}
                  value={Number.isNaN(sizeMB) ? '' : sizeMB}
                  onChange={(e) => setSizeMB(e.target.valueAsNumber)}
                  className="w-32 rounded-md border bg-background px-3 py-2"
                />
              </label>
              <label className="text-sm space-y-1">
                <span className="block font-medium">Hold duration (seconds)</span>
                <input
                  type="number"
                  min={1}
                  max={maxDurationSec}
                  value={Number.isNaN(durationSec) ? '' : durationSec}
                  onChange={(e) => setDurationSec(e.target.valueAsNumber)}
                  className="w-32 rounded-md border bg-background px-3 py-2"
                />
              </label>
              <Button
                disabled={
                  !sizeValid ||
                  !durationValid ||
                  memoryActive ||
                  Boolean(inFlight.memory)
                }
                onClick={handleMemoryTest}
              >
                {inFlight.memory ? 'Working…' : 'Test Memory'}
              </Button>
            </div>
            <p className="text-xs text-muted-foreground">
              Max {maxSizeMB ? `${maxSizeMB} MB` : 'available memory'} (90% of
              system RAM) and {maxDurationSec} seconds.
            </p>
          </div>

          <div>
            <h2 className="text-sm font-semibold text-muted-foreground mb-2">
              Activity{lastAction ? ` · last action: ${lastAction}` : ''}
            </h2>
            <div className="rounded-md border bg-card max-h-72 overflow-y-auto">
              {activityLog.length === 0 ? (
                <p className="text-sm text-muted-foreground p-4">
                  No actions yet. Click a button above to begin the demo.
                </p>
              ) : (
                <ul className="divide-y">
                  <AnimatePresence initial={false}>
                    {activityLog.map((entry) => (
                      <motion.li
                        key={entry.id}
                        initial={{ opacity: 0, height: 0 }}
                        animate={{ opacity: 1, height: 'auto' }}
                        exit={{ opacity: 0, height: 0 }}
                        transition={{ duration: 0.2 }}
                        className="p-3 text-sm flex items-start gap-3"
                      >
                        <Badge
                          variant={entry.success ? 'default' : 'destructive'}
                          className="mt-0.5 shrink-0"
                        >
                          {entry.success ? 'OK' : 'ERR'}
                        </Badge>
                        <div className="min-w-0">
                          <p className="font-medium">{entry.label}</p>
                          <p className="text-muted-foreground break-words">
                            {entry.message}
                          </p>
                          <p className="text-xs text-muted-foreground">
                            {new Date(entry.timestamp).toLocaleTimeString()}
                          </p>
                        </div>
                      </motion.li>
                    ))}
                  </AnimatePresence>
                </ul>
              )}
            </div>
          </div>
        </CardContent>
      </Card>
    </div>
  )
}

export default App
