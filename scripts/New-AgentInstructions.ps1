<#
.SYNOPSIS
    Renders a ready-to-paste "VM Alert Responder" custom-agent instructions file from
    docs/vm-alert-responder-instructions.template.md, filled in with the actual values
    from *your* deployment instead of the original demo's hardcoded subscription/resource
    names.

.DESCRIPTION
    docs/vm-alert-responder-instructions.md used to hardcode the original author's
    subscription ID, resource group, VM name, and Log Analytics workspace name/ID directly
    in the text block meant to be pasted into the SRE Agent portal. Pasting that verbatim
    into a different subscription would point the custom agent at someone else's
    resources.

    This script instead:
      1. Reads the outputs (and, where needed, the resolved parameter values) of your
         `infra/main.bicep` deployment via `az deployment sub show`.
      2. Falls back to this repo's Bicep defaults for anything not available as a
         deployment output (e.g. alert rule names, the Data Collection Rule name) or not
         explicitly overridden via a script parameter.
      3. Substitutes the `{{PLACEHOLDER}}` tokens in
         docs/vm-alert-responder-instructions.template.md and writes the result to
         docs/vm-alert-responder-instructions.generated.md (git-ignored - it's a
         per-deployment artifact, not checked-in source).

    Run this *after* `infra/main.bicep` has been deployed (see infra/README.md), then copy
    the generated file's contents into the custom agent's instructions field per
    docs/sre-agent-setup.md step (h).

.PARAMETER DeploymentName
    Name of the subscription-scoped deployment to read outputs/parameters from (the name
    passed to `az deployment sub create --name ...`, or `main` if none was given).

.PARAMETER SubscriptionId
    Subscription ID containing the deployment. Defaults to the current `az account show`
    subscription if not supplied.

.PARAMETER ResourceGroupName
    Override instead of reading from the deployment output. Useful if you don't have the
    deployment record handy and want to fill in values by hand.

.PARAMETER VmName
    Override instead of reading from the deployment output.

.PARAMETER Location
    Override instead of reading from the deployment parameters.

.PARAMETER LogAnalyticsWorkspaceName
    Override instead of deriving from the deployment's `logAnalyticsWorkspaceId` output.

.PARAMETER LogAnalyticsWorkspaceCustomerId
    Override instead of reading from the deployment's
    `logAnalyticsWorkspaceCustomerId` output.

.PARAMETER DataCollectionRuleName
    Override the Data Collection Rule name. Defaults to `dcr-sre-agent-demo` (the
    `infra/modules/monitoring.bicep` default - `main.bicep` does not expose this as a
    pass-through parameter, so it is the same for every deployment unless you've edited
    the Bicep yourself).

.PARAMETER ErrorCountAlertName
.PARAMETER CpuAlertName
.PARAMETER MemoryAlertName
    Override the alert rule names. Default to the `infra/modules/alerts.bicep` defaults
    (`alert-sre-demo-error-count` / `alert-sre-demo-cpu-high` / `alert-sre-demo-memory-high`)
    for the same reason as DataCollectionRuleName above.

.PARAMETER ErrorCountThreshold
.PARAMETER CpuThresholdPercentage
.PARAMETER MemoryThresholdPercentage
    Override the alert thresholds instead of reading from the deployment parameters.

.PARAMETER TemplatePath
    Path to the template file. Defaults to
    docs/vm-alert-responder-instructions.template.md.

.PARAMETER OutputPath
    Path to write the rendered instructions to. Defaults to
    docs/vm-alert-responder-instructions.generated.md.

.EXAMPLE
    ./scripts/New-AgentInstructions.ps1

.EXAMPLE
    # No deployment record handy - fill in every value explicitly instead.
    ./scripts/New-AgentInstructions.ps1 `
        -SubscriptionId "11111111-2222-3333-4444-555555555555" `
        -ResourceGroupName "rg-sre-agent-demo" `
        -VmName "vm-sre-demo-01" `
        -Location "eastus2" `
        -LogAnalyticsWorkspaceName "law-sre-agent-demo" `
        -LogAnalyticsWorkspaceCustomerId "22222222-3333-4444-5555-666666666666"
