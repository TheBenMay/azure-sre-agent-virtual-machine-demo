<#
.SYNOPSIS
    In-guest provisioning script for the Azure SRE Agent demo VM.

.DESCRIPTION
    Runs ON the Windows Server 2022 VM (via `az vm run-command invoke`) to:
      1. Register the custom Windows Event Log source "SREDemoApp" (Application log)
         that the demo app's /api/errors endpoint writes Error-level events to, and
         that the monitoring Data Collection Rule (infra/modules/monitoring.bicep)
         is filtered on.
      2. Install Node.js (latest LTS) if not already present.
      3. Decode and extract the demo app package (zipped app/ source, base64-embedded directly
         in the Run Command invocation by scripts/Deploy-DemoApp.ps1 - no storage account
         needed, since this subscription's policy forces storage accounts to
         publicNetworkAccess=Disabled) to C:\SREDemoApp\app.
      4. Run `npm install` + `npm run build` on the VM (needs outbound internet to
         registry.npmjs.org - allowed by default, NSG here only restricts inbound).
      5. Open the Windows Firewall for the app port (the app is normally used at localhost via Bastion).
      6. Register + start a Scheduled Task ("SREDemoApp") that runs `node dist\server.js`
         at system startup (and immediately now), restarting automatically if it exits.

.NOTES
    Idempotent: safe to re-run (e.g. to push an updated app package) - it registers the
    event source only if missing, replaces the extracted app folder, and re-registers the
    scheduled task each time.
#>
param(
    [int]$AppPort = 8080
)

# NOTE: $PackagePayloadBase64 is deliberately NOT a declared parameter. az vm run-command's
# --parameters values are capped well below the size of this base64 app package (a ~67KB value
# reliably causes a generic 'VMExtensionProvisioningError' with no script output at all), while
# --scripts file content comfortably supports payloads this size. So scripts/Deploy-DemoApp.ps1
# injects the payload by replacing the placeholder line below with a here-string assignment
# before invoking this script - keep the placeholder line intact and exactly as written.
# __PACKAGE_PAYLOAD_PLACEHOLDER__

$ErrorActionPreference = 'Stop'
$installRoot = 'C:\SREDemoApp'
New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
Start-Transcript -Path (Join-Path $installRoot 'install.log') -Append | Out-Null

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Write-Host '--- Step 1: Register SREDemoApp Event Log source ---'
    if (-not [System.Diagnostics.EventLog]::SourceExists('SREDemoApp')) {
        New-EventLog -LogName Application -Source 'SREDemoApp'
        Write-Host 'Registered Event Log source SREDemoApp.'
    }
    else {
        Write-Host 'Event Log source SREDemoApp already registered.'
    }

    Write-Host '--- Step 2: Ensure Node.js is installed ---'
    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if (-not $nodeCmd) {
        Write-Host 'Node.js not found - downloading latest LTS...'
        $distIndex = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json'
        $lts = $distIndex | Where-Object { $_.lts } | Select-Object -First 1
        if (-not $lts) { throw 'Could not determine latest Node.js LTS version.' }
        $version = $lts.version
        $msiUrl = "https://nodejs.org/dist/$version/node-$version-x64.msi"
        $msiPath = Join-Path $env:TEMP 'node-lts.msi'
        Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath
        Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /qn /norestart" -Wait
        # Refresh PATH in this process so `node`/`npm` resolve without a new shell.
        $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
        $userPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')
        $env:Path = "$machinePath;$userPath"
        Write-Host "Installed Node.js $version."
    }
    else {
        Write-Host "Node.js already present: $(node --version)"
    }

    Write-Host '--- Step 3: Decode and extract demo app package ---'
    $zipPath = Join-Path $env:TEMP 'sre-demo-app.zip'
    [IO.File]::WriteAllBytes($zipPath, [Convert]::FromBase64String($PackagePayloadBase64))
    $appPath = Join-Path $installRoot 'app'
    Remove-Item -Recurse -Force $appPath -ErrorAction SilentlyContinue
    Expand-Archive -Path $zipPath -DestinationPath $appPath -Force
    Write-Host "Extracted app package to $appPath."

    Write-Host '--- Step 4: npm install + build ---'
    Push-Location $appPath
    # npm writes routine "npm notice" messages to stderr; with $ErrorActionPreference = 'Stop'
    # (set above), PowerShell 5.1 treats ANY stderr line from a native command as a terminating
    # error even when merged via 2>&1, so relax it to 'Continue' for just these two calls and
    # rely on $LASTEXITCODE to detect real failures instead.
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & npm install --no-audit --no-fund 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) { throw "npm install failed with exit code $LASTEXITCODE" }
        & npm run build 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) { throw "npm run build failed with exit code $LASTEXITCODE" }
    }
    finally {
        $ErrorActionPreference = $previousEap
        Pop-Location
    }

    Write-Host '--- Step 5: Open firewall port ---'
    if (-not (Get-NetFirewallRule -DisplayName 'SRE Demo App' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName 'SRE Demo App' -Direction Inbound -Protocol TCP -LocalPort $AppPort -Action Allow | Out-Null
        Write-Host "Opened inbound firewall for TCP port $AppPort."
    }
    else {
        Write-Host 'Firewall rule for SRE Demo App already exists.'
    }

    Write-Host '--- Step 6: Register + start Scheduled Task ---'
    $apiPath = Join-Path $appPath 'api'
    # Use the fully-resolved node.exe path rather than relying on PATH lookup: the Scheduled
    # Task runs as SYSTEM in a fresh process, and Windows services/Task Scheduler commonly
    # don't see a just-installed Node.js's System PATH update until the next reboot/logon -
    # causing the task to fail with ERROR_FILE_NOT_FOUND (0x80070002) even though `node` works
    # fine in this (already PATH-refreshed) installer process.
    $nodeExePath = (Get-Command node).Source
    Write-Host "Resolved node.exe path: $nodeExePath"
    $action = New-ScheduledTaskAction -Execute $nodeExePath -Argument 'dist\server.js' -WorkingDirectory $apiPath
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

    Unregister-ScheduledTask -TaskName 'SREDemoApp' -Confirm:$false -ErrorAction SilentlyContinue
    # Unregistering doesn't stop an already-running instance; kill it so the new build can bind the port.
    Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" |
        Where-Object { $_.CommandLine -like '*dist\server.js*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Register-ScheduledTask -TaskName 'SREDemoApp' -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings | Out-Null

    # PORT env var is read by app/api/src/server.ts; set it machine-wide so the
    # scheduled task (running as SYSTEM) picks it up.
    [System.Environment]::SetEnvironmentVariable('PORT', "$AppPort", 'Machine')

    Stop-ScheduledTask -TaskName 'SREDemoApp' -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName 'SREDemoApp'
    Start-Sleep -Seconds 5

    $task = Get-ScheduledTask -TaskName 'SREDemoApp'
    Write-Host "Scheduled Task state: $($task.State)"
    Write-Host "Provisioning complete. Demo app is running on the VM. Connect via Azure Bastion and browse to http://localhost:$AppPort inside the VM"
}
finally {
    Stop-Transcript | Out-Null
}
