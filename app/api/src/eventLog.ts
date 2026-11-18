import { execFile } from 'node:child_process'

const EVENT_SOURCE = 'SREDemoApp'
const EVENT_ID = 9999

export interface WriteEventLogResult {
  written: number
  simulated: boolean
  message: string
}

function execFileAsync(
  file: string,
  args: string[]
): Promise<{ stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    execFile(
      file,
      args,
      { windowsHide: true, timeout: 15_000 },
      (error, stdout, stderr) => {
        if (error) {
          reject(new Error(stderr?.toString().trim() || error.message))
          return
        }
        resolve({ stdout: stdout.toString(), stderr: stderr.toString() })
      }
    )
  })
}

function buildWriteEventLogArgs(message: string): string[] {
  // Single-quote PowerShell string literal; escape embedded single quotes by doubling them.
  const escaped = message.replace(/'/g, "''")
  const command = `Write-EventLog -LogName Application -Source '${EVENT_SOURCE}' -EventId ${EVENT_ID} -EntryType Error -Message '${escaped}'`
  return ['-NoProfile', '-NonInteractive', '-Command', command]
}

/**
 * Writes a single Error entry via whichever PowerShell executable is
 * available, preferring Windows PowerShell (`powershell.exe`) and falling
 * back to PowerShell 7+ (`pwsh`) if that's what's installed on the VM.
 */
async function writeOneEntry(message: string): Promise<void> {
  const args = buildWriteEventLogArgs(message)
  try {
    await execFileAsync('powershell.exe', args)
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code
    if (code === 'ENOENT') {
      await execFileAsync('pwsh', args)
      return
    }
    throw err
  }
}

/**
 * Writes `count` Application-log Error entries using the custom event
 * source `SREDemoApp` by shelling out to PowerShell's `Write-EventLog`.
 *
 * IMPORTANT: The `SREDemoApp` event source must already be registered on
 * the target VM before this will succeed for real, e.g.:
 *   New-EventLog -LogName Application -Source SREDemoApp
 * That registration is handled by a separate VM-provisioning-script
 * workstream — this app only depends on it existing, it does not create it.
 */
export async function writeEventLogEntries(
  count: number
): Promise<WriteEventLogResult> {
  // Only shell out to PowerShell on Windows. On other platforms (e.g. so
  // this app can be dev-tested on macOS/Linux), simulate success instead.
  if (process.platform !== 'win32') {
    console.log(
      `[errors] Non-Windows platform ("${process.platform}") detected; ` +
        `simulating ${count} Application-log Error event(s) for source "${EVENT_SOURCE}" ` +
        'instead of invoking Write-EventLog.'
    )
    return {
      written: count,
      simulated: true,
      message: `Simulated ${count} Error event(s) for source "${EVENT_SOURCE}" (non-Windows dev environment).`,
    }
  }

  for (let i = 0; i < count; i += 1) {
    const message = `SRE Demo: simulated error #${i + 1} of ${count} generated at ${new Date().toISOString()}`
    // eslint-disable-next-line no-await-in-loop -- entries must be written sequentially
    await writeOneEntry(message)
  }

  return {
    written: count,
    simulated: false,
    message: `Wrote ${count} Error event(s) to Application log via source "${EVENT_SOURCE}".`,
  }
}
