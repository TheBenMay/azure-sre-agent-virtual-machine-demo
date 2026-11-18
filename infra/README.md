# Infra: Networking + VM + Monitoring + Alerts (Azure SRE Agent demo)

This folder contains the full Bicep stack for the Azure SRE Agent virtual machine demo: a
VNet/subnet/NSG, a Windows Server 2022 VM (with a system-assigned managed identity) running the demo
web app, a Log Analytics Workspace + Data Collection Rule/Endpoint + Azure Monitor Agent extension,
three Azure Monitor alert rules (error-count, CPU, memory), and (by default) an Azure Bastion host for
portal-based RDP access (the only way in — the NSG allows no inbound internet traffic). The Azure SRE
Agent resource itself is **not** included here — it has no
documented Bicep/ARM/CLI surface and must be created via the https://sre.azure.com portal wizard
(see `docs/sre-agent-setup.md`).

## Layout

```
infra/
  main.bicep                 # subscription-scoped entrypoint: creates the RG and deploys all modules into it
  main.parameters.json        # example parameters file (placeholders for secrets — see below)
  modules/
    networking.bicep          # VNet + subnet + NSG (no inbound allow rules; access is via Bastion), plus AzureBastionSubnet when deployBastion is true
    vm.bicep                  # Windows Server 2022 VM (SystemAssigned identity), public IP, NIC, boot diagnostics
    monitoring.bicep          # Log Analytics Workspace, DCE/DCR, Azure Monitor Agent (AMA) extension
    alerts.bicep              # error-count / CPU / memory scheduledQueryRules + metricAlerts
    bastion.bicep              # Azure Bastion (Basic SKU) + its Standard public IP — only deployed when deployBastion is true
```

## Parameters (`main.bicep`)

| Parameter | Required | Default | Notes |
|---|---|---|---|
| `location` | no | `eastus2` | Azure region for all resources. The live demo deployment used `eastus2` |
| `resourceGroupName` | no | `rg-sre-agent-demo` | Resource group created by this deployment |
| `vmName` | no | `vm-sre-demo-01` | Name of the demo VM |
| `vmSize` | no | `Standard_B2s` | **The live demo deployment used `Standard_D2_v3`** — `Standard_B2s` hit `SkuNotAvailable` capacity restrictions in `eastus2` at deploy time. Override if you hit the same error |
| `osDiskStorageAccountType` | no | `Premium_LRS` | **The live demo deployment used `StandardSSD_LRS`** — required because `Standard_D2_v3` is not premium-storage-capable (no "s" suffix). Must match the chosen `vmSize`'s premium-storage capability |
| `imageSku` | no | `2022-datacenter-azure-edition-core` | **The live demo deployment used `2022-datacenter`** (Gen1, Desktop Experience) — the Gen2 `-core` SKU is incompatible with Gen1-only sizes like `Standard_D2_v3`. Match Gen1/Gen2 and Core/Desktop Experience to your chosen `vmSize` |
| `adminUsername` | yes | — | Local administrator username for the VM |
| `adminPassword` | yes (secure) | — | Local administrator password for the VM. Must meet Azure Windows VM password complexity rules |
| `deployBastion` | no | `true` | Whether to deploy Azure Bastion (Basic SKU), which is how you connect to the VM (portal → VM → Connect → Bastion) since the NSG allows no inbound internet traffic. Adds a second VNet address range + `AzureBastionSubnet` + a Standard public IP + the Bastion host (~$140/month running cost). Only set to `false` if you provide another way to reach the VM |
| `logAnalyticsWorkspaceName` | no | `law-sre-agent-demo` | Name of the Log Analytics Workspace |
| `eventSourceName` | no | `SREDemoApp` | Windows Event Log source name the demo app writes to and the DCR/alert queries match on |
| `errorCountThreshold` | no | `10` | Error-level events within 5 minutes that trigger the error-count alert |
| `cpuThresholdPercentage` | no | `50` | Sustained average CPU % (5 min window) that triggers the CPU alert |
| `memoryThresholdPercentage` | no | `70` | Average "% Committed Bytes In Use" (5 min window) that triggers the memory alert |

`adminPassword` has no default by design — it is security-sensitive and must be supplied explicitly at
deploy time.

