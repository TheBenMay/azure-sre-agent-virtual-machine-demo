/**
 * Shared request/response shapes for the SRE Demo Console API.
 * Keep in sync with app/web/src/types.ts — this is the single source of
 * truth for what the Express backend returns to the frontend.
 */

export interface ErrorsRequest {
  count: number
}

export interface ErrorsResponse {
  success: true
  requested: number
  written: number
  simulated: boolean
  message: string
}

export interface StressMemoryRequest {
  sizeMB: number
  durationSec: number
}

export interface StressMemoryResponse {
  success: true
  sizeMB: number
  durationSec: number
  bytesAllocated: number
  startedAt: string
  endsAt: string
}

export interface ApiErrorResponse {
  success: false
  error: string
}

export interface JobStatus {
  active: boolean
  sizeMB?: number
  durationSec?: number
  startedAt?: string
  endsAt?: string
  bytesAllocated?: number
}

export interface HistoryEntry {
  timestamp: string
  action: string
  request?: unknown
  result: unknown
  success: boolean
}

export interface StatusResponse {
  maxSizeMB: number
  maxDurationSec: number
  memory: JobStatus
  history: HistoryEntry[]
}