#>
[CmdletBinding()]
param(
    [string] $DeploymentName = "main",
    [string] $SubscriptionId,
    [string] $ResourceGroupName,
    [string] $VmName,
    [string] $Location,
    [string] $LogAnalyticsWorkspaceName,
    [string] $LogAnalyticsWorkspaceCustomerId,
    [string] $DataCollectionRuleName = "dcr-sre-agent-demo",
    [string] $ErrorCountAlertName = "alert-sre-demo-error-count",
    [string] $CpuAlertName = "alert-sre-demo-cpu-high",
    [string] $MemoryAlertName = "alert-sre-demo-memory-high",
    [Nullable[int]] $ErrorCountThreshold,
    [Nullable[int]] $CpuThresholdPercentage,
    [Nullable[int]] $MemoryThresholdPercentage,
    [string] $TemplatePath = (Join-Path (Split-Path -Parent $PSScriptRoot) "docs\vm-alert-responder-instructions.template.md"),
    [string] $OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "docs\vm-alert-responder-instructions.generated.md")
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $TemplatePath)) {
    throw "Template not found at '$TemplatePath'. Has docs/vm-alert-responder-instructions.template.md been moved/renamed?"
}

if (-not $SubscriptionId) {
    Write-Host "No -SubscriptionId supplied - using the current az CLI subscription..." -ForegroundColor Yellow
    $SubscriptionId = az account show --query id -o tsv
    if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
        throw "Could not determine a subscription ID from 'az account show'. Pass -SubscriptionId explicitly, or run 'az login' / 'az account set' first."
    }
}

# Try to read the deployment's outputs/parameters, but tolerate failure - every value can
# also be supplied explicitly via script parameters (e.g. if the deployment record has
# expired, or you're filling in values for someone else's deployment by hand).
$deploymentOutputs = $null
$deploymentParameters = $null
Write-Host "Looking up deployment '$DeploymentName' in subscription $SubscriptionId..." -ForegroundColor Yellow
$deploymentJson = az deployment sub show --name $DeploymentName --subscription $SubscriptionId -o json 2>$null
if ($LASTEXITCODE -eq 0 -and $deploymentJson) {
    $deployment = $deploymentJson | ConvertFrom-Json
    $deploymentOutputs = $deployment.properties.outputs
    $deploymentParameters = $deployment.properties.parameters
    Write-Host "Found deployment '$DeploymentName'." -ForegroundColor Green
}
else {
    Write-Warning "Could not find a subscription deployment named '$DeploymentName' (or 'az deployment sub show' failed). Falling back to explicit script parameters / Bicep defaults for anything not supplied. Pass -DeploymentName if you used a different --name at deploy time."
}

function Resolve-Value {
    param(
        [string] $Explicit,
        [object] $OutputValue,
        [string] $ParameterName,
        [string] $FallbackDefault,
        [string] $FriendlyName
    )
    if ($Explicit) { return $Explicit }
    if ($OutputValue) { return [string]$OutputValue }
    if ($ParameterName -and $deploymentParameters -and $deploymentParameters.$ParameterName) {
        return [string]$deploymentParameters.$ParameterName.value
    }
    if ($FallbackDefault) {
        Write-Warning "Could not resolve '$FriendlyName' from the deployment - using the repo's Bicep default '$FallbackDefault'. Pass -$FriendlyName explicitly if this is wrong for your deployment."
        return $FallbackDefault
    }
    throw "Could not resolve required value '$FriendlyName'. Pass it explicitly, e.g. -$FriendlyName '<value>'."
}

$resolvedResourceGroupName = Resolve-Value -Explicit $ResourceGroupName -OutputValue $deploymentOutputs.resourceGroupName.value -ParameterName "resourceGroupName" -FallbackDefault "rg-sre-agent-demo" -FriendlyName "ResourceGroupName"
$resolvedVmName = Resolve-Value -Explicit $VmName -OutputValue $deploymentOutputs.vmName.value -ParameterName "vmName" -FallbackDefault "vm-sre-demo-01" -FriendlyName "VmName"
$resolvedLocation = Resolve-Value -Explicit $Location -ParameterName "location" -FallbackDefault "eastus2" -FriendlyName "Location"
$resolvedWorkspaceCustomerId = Resolve-Value -Explicit $LogAnalyticsWorkspaceCustomerId -OutputValue $deploymentOutputs.logAnalyticsWorkspaceCustomerId.value -FriendlyName "LogAnalyticsWorkspaceCustomerId"

