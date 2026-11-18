# Azure SRE Agent — Customer Demo

A self-contained demo environment for showing a customer how **Azure SRE Agent** investigates and
recommends fixes for real incidents: a Windows VM running a small web app with buttons to inject
fake error-log entries and hold a chosen amount of memory, wired to Azure Monitor alerts, which Azure SRE Agent
polls and investigates using its own managed identity (no credentials/service principal needed).

**Author:** Ben May

> Every value below (resource group, VM name, workspace, public IP, etc.) comes from
> `infra/main.bicep`'s parameters/defaults — they belong to **your own** deployment, not a
> shared/live one. After deploying, find your actual values with
> `az deployment sub show --name <deployment-name> --query properties.outputs`. See
> [`docs/original-deployment-reference.md`](docs/original-deployment-reference.md) for a
> worked example from one specific past deployment (for illustration only — don't reuse
> those values).

## Architecture

```
┌─────────────────────────────┐      ┌──────────────────────────┐
│  vm-sre-demo-01 (Win2022)    │      │  Log Analytics Workspace │
│  ┌─────────────────────────┐│ AMA  │  law-sre-agent-demo      │
│  │ Demo web app :8080       ││ ───► │  Event / Perf / Heartbeat│
│  │  - Inject N errors       ││      └───────────┬──────────────┘
│  │  - Hold N MB for N sec   ││                  │
│  └─────────────────────────┘│                  ▼
│  System-assigned identity    │      ┌──────────────────────────┐
│                              │      │ Azure Monitor alert rules│
└─────────────────────────────┘      │  - error-count (≥10/5min)│
                                      │  - cpu-high (≥50%/5min)  │
                                      │  - memory-high (≥50%/5m) │
                                      └───────────┬──────────────┘
                                                  │ polled every 1 min
                                                  ▼
                                      ┌──────────────────────────┐
                                      │   Azure SRE Agent         │
                                      │  (Reader RBAC + OBO       │
                                      │   elevation for actions)  │
                                      └──────────────────────────┘
```

## Repo layout