> **Managed identity requirement:** `vm.bicep` assigns a **system-assigned managed identity** to the
> VM. This is **required** for the Azure Monitor Agent extension to authenticate and fetch its Data
> Collection Rule config — without it, the AMA extension reports `ProvisioningState: Succeeded` but
> the underlying Geneva-based agent processes (`MonAgentCore.exe`, `MonAgentHost.exe`, etc.) never
> start, and **no telemetry at all** (not even `Heartbeat`) reaches the workspace. This was discovered
> the hard way during live deployment and is now baked into the module — do not remove the `identity`
> block.

## Deploying

1. Copy `infra/main.parameters.json` and fill in the placeholder values:
   - `adminPassword`: a strong password (not committed to source control — consider passing it via
     `--parameters adminPassword=<value>` or a secret store instead of editing the JSON file in a
     shared repo). **Avoid ambiguous special characters like `$` and `^`** — they were observed to
     cause browser-based Bastion RDP logins to fail (likely a keyboard-layout/paste issue in the
     browser RDP client); stick to a safer set like `-_@#`.

2. Run the deployment from the repo root:

   ```powershell
   az deployment sub create `
     --location eastus2 `
     --template-file infra/main.bicep `
     --parameters @infra/main.parameters.json
   ```

   Or without editing the parameters file, pass sensitive values inline:

   ```powershell
   az deployment sub create `
     --location eastus2 `
     --template-file infra/main.bicep `
     --parameters @infra/main.parameters.json `
     --parameters adminPassword='<your-strong-password>'
   ```

   **Known-working override set** (used for the actual live demo deployment in `eastus2`, after
   hitting `Standard_B2s` capacity and Gen1/Gen2 image-mismatch errors with the defaults above):

   ```powershell
   az deployment sub create `
     --location eastus2 `
     --template-file infra/main.bicep `
     --parameters @infra/main.parameters.json `
     --parameters adminPassword='<your-strong-password>' `
     --parameters vmSize=Standard_D2_v3 osDiskStorageAccountType=StandardSSD_LRS imageSku=2022-datacenter
   ```

3. Validate templates compile (no deployment) at any time with:

   ```powershell
   az bicep build --file infra/main.bicep
   az bicep build --file infra/modules/networking.bicep
   az bicep build --file infra/modules/vm.bicep
   az bicep build --file infra/modules/monitoring.bicep
   az bicep build --file infra/modules/alerts.bicep
   az bicep build --file infra/modules/bastion.bicep
   ```

4. After the VM and networking resources exist, provision the demo app onto the VM (see
   `scripts/Deploy-DemoApp.ps1` — embeds the built app as a base64 payload directly into the Run
   Command script body to work around an undocumented size ceiling on `--parameters` values):

   ```powershell
   ./scripts/Deploy-DemoApp.ps1 -ResourceGroupName rg-sre-agent-demo -VmName vm-sre-demo-01
   ```

## What gets created

- Resource group (`resourceGroupName`, default `rg-sre-agent-demo`)
- VNet `vnet-sre-demo` (`10.20.0.0/24`, plus a second range `10.20.1.0/24` when `deployBastion` is
  true) with subnet `snet-sre-demo` (`10.20.0.0/24`), and `AzureBastionSubnet` (`10.20.1.0/26`) when
  `deployBastion` is true
- NSG `nsg-sre-demo` with **no custom inbound rules**: the default `DenyAllInBound` rule blocks all inbound internet traffic, and the default `AllowVnetInBound` rule lets Azure Bastion reach the VM
  - The NSG is associated with the VM's NIC (not the subnet)
- Public IP `pip-<vmName>` (Standard SKU, static allocation, with a DNS label/FQDN)
- NIC `nic-<vmName>` attached to the subnet above, with the public IP and NSG attached
- VM `<vmName>` (default `vm-sre-demo-01`):
  - Size: `vmSize` param (see override note above)
  - Image: `MicrosoftWindowsServer:WindowsServer:<imageSku>:latest`
  - OS disk: `osDiskStorageAccountType` param, `FromImage`
  - **System-assigned managed identity** (required by the AMA extension — see note above)
  - Boot diagnostics: enabled, managed (no explicit storage account — `storageUri` is omitted)
- Log Analytics Workspace `logAnalyticsWorkspaceName` (default `law-sre-agent-demo`), a Data
  Collection Endpoint + Data Collection Rule (collects Windows `Application` event log Error-level
  events matching `eventSourceName`, plus `% Processor Time` and `% Committed Bytes In Use`
  performance counters), and the `AzureMonitorWindowsAgent` VM extension associated to the DCR
