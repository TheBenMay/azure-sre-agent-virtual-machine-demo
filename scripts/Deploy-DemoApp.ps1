<#
.SYNOPSIS
    Packages app/ and runs Install-DemoApp.ps1 on the demo VM via `az vm run-command invoke`
    to install/update the demo app, with the package embedded directly in the command payload.

.DESCRIPTION
    This is the "push a new build to the VM" workflow for the Azure SRE Agent demo:
      1. Zips the app/ folder (excluding node_modules, dist/build output, and .git), since
         the VM builds the app itself from source (see Install-DemoApp.ps1).
      2. Base64-encodes the zip and passes it as a parameter to Install-DemoApp.ps1, which runs
         on the VM via `az vm run-command invoke`.

    NOTE: An earlier version of this script staged the package in an Azure Storage blob with a
    SAS URL. This subscription enforces an Azure Policy that forces all storage accounts to
    publicNetworkAccess=Disabled, which blocks both the uploading client and the VM from
    reaching blob endpoints over the public internet - so that approach doesn't work here.
    Embedding the (small, ~50 KB) app source as base64 directly in the Run Command payload
    avoids needing any public-network-reachable storage at all. If the app package grows
    significantly, revisit this (e.g. a private endpoint + VM in the same VNet, or git-cloning
    from a reachable repository instead).

.PARAMETER ResourceGroupName
    Resource group containing the demo VM (must match infra/main.bicep's resourceGroupName).

.PARAMETER VmName
    Name of the demo VM (must match infra/main.bicep's vmName).

.PARAMETER AppPort
    Port the demo app listens on (must match the NSG rule in infra/modules/networking.bicep).

.EXAMPLE
    .\scripts\Deploy-DemoApp.ps1 -ResourceGroupName rg-sre-agent-demo -VmName vm-sre-demo-01
#>
param(
    [string]$ResourceGroupName = 'rg-sre-agent-demo',
    [string]$VmName = 'vm-sre-demo-01',
    [int]$AppPort = 8080
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$appPath = Join-Path $repoRoot 'app'
$zipPath = Join-Path $env:TEMP 'sre-demo-app-package.zip'

Write-Host "--- Packaging $appPath (excluding node_modules/dist/.git) ---"
Remove-Item -Force $zipPath -ErrorAction SilentlyContinue
$stagingDir = Join-Path $env:TEMP "sre-demo-app-staging-$(Get-Random)"
New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null
try {
    robocopy $appPath $stagingDir /E /XD node_modules dist .git .vite /XF *.log | Out-Null
    Compress-Archive -Path (Join-Path $stagingDir '*') -DestinationPath $zipPath -Force
}
finally {
    Remove-Item -Recurse -Force $stagingDir -ErrorAction SilentlyContinue
}
$zipSizeKb = [math]::Round((Get-Item $zipPath).Length / 1KB, 1)
Write-Host "Package created: $zipPath ($zipSizeKb KB)"
if ($zipSizeKb -gt 200) {
    Write-Warning "Package is $zipSizeKb KB - Run Command payloads have a size ceiling (~256KB total). If this invoke fails, trim app/ further or switch to a VNet-reachable transfer mechanism."
}

$base64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($zipPath))
Write-Host "Base64-encoded payload: $([math]::Round($base64.Length / 1KB, 1)) KB"

Write-Host "--- Running Install-DemoApp.ps1 on $VmName via az vm run-command invoke ---"
Write-Host '(this installs Node.js if needed, builds the app, and starts the Scheduled Task - can take several minutes on first run)'

# az vm run-command's --parameters values have a size ceiling well below this base64 payload's
# size (~67KB reliably fails with a generic VMExtensionProvisioningError and no script output),
# while --scripts file content comfortably supports payloads this size. So instead of passing
# the payload as a parameter, inject it directly into a temp copy of the script body by
# replacing the placeholder line in Install-DemoApp.ps1.
$installScriptContent = Get-Content (Join-Path $PSScriptRoot 'Install-DemoApp.ps1') -Raw
$payloadAssignment = "`$PackagePayloadBase64 = @'`n$base64`n'@"
$combinedScriptContent = $installScriptContent -replace '# __PACKAGE_PAYLOAD_PLACEHOLDER__', $payloadAssignment
if ($combinedScriptContent -eq $installScriptContent) {
    throw 'Could not find the __PACKAGE_PAYLOAD_PLACEHOLDER__ marker in Install-DemoApp.ps1 - has it been edited?'
}
$combinedScriptPath = Join-Path $env:TEMP 'sre-demo-install-combined.ps1'
Set-Content -Path $combinedScriptPath -Value $combinedScriptContent -Encoding utf8 -NoNewline

az vm run-command invoke --resource-group $ResourceGroupName --name $VmName `
    --command-id RunPowerShellScript `
    --scripts "@$combinedScriptPath" `
    --parameters "AppPort=$AppPort" `
    -o json | ConvertFrom-Json | Select-Object -ExpandProperty value | ForEach-Object { $_.message }

Remove-Item -Force $combinedScriptPath, $zipPath -ErrorAction SilentlyContinue
Write-Host '--- Done. ---'