$resolvedWorkspaceName = $LogAnalyticsWorkspaceName
if (-not $resolvedWorkspaceName -and $deploymentOutputs.logAnalyticsWorkspaceId.value) {
    # logAnalyticsWorkspaceId is a full ARM resource ID - the workspace name is the last segment.
    $resolvedWorkspaceName = ($deploymentOutputs.logAnalyticsWorkspaceId.value -split "/")[-1]
}
if (-not $resolvedWorkspaceName) {
    $resolvedWorkspaceName = Resolve-Value -Explicit $null -ParameterName "logAnalyticsWorkspaceName" -FallbackDefault "law-sre-agent-demo" -FriendlyName "LogAnalyticsWorkspaceName"
}

$resolvedErrorCountThreshold = if ($null -ne $ErrorCountThreshold) { $ErrorCountThreshold } `
    elseif ($deploymentParameters.errorCountThreshold.value) { $deploymentParameters.errorCountThreshold.value } `
    else { Write-Warning "Could not resolve 'ErrorCountThreshold' from the deployment - using the repo's Bicep default '10'."; 10 }
$resolvedCpuThresholdPercentage = if ($null -ne $CpuThresholdPercentage) { $CpuThresholdPercentage } `
    elseif ($deploymentParameters.cpuThresholdPercentage.value) { $deploymentParameters.cpuThresholdPercentage.value } `
    else { Write-Warning "Could not resolve 'CpuThresholdPercentage' from the deployment - using the repo's Bicep default '50'."; 50 }
$resolvedMemoryThresholdPercentage = if ($null -ne $MemoryThresholdPercentage) { $MemoryThresholdPercentage } `
    elseif ($deploymentParameters.memoryThresholdPercentage.value) { $deploymentParameters.memoryThresholdPercentage.value } `
    else { Write-Warning "Could not resolve 'MemoryThresholdPercentage' from the deployment - using the repo's Bicep default '70'."; 70 }

$tokens = [ordered]@{
    "{{SUBSCRIPTION_ID}}"                     = $SubscriptionId
    "{{RESOURCE_GROUP}}"                      = $resolvedResourceGroupName
    "{{VM_NAME}}"                             = $resolvedVmName
    "{{LOCATION}}"                             = $resolvedLocation
    "{{LOG_ANALYTICS_WORKSPACE_NAME}}"        = $resolvedWorkspaceName
    "{{LOG_ANALYTICS_WORKSPACE_CUSTOMER_ID}}" = $resolvedWorkspaceCustomerId
    "{{DATA_COLLECTION_RULE_NAME}}"           = $DataCollectionRuleName
    "{{ERROR_COUNT_ALERT_NAME}}"               = $ErrorCountAlertName
    "{{CPU_ALERT_NAME}}"                       = $CpuAlertName
    "{{MEMORY_ALERT_NAME}}"                   = $MemoryAlertName
    "{{ERROR_COUNT_THRESHOLD}}"                = $resolvedErrorCountThreshold
    "{{CPU_THRESHOLD_PERCENTAGE}}"             = $resolvedCpuThresholdPercentage
    "{{MEMORY_THRESHOLD_PERCENTAGE}}"         = $resolvedMemoryThresholdPercentage
}

Write-Host ""
Write-Host "--- Resolved values ---" -ForegroundColor Cyan
foreach ($key in $tokens.Keys) {
    Write-Host ("{0,-42} {1}" -f $key, $tokens[$key])
}

$content = Get-Content -Path $TemplatePath -Raw
foreach ($key in $tokens.Keys) {
    $content = $content.Replace($key, [string]$tokens[$key])
}

$remainingTokens = [regex]::Matches($content, "\{\{[A-Z_]+\}\}") | ForEach-Object { $_.Value } | Select-Object -Unique
if ($remainingTokens) {
    throw "The following placeholder token(s) were not substituted: $($remainingTokens -join ', '). Update this script to resolve them, or pass their values explicitly."
}

Set-Content -Path $OutputPath -Value $content -Encoding utf8 -NoNewline
Write-Host ""
Write-Host "--- Done. ---" -ForegroundColor Cyan
Write-Host "Wrote $OutputPath"
Write-Host "Copy its contents into the custom agent's instructions field per docs/sre-agent-setup.md step (h)."