- Three Azure Monitor alert rules (`alerts.bicep`), all `enabled: true`, no action groups (Azure SRE
  Agent polls alerts directly):
  - `alert-sre-demo-error-count` — log search alert (`scheduledQueryRules`), `Event` table, Error-level
    `eventSourceName` rows, `timeAggregation: Count` ≥ `errorCountThreshold` over a 5-minute window.
    **Important:** the KQL must return one row per matching event (no `summarize count()`) — `Count`
    aggregation counts rows returned, not an aggregated column value; pre-aggregating silently breaks
    the rule (it was live-patched once to fix exactly this)
  - `alert-sre-demo-cpu-high` — metric alert on the VM's `Percentage CPU`, average ≥
    `cpuThresholdPercentage` sustained over 5 minutes
  - `alert-sre-demo-memory-high` — log search alert, `Perf` table average `% Committed Bytes In Use` ≥
    `memoryThresholdPercentage` over 5 minutes (uses `metricMeasureColumn` since this one does
    legitimately aggregate to a single value per window)
- (when `deployBastion` is `true`, the default) Azure Bastion `bastion-sre-demo` (Basic SKU) with its
  own Standard public IP `pip-bastion-sre-demo`, deployed into `AzureBastionSubnet`. Provides
  portal-based (browser) RDP access to the VM — connect via **Azure Portal → the VM → Connect →
  Bastion**, then browse to `http://localhost:8080` inside the VM. No inbound NSG rules are needed.

## Outputs

Other workstreams (monitoring module, VM-provisioning script) can rely on these `main.bicep` outputs:

| Output | Description |
|---|---|
| `resourceGroupName` | Name of the resource group containing all resources |
| `vmName` | Name of the demo VM |
| `vmPublicIp` | Public IP address of the demo VM (informational — inbound traffic is blocked by the NSG; connect via Bastion) |
| `vmId` | Full ARM resource ID of the VM |
| `subnetId` | Full ARM resource ID of the subnet (for any additional resources that need to join the VNet) |
| `logAnalyticsWorkspaceId` | Full ARM resource ID of the Log Analytics Workspace |
| `logAnalyticsWorkspaceCustomerId` | Workspace GUID (`customerId`), needed for `az monitor log-analytics query -w <customerId>` |
| `bastionFqdn` | DNS name of the Azure Bastion host (empty string if `deployBastion` is `false`) |

Retrieve outputs after deployment with:

```powershell
az deployment sub show --name <deployment-name> --query properties.outputs
```

`az deployment sub create` defaults the deployment name to the template file name (`main`) unless you
pass `--name`; the live demo deployment used an explicit `--name sre-agent-demo-deploy<N>` per retry
attempt (useful when iterating past capacity/SKU errors, since failed deployment names stick around).

## Assumptions / notes

- VM image SKU defaults to `2022-datacenter-azure-edition-core` (Gen2, Server Core) but the live
  demo used the Gen1 `2022-datacenter` (Desktop Experience) SKU paired with `Standard_D2_v3` — see
  the override table above. Match Gen1/Gen2 and Core/Desktop Experience to whichever `vmSize` you
  pick; mismatches fail deployment with an image/plan compatibility error.
- No auto-shutdown schedule is configured — per the brief, this is handled by the org separately.
- The NSG has **no** custom rules, so nothing from the internet is allowed in; connect via Azure Bastion
  (and use `az vm run-command` for scripted interaction).
- `main.bicep` is deployed at subscription scope (`targetScope = 'subscription'`) so it can create
  the resource group itself; all five modules are deployed with `scope: rg` into that resource group
  (`bastion` conditionally, via `if (deployBastion)`).
- **Corporate network caveat:** direct access to a VM's public IP can be blocked entirely by a corporate
  VPN/Global Secure Access tunnel (observed live, including for a second, unrelated Azure VM). This is
  why the NSG opens no inbound ports and `deployBastion` defaults to `true`: Azure Bastion connects
  through the Azure Portal's own HTTPS session, so it is unaffected. Use **Portal → VM → Connect →
  Bastion**, open `http://localhost:8080` in the VM, and fall back to `az vm run-command` if needed.