| Folder | Contents |
|---|---|
| `infra/` | Bicep for the resource group, VNet/NSG, VM, Log Analytics + AMA, and alert rules. See [`infra/README.md`](infra/README.md) for parameters and deploy commands. |
| `app/` | The demo web app (Vite/React frontend + Express/TypeScript backend) with error-injection and CPU/memory stress endpoints. See [`app/README.md`](app/README.md). |
| `scripts/` | `Deploy-DemoApp.ps1` / `Install-DemoApp.ps1` (push the app to the VM via Run Command) and `grant-sre-agent-access.ps1` (RBAC for the agent's managed identity). |
| `docs/sre-agent-setup.md` | Step-by-step runbook for creating the Azure SRE Agent itself (manual portal wizard — no Bicep/CLI surface exists for this step) and wiring it to this environment. |
| `docs/vm-alert-responder-instructions.md` | How to generate paste-ready instructions (via `scripts/New-AgentInstructions.ps1`) for the `VM Alert Responder` custom agent required by `docs/sre-agent-setup.md` step (h). |
| `docs/original-deployment-reference.md` | Example values from one specific past deployment — for illustration only, not a template to reuse. |

## Quickstart: deploy the whole thing

```powershell
# 1. Deploy infra (RG, VNet/NSG, VM, Log Analytics, alert rules)
az deployment sub create `
  --location eastus2 `
  --template-file infra/main.bicep `
  --parameters @infra/main.parameters.json `
  --parameters adminPassword='<strong-password>' `
  --parameters vmSize=Standard_D2_v3 osDiskStorageAccountType=StandardSSD_LRS imageSku=2022-datacenter

# 2. Push the demo app onto the VM (installs Node.js, builds, registers a Scheduled Task)
./scripts/Deploy-DemoApp.ps1 -ResourceGroupName rg-sre-agent-demo -VmName vm-sre-demo-01

# 3. Create and wire up the Azure SRE Agent — manual portal step, see docs/sre-agent-setup.md

# 4. Generate your own paste-ready "VM Alert Responder" instructions (see docs/sre-agent-setup.md step (h))
./scripts/New-AgentInstructions.ps1
```

See [`infra/README.md`](infra/README.md) for the full parameter reference and known-working SKU
overrides (the plain defaults hit capacity/image-compatibility errors in this subscription/region).

## Deploying your own copy

This repo is meant to be cloned and redeployed by anyone on the team into **their own**
Azure subscription — nothing here is tied to one specific tenant/subscription:

1. **Pick your subscription**: `az login`, then `az account set --subscription <your-subscription-id>`
   (confirm with `az account show`).
2. **Run the Quickstart above as-is.** The default resource/VM/workspace names
   (`rg-sre-agent-demo`, `vm-sre-demo-01`, `law-sre-agent-demo`, etc.) are safe to reuse
   unchanged as long as you're deploying into your own subscription — see
   [`infra/README.md`](infra/README.md) for the full parameter reference if you want to
   customize anything (region, VM size, thresholds, etc.).
3. **Don't reuse any values from [`docs/original-deployment-reference.md`](docs/original-deployment-reference.md)**
   — that page documents one specific past deployment for illustration only. Always look
   up your own deployment's actual values with
   `az deployment sub show --name <deployment-name> --query properties.outputs`.
4. **After creating the Azure SRE Agent** (step 3/`docs/sre-agent-setup.md`), run
   `./scripts/New-AgentInstructions.ps1` to generate a paste-ready custom-agent
   instructions file scoped to *your* deployment — see
   [`docs/vm-alert-responder-instructions.md`](docs/vm-alert-responder-instructions.md).

## Running the demo

### Option A — Bastion + browser on the VM (preferred)

The app is used **from inside the VM**, at `http://localhost:8080`. You don't need to reach the VM's
public IP or port 8080 from your own machine.

1. In the Azure Portal, open the VM (`vm-sre-demo-01`) → **Connect → Bastion**.
2. Enter the VM's admin username and password and click **Connect**. A browser-based RDP session opens.
3. In the VM, open Microsoft Edge and browse to **`http://localhost:8080`**.
4. Use the UI:
   - **Generate errors** — writes N Error-level entries to the VM's `Application` event log under
     source `SREDemoApp` (default alert threshold: 10 in 5 minutes).
   - **Memory Test** — enter an amount in MB and a hold duration in seconds (e.g. 1024 MB for 600 s;
     max 90% of VM RAM and 3600 s) to allocate and hold that memory.

> Bastion connects through the Azure Portal's own HTTPS session, so it works even when a corporate
> VPN/Global Secure Access tunnel blocks inbound traffic to Azure VM public IPs.
> **Test the Bastion login from the actual presenting machine/network before the live demo.**
### Option B — `az vm run-command` fallback (no Bastion/RDP needed)

```powershell
# Generate 20 errors
$s = "$env:TEMP\trigger-errors.ps1"
'$r = Invoke-RestMethod -Uri "http://localhost:8080/api/errors" -Method Post -Body (@{count=20} | ConvertTo-Json) -ContentType "application/json"; $r | ConvertTo-Json' | Out-File $s -Encoding utf8
az vm run-command invoke -g rg-sre-agent-demo -n vm-sre-demo-01 --command-id RunPowerShellScript --scripts "@$s"

# Hold 4096 MB of memory for 600s
$s2 = "$env:TEMP\trigger-memory.ps1"
'Invoke-RestMethod -Uri "http://localhost:8080/api/stress/memory" -Method Post -Body (@{sizeMB=4096;durationSec=600} | ConvertTo-Json) -ContentType "application/json"' | Out-File $s2 -Encoding utf8
az vm run-command invoke -g rg-sre-agent-demo -n vm-sre-demo-01 --command-id RunPowerShellScript --scripts "@$s2"
```

### Confirm telemetry and alerts fired

```powershell
# Look up your deployment's workspace customer ID and subscription ID
$outputs = az deployment sub show --name main --query properties.outputs -o json | ConvertFrom-Json
$workspaceId = $outputs.logAnalyticsWorkspaceCustomerId.value
$subId = az account show --query id -o tsv

# Confirm events/metrics landed in Log Analytics
az monitor log-analytics query -w $workspaceId `
  --analytics-query "Event | where Source == 'SREDemoApp' | summarize count() by bin(TimeGenerated, 5m) | order by TimeGenerated desc"

# Confirm alert rules actually fired (not just "enabled")
az extension add -n scheduled-query -y   # one-time, non-interactive
$alerts = az rest --method get --url "https://management.azure.com/subscriptions/$subId/providers/Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview" -o json | ConvertFrom-Json
$alerts.value | ForEach-Object { [PSCustomObject]@{ name=$_.name; state=$_.properties.essentials.alertState; condition=$_.properties.essentials.monitorCondition } }
```

> Replace `main` above with whatever `--name` you passed to `az deployment sub create`
> (it defaults to the template file name, `main`, if you didn't pass one).

Both the CPU and memory alerts evaluate/fire within ~5-10 minutes of a sustained breach; the
error-count alert needs its triggering burst to land inside a single 5-minute evaluation window.

### Creating and demoing the SRE Agent itself

This is a **manual, portal-only step** (`https://sre.azure.com`) — there is no documented
Bicep/ARM/CLI path to create the agent resource. Follow [`docs/sre-agent-setup.md`](docs/sre-agent-setup.md)
end-to-end: create the agent, connect the Log Analytics workspace as a Logs source, connect Azure
Monitor as the incident platform, grant the agent **Reader**-level access to `rg-sre-agent-demo` (plus
subscription-scope `Monitoring Contributor` for alert lifecycle), and configure an Incident Response
Plan with **Review** autonomy (recommend-only — the agent must request on-behalf-of elevation before
taking any write action, and only a **Entra ID work/school account** holding **SRE Agent
Administrator** can approve that prompt).

Once an alert fires, the agent should open an investigation thread within ~1-2 minutes (its scanner
polls every minute) and produce a root-cause recommendation correlating the alert, the underlying
logs/metrics, and (if connected) this repo's source.

## Teardown

```powershell
az group delete --name rg-sre-agent-demo --yes --no-wait
```

This removes the VM, networking, Log Analytics workspace, and alert rules. The Azure SRE Agent
resource itself (created separately via the portal) must be deleted independently from
`https://sre.azure.com` or the Azure portal.
