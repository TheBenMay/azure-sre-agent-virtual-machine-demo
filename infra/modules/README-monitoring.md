# Monitoring & Alerting Modules

This document describes `monitoring.bicep` and `alerts.bicep` so they can be wired into
`main.bicep` by the networking/VM workstream, and so the demo app and the SRE Agent runbook
use the **exact same** event source name and performance counter names as the alert rules.

Both modules are resource-group scoped and are intended to be deployed into the same
resource group as the VM (e.g. `rg-sre-agent-demo`), via `module` blocks from the
subscription-scoped `main.bicep`.

## Naming contract (must match across app, VM provisioning script, and these modules)

| Thing | Exact value |
| --- | --- |
| Windows Event Log | `Application` |
| Custom Event Log **source** | `SREDemoApp` |
| Error level used for alerting | Event Level `2` (Error) / `EventLevelName == "Error"` |
| CPU counter | `\Processor(_Total)\% Processor Time` |
| Memory counter | `\Memory\% Committed Bytes In Use` |
| Perf sampling interval | 60 seconds |

The demo app's Custom Script Extension / install script **must** register the Windows Event
Log source exactly as `SREDemoApp` under the `Application` log (e.g. via
`New-EventLog -LogName Application -Source SREDemoApp` in PowerShell, or the Windows
`EventLog` API registering under that same source name) and must write entries with
`EntryType = Error` for the error-count alert to trigger.

## `monitoring.bicep`

Creates the Log Analytics Workspace, Data Collection Endpoint, Data Collection Rule,
Data Collection Rule Association (DCR → VM), and the Azure Monitor Agent VM extension.

### Required / key parameters

