import path from 'node:path'
import express, { type NextFunction, type Request, type Response } from 'express'
import { writeEventLogEntries } from './eventLog'
import {
  maxAllocatableMB,
  startMemoryStress,
  type MemoryStressHandle,
} from './memoryStress'
import { jobState } from './jobState'
import { clamp } from './validate'
import type {
  ApiErrorResponse,
  ErrorsRequest,
  ErrorsResponse,
  StatusResponse,
  StressMemoryRequest,
  StressMemoryResponse,
} from './types'

const PORT = Number(process.env.PORT) || 8080
const MAX_DURATION_SEC = 3600
const WEB_DIST_DIR = path.join(__dirname, '..', '..', 'web', 'dist')

const app = express()
app.use(express.json())

let activeMemoryHandle: MemoryStressHandle | null = null

function sendError(res: Response, status: number, error: string): void {
  const body: ApiErrorResponse = { success: false, error }
  res.status(status).json(body)
}

// --- POST /api/errors ------------------------------------------------------
app.post(
  '/api/errors',
  async (req: Request<unknown, unknown, Partial<ErrorsRequest>>, res: Response) => {
    const count = Math.round(clamp(req.body?.count, 1, 50, 10))

    try {
      const result = await writeEventLogEntries(count)
      const response: ErrorsResponse = {
        success: true,
        requested: count,
        written: result.written,
        simulated: result.simulated,
        message: result.message,
      }
      jobState.addHistory({
        timestamp: new Date().toISOString(),
        action: 'generate-errors',
        request: { count },
        result: response,
        success: true,
      })
      res.status(200).json(response)
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Failed to write event log entries'
      jobState.addHistory({
        timestamp: new Date().toISOString(),
        action: 'generate-errors',
        request: { count },
        result: { error: message },
        success: false,
      })
      sendError(res, 500, message)
    }
  }
)

// --- POST /api/stress/memory -------------------------------------------------
app.post(
  '/api/stress/memory',
  (req: Request<unknown, unknown, Partial<StressMemoryRequest>>, res: Response) => {
    if (jobState.isMemoryActive()) {
      sendError(res, 409, 'A memory stress job is already running')
      return
    }

    const sizeMB = Math.round(clamp(req.body?.sizeMB, 1, maxAllocatableMB(), 1024))
    const durationSec = Math.round(clamp(req.body?.durationSec, 1, MAX_DURATION_SEC, 60))

    const handle = startMemoryStress(sizeMB)
    activeMemoryHandle = handle
    jobState.startMemoryJob(sizeMB, durationSec, handle.bytesAllocated, () => {
      activeMemoryHandle?.stop()
      activeMemoryHandle = null
    })

    const status = jobState.getMemoryStatus()
    const response: StressMemoryResponse = {
      success: true,
      sizeMB,
      durationSec,
      bytesAllocated: handle.bytesAllocated,
      startedAt: status.startedAt!,
      endsAt: status.endsAt!,
    }
    jobState.addHistory({
      timestamp: new Date().toISOString(),
      action: 'stress-memory',
      request: { sizeMB, durationSec },
      result: response,
      success: true,
    })
    res.status(200).json(response)
  }
)

// --- GET /api/status ---------------------------------------------------------
app.get('/api/status', (_req: Request, res: Response) => {
  const response: StatusResponse = {
    maxSizeMB: maxAllocatableMB(),
    maxDurationSec: MAX_DURATION_SEC,
    memory: jobState.getMemoryStatus(),
    history: jobState.getHistory(),
  }
  res.status(200).json(response)
})

// --- Static frontend (production) -------------------------------------------
app.use(express.static(WEB_DIST_DIR))
app.get('/*splat', (req: Request, res: Response, next: NextFunction) => {
  if (req.path.startsWith('/api/')) {
    next()
    return
  }
  res.sendFile(path.join(WEB_DIST_DIR, 'index.html'), (err) => {
    if (err) next(err)
  })
})

app.listen(PORT, () => {
  console.log(`SRE demo API listening on port ${PORT}`)
})
