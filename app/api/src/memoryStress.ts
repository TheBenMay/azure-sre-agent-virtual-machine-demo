import os from 'node:os'

export interface MemoryStressHandle {
  bytesAllocated: number
  stop: () => void
}

const PAGE_SIZE = 4096

/** Largest allocation (in MB) the API accepts: 90% of total system memory. */
export function maxAllocatableMB(): number {
  return Math.max(1, Math.floor((os.totalmem() * 0.9) / (1024 * 1024)))
}

/**
 * Allocates a Buffer of `sizeMB` megabytes and writes into every page so the
 * OS actually commits physical/paged memory behind it (a zero-filled
 * allocation alone may stay as lazily-committed zero pages and not move
 * `% Committed Bytes In Use`). The buffer is held until `stop()` is called
 * (or the caller lets it go out of scope), then freed.
 */
export function startMemoryStress(sizeMB: number): MemoryStressHandle {
  const bytesAllocated = Math.max(1, Math.floor(sizeMB * 1024 * 1024))

  let buffer: Buffer | null = Buffer.alloc(bytesAllocated)
  for (let offset = 0; offset < buffer.length; offset += PAGE_SIZE) {
    buffer[offset] = 1
  }

  return {
    bytesAllocated,
    stop: () => {
      buffer = null
    },
  }
}