| Parameter | Required | Default | Notes |
| --- | --- | --- | --- |
| `location` | yes | — | Azure region for all resources in this module. |
| `logAnalyticsWorkspaceName` | yes | — | Name of the Log Analytics Workspace to create. |
| `vmResourceId` | yes | — | Full resource ID of the VM (from `vm.bicep`'s `vmId` output). Used for traceability/output; echoed back as `monitoredVmResourceId`. |
| `vmName` | yes | — | Name of the VM (from `vm.bicep`'s `vmName` output). Used to obtain an `existing` reference to the VM (same resource group) for the DCR association scope and the AMA extension parent. |
| `logAnalyticsRetentionInDays` | no | `30` | Workspace retention. |
| `dataCollectionEndpointName` | no | `dce-sre-agent-demo` | DCE name. |
| `dataCollectionRuleName` | no | `dcr-sre-agent-demo` | DCR name. |
| `eventSourceName` | no | `SREDemoApp` | Must match the demo app's registered EventLog source name exactly. |
| `perfCounterSamplingFrequencyInSeconds` | no | `60` | Perf counter sampling interval. |

### Outputs

| Output | Description |
| --- | --- |
| `logAnalyticsWorkspaceId` | Resource ID of the Log Analytics Workspace — pass into `alerts.bicep`'s `logAnalyticsWorkspaceId` param. |
| `logAnalyticsWorkspaceCustomerId` | Workspace GUID (customer ID). |
| `dataCollectionRuleId` | Resource ID of the DCR. |
| `monitoredVmResourceId` | Echo of the `vmResourceId` input, for caller verification. |

### Example wiring from `main.bicep`

```bicep
module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  scope: resourceGroup(rg.name) // or wherever the RG module/resource is scoped
  params: {
    location: location
    logAnalyticsWorkspaceName: 'law-sre-agent-demo'
    vmResourceId: vm.outputs.vmId
    vmName: vm.outputs.vmName
  }
}
```

### Event Log collection (DCR `windowsEventLogs`)

XPath query used to filter to Error-level events from the `SREDemoApp` source only:

```
Application!*[System[Provider[@Name='SREDemoApp'] and (Level=2)]]
```

Destination table: `Event` (Log Analytics Workspace, via the `Microsoft-Event` stream).

### Performance counter collection (DCR `performanceCounters`)

Counters collected every 60 seconds, destination table: `Perf` (via the `Microsoft-Perf` stream):

- `\Processor(_Total)\% Processor Time`
- `\Memory\% Committed Bytes In Use`

## `alerts.bicep`

Creates three standalone alert rules — **no action group is configured**, since Azure SRE
Agent polls Azure Monitor alerts directly rather than being triggered via action groups.

### Required / key parameters

| Parameter | Required | Default | Notes |
| --- | --- | --- | --- |
| `location` | yes | — | Region for the two log search alert rules (should match the workspace region). The CPU metric alert is always deployed to `global`. |
| `logAnalyticsWorkspaceId` | yes | — | Resource ID of the workspace (from `monitoring.bicep`'s `logAnalyticsWorkspaceId` output); used as the `scopes` for both log search alerts. |
| `vmResourceId` | yes | — | Target resource for the CPU metric alert (from `vm.bicep`'s `vmId` output). |
| `eventSourceName` | no | `SREDemoApp` | Must match `monitoring.bicep`'s `eventSourceName` and the demo app's registered source. |
| `errorCountThreshold` | no | `10` | Error-level `SREDemoApp` events in a 5-minute window that trigger the alert. |
| `cpuThresholdPercentage` | no | `50` | Sustained average CPU % (5-minute window) that triggers the CPU alert. |
| `memoryThresholdPercentage` | no | `70` | Average "% Committed Bytes In Use" (5-minute window) that triggers the memory alert. |
| `errorCountAlertName` | no | `alert-sre-demo-error-count` | Override alert rule name if needed. |
| `cpuAlertName` | no | `alert-sre-demo-cpu-high` | Override alert rule name if needed. |
| `memoryAlertName` | no | `alert-sre-demo-memory-high` | Override alert rule name if needed. |

### Outputs

| Output | Description |
| --- | --- |
| `errorCountAlertId` | Resource ID of the error-count log search alert. |
| `cpuAlertId` | Resource ID of the CPU metric alert. |
| `memoryAlertId` | Resource ID of the memory log search alert. |

### Example wiring from `main.bicep`

```bicep
module alerts 'modules/alerts.bicep' = {
  name: 'alerts'
  scope: resourceGroup(rg.name)
  params: {
    location: location
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    vmResourceId: vm.outputs.vmId
  }
}
```

### KQL queries used by the alert rules

**1. Error-count log search alert** (severity 2, 5 min evaluation frequency / 5 min window,
threshold `>= errorCountThreshold`, default `10`):

```kql
Event
| where EventLevelName == "Error" and Source == "SREDemoApp"
| summarize AggregatedValue = count()
```

**2. CPU metric alert** (severity 3, static threshold, 5-minute window, `Percentage CPU`
metric in the `Microsoft.Compute/virtualMachines` namespace, threshold
`>= cpuThresholdPercentage`, default `50`) — this is a native Azure Monitor **metric** alert
(no KQL; evaluated directly against platform metrics).

**3. Memory log search alert** (severity 3, 5 min evaluation frequency / 5 min window,
threshold `>= memoryThresholdPercentage`, default `70`, average over the window):

```kql
Perf
| where ObjectName == "Memory" and CounterName == "% Committed Bytes In Use"
| summarize AggregatedValue = avg(CounterValue)
```

> Keep these exact table/column names (`Event.EventLevelName`, `Event.Source`,
> `Perf.ObjectName`, `Perf.CounterName`, `Perf.CounterValue`) in sync with any future
> dashboard or workbook queries, and keep `SREDemoApp` / counter name strings identical
> across the demo app, `monitoring.bicep`, and `alerts.bicep`.

## Validation

Both modules were validated standalone (they declare all of their own parameters and have
no dependency on `main.bicep`, which is still being authored by the networking/VM workstream):

```powershell
az bicep build --file infra\modules\monitoring.bicep
az bicep build --file infra\modules\alerts.bicep
```

Both commands complete with no errors or warnings (Bicep CLI 0.44.1).
