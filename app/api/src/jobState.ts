import type { HistoryEntry, JobStatus } from './types'

const MAX_HISTORY = 20

interface InternalJob extends JobStatus {
  timer?: NodeJS.Timeout
}

/**
 * In-memory tracking of the currently running memory stress job and a
 * short rolling history of recent demo actions. This is intentionally
 * process-local (no database) since the app is a single-process demo tool.
 */
class JobState {
  private memoryJob: InternalJob = { active: false }
  private history: HistoryEntry[] = []

  getMemoryStatus(): JobStatus {
    return this.toPublic(this.memoryJob)
  }

  isMemoryActive(): boolean {
    return this.memoryJob.active
  }

  startMemoryJob(
    sizeMB: number,
    durationSec: number,
    bytesAllocated: number,
    onComplete: () => void
  ): void {
    const startedAt = new Date()
    const endsAt = new Date(startedAt.getTime() + durationSec * 1000)
    this.memoryJob = {
      active: true,
      sizeMB,
      durationSec,
      bytesAllocated,
      startedAt: startedAt.toISOString(),
      endsAt: endsAt.toISOString(),
      timer: setTimeout(() => {
        this.memoryJob = { active: false }
        onComplete()
      }, durationSec * 1000),
    }
  }

  addHistory(entry: HistoryEntry): void {
    this.history.unshift(entry)
    if (this.history.length > MAX_HISTORY) {
      this.history.length = MAX_HISTORY
    }
  }

  getHistory(): HistoryEntry[] {
    return this.history
  }

  private toPublic(job: InternalJob): JobStatus {
    const { timer: _timer, ...publicJob } = job
    return publicJob
  }
}

export const jobState = new JobState()
