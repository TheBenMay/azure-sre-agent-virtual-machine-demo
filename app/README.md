# SRE Agent Demo Console — `app/`

A single-page demo web app for a presenter to simulate an incident on a
Windows Server 2022 VM: generate fake "Error" Windows Event Log entries and
hold a chosen amount of memory. Azure Monitor Agent on the VM ships these signals
(Application-log Errors and performance counters) to Log Analytics, where
alert rules fire and an Azure SRE Agent investigates.

This folder contains **only the web app** (frontend + backend). VM
provisioning (registering the `SREDemoApp` event log source, installing
Azure Monitor Agent, etc.) and the Bicep infra/alert rules are separate
workstreams.

## Stack

- **Frontend** (`app/web`): React + TypeScript + Vite, Tailwind CSS,
  shadcn/ui, Framer Motion, Zustand.
- **Backend** (`app/api`): Node.js + TypeScript + Express, serving the
  built frontend as static assets in production (one process, one port).

## Install, build, run

From the `app/` folder (an npm workspaces root covering `web` and `api`):

```powershell
cd app
npm install          # installs dependencies for both web and api
npm run build        # builds the Vite frontend (app/web/dist) and compiles
                      # the Express backend (app/api/dist)
npm start             # runs the compiled Express server, which also serves
                      # app/web/dist as static files
```

The server listens on **port 8080** by default. Override with the `PORT`
environment variable, e.g.:

```powershell
$env:PORT = 9000
npm start
```

Then open `http://localhost:8080/` (or your chosen port) for the demo
console.

### Local development (hot reload)

Run the frontend and backend separately during development:

```powershell
# terminal 1 — Express API on port 8080
npm run dev:api --prefix app

# terminal 2 — Vite dev server with HMR, proxies /api/* to port 8080
npm run dev:web --prefix app
```

## API contract

All responses are JSON. All POST bodies are JSON. The server **always
clamps inputs server-side** regardless of what the client sends.

### `POST /api/errors`

Writes `count` Application-log **Error** entries using custom event source
**`SREDemoApp`**, event ID `9999`, via PowerShell's `Write-EventLog`.

> **VM prerequisite:** The `SREDemoApp` event source must be pre-registered
> on the target VM before this endpoint will actually write real Windows
> Event Log entries:
> ```powershell
> New-EventLog -LogName Application -Source SREDemoApp
> ```
> That registration is handled by a separate VM-provisioning-script
> workstream, not by this app. Without it, `Write-EventLog` fails with a
> `SecurityException` ("The source was not found...") and the endpoint
> returns `500` with that error message.

- Request body: `{ "count": number }` — clamped to **1–50** server-side.
- On Windows (`process.platform === 'win32'`): shells out to
  `powershell.exe` (falling back to `pwsh` if `powershell.exe` isn't
  found) once per entry, sequentially.
- On non-Windows platforms: does **not** shell out; logs a console message
  and returns a simulated success response, so the app can be dev-tested
  off Windows.
- Success response (`200`):
  ```json
  {
    "success": true,
    "requested": 10,
    "written": 10,
    "simulated": false,
    "message": "Wrote 10 Error event(s) to Application log via source \"SREDemoApp\"."
  }
  ```
- Failure response (`500`): `{ "success": false, "error": "<message>" }`

### `POST /api/stress/memory`

Allocates and touches (writes a byte into every 4&nbsp;KB page of) a
`Buffer` of `sizeMB` megabytes, holds it for `durationSec` seconds, then
frees it. Maps to the `% Committed Bytes In Use` performance counter
shipped by Azure Monitor Agent.

- Request body: `{ "sizeMB": number, "durationSec": number }`
  - `sizeMB` clamped to **1–90% of total system memory** (in MB).
  - `durationSec` clamped to **1–3600** (seconds).
- Returns `409` if a memory stress job is already running:
  `{ "success": false, "error": "A memory stress job is already running" }`
- Success response (`200`):
  ```json
  {
    "success": true,
    "sizeMB": 1024,
    "durationSec": 600,
    "bytesAllocated": 1073741824,
    "startedAt": "2026-10-12T17:23:28.055Z",
    "endsAt": "2026-10-12T17:33:28.055Z"
  }
  ```

> Each job is always time-bounded and auto-clears after `durationSec`; no job
> can run unbounded regardless of client input.
### `GET /api/status`

Returns the request limits, whether a memory stress job is currently active and the last
~20 demo actions (in-memory, timestamped).

- Response (`200`):
  ```json
  {
    "maxSizeMB": 29092,
    "maxDurationSec": 3600,
    "memory": {
      "active": true,
      "sizeMB": 1024,
      "durationSec": 600,
      "bytesAllocated": 1073741824,
      "startedAt": "2026-10-12T17:23:28.055Z",
      "endsAt": "2026-10-12T17:24:28.055Z"
    },
    "history": [
      {
        "timestamp": "2026-10-12T17:23:28.055Z",
        "action": "stress-memory",
        "request": { "sizeMB": 1024, "durationSec": 600 },
        "result": { "...": "..." },
        "success": true
      }
    ]
  }
  ```

## Verification performed

- `npm install && npm run build` from `app/` succeeds with **no
  TypeScript errors** in both `app/web` and `app/api`.
- Started the compiled server (`node dist/server.js`, `app/api`) on a test
  port and used `Invoke-RestMethod`/`curl` to confirm:
  - `GET /api/status` returns the expected idle-state JSON shape.
  - `POST /api/errors {count:3}` on this (real, non-provisioned) Windows
    sandbox correctly shells out to `powershell.exe` and surfaces the
    expected `SecurityException` ("source was not found") since
    `SREDemoApp` isn't registered here — confirming the real code path is
    wired correctly; on a VM with the source pre-registered it returns
    `200` instead.
  - `POST /api/stress/memory {sizeMB:256,durationSec:3}` returns `200`
    with the expected fields and auto-clears after the duration.
  - Starting a second memory stress job while one is already running
    returns `409`.
  - Out-of-range inputs (e.g. `count: 999`) are clamped server-side (to
    `50`) regardless of the request body.
  - `GET /` serves the built frontend (`app/web/dist/index.html`).
  - Test server was stopped after verification.
