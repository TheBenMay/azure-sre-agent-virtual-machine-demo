<#
.SYNOPSIS
    Creates (if needed) and assigns a least-privilege custom role that lets the "VM Alert
    Responder" custom agent invoke Azure Run Command on a single VM, without granting the
    broad built-in "Virtual Machine Contributor" role.

.DESCRIPTION
    docs/vm-alert-responder-instructions.md documents a workaround where the custom agent
    calls the Compute "Run Command" REST API directly (via its sandbox's own managed
    identity token) because the `RunAzCliWriteCommands` tool's `az vm run-command
    invoke/create` path currently fails. That workaround originally required assigning the
    agent's identity "Virtual Machine Contributor" at the VM (or resource group) scope --
    a role that also grants delete, resize, disk, and extension management rights far
    beyond what "run a script on this one VM" needs.

    This script instead creates a **custom role** containing only the actions needed to
    create, poll, and clean up a persisted VM run command:
        - Microsoft.Compute/virtualMachines/runCommands/write   (create/update run command)
        - Microsoft.Compute/virtualMachines/runCommands/read    (poll status/stdout/stderr)
        - Microsoft.Compute/virtualMachines/runCommands/delete  (clean up afterwards)
    (Verified against the Azure resource-provider operation catalog -- these are the exact
    control-plane actions for the `Microsoft.Compute/virtualMachines/runCommands/{name}`
    sub-resource used by the REST calls in the instructions doc.)

    The role definition's `AssignableScopes` and the role assignment are both scoped to the
    **single VM's resource ID**, not the resource group -- tighter blast radius than the
    agent's existing Reader-level resource-group grant from
    `scripts/grant-sre-agent-access.ps1` / docs/sre-agent-setup.md step (e).

    Re-running this script for a second VM will extend the existing custom role's
    `AssignableScopes` to include the new VM (role definitions are created once per
    subscription, then reused/extended across scopes) rather than creating a duplicate
    role.

    It is idempotent: both the role *definition* and the role *assignment* are checked
    before being created/updated, so re-running this script is safe.

.PARAMETER UamiObjectId
    The Object (principal) ID of the Azure SRE Agent's user-assigned managed identity.
    Find it in the agent portal: Settings > Azure settings > Go to Identity. Or in the
    Azure portal: the agent's Container App resource > Identity > Object (principal) ID.

.PARAMETER VmName
    The name of the virtual machine to scope the role to. Defaults to 'vm-sre-demo-01' to
    match docs/sre-agent-setup.md and docs/vm-alert-responder-instructions.md.

.PARAMETER ResourceGroupName
    The resource group containing VmName. Defaults to 'rg-sre-agent-demo'.
    ASSUMPTION: this default matches docs/sre-agent-setup.md and
    scripts/grant-sre-agent-access.ps1. If infra/README.md is published with a different
    resource group name, update the default here too.

.PARAMETER SubscriptionId
    The subscription ID that contains ResourceGroupName/VmName.

.PARAMETER RoleName
    Display name of the custom role. Defaults to 'SRE Demo VM RunCommand Operator'.

.EXAMPLE
    ./grant-vm-runcommand-role.ps1 `
        -UamiObjectId "11111111-2222-3333-4444-555555555555" `
        -VmName "vm-sre-demo-01" `
        -ResourceGroupName "rg-sre-agent-demo" `
        -SubscriptionId "66666666-7777-8888-9999-aaaaaaaaaaaa"

.NOTES
    This is a TEMPLATE script, written alongside the rest of the VM Script Execution
    rewrite in docs/vm-alert-responder-instructions.md. It has not been executed against
    live Azure resources in this session (no subscription access here) -- run it (and
    verify the resulting role assignment in the portal) before relying on it for a live
    demo, and keep the agent's "show the script and wait for confirmation" step (see the
    instructions doc) as the actual per-action safety control -- this script only narrows
    *what* the agent's identity is capable of if a confirmed script is executed.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string] $UamiObjectId,

    [Parameter(Mandatory = $false)]
    [string] $VmName = "vm-sre-demo-01",

    [Parameter(Mandatory = $false)]
    [string] $ResourceGroupName = "rg-sre-agent-demo",

    [Parameter(Mandatory = $true)]
    [string] $SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string] $RoleName = "SRE Demo VM RunCommand Operator"
)

$ErrorActionPreference = "Stop"

$vmScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/virtualMachines/$VmName"

# Least-privilege actions for the persisted VM Run Command sub-resource used by the REST
# calls in docs/vm-alert-responder-instructions.md. VM read / instanceView read (needed to
# resolve the VM itself and poll $expand=instanceView) are already covered by the agent's
# existing Reader-level grant from scripts/grant-sre-agent-access.ps1, so they're
# intentionally not duplicated here.
$RunCommandActions = @(
    "Microsoft.Compute/virtualMachines/runCommands/write",
    "Microsoft.Compute/virtualMachines/runCommands/read",
    "Microsoft.Compute/virtualMachines/runCommands/delete"
)

Write-Host "Checking for existing custom role '$RoleName'..." -ForegroundColor Yellow

$existingRole = az role definition list --name $RoleName --custom-role-only true | ConvertFrom-Json

if (-not $existingRole) {
    Write-Host "No existing '$RoleName' role found. Creating it, scoped to: $vmScope" -ForegroundColor Green

    $roleDefinition = [ordered]@{
        Name             = $RoleName
        IsCustom         = $true
        Description      = "Lets the SRE Agent's identity invoke, poll, and delete Azure Run Command on a single demo VM, without the broader rights in built-in 'Virtual Machine Contributor'."
        Actions          = $RunCommandActions
        NotActions       = @()
        DataActions      = @()
        NotDataActions   = @()
        AssignableScopes = @($vmScope)
    }

    $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "sre-demo-runcommand-role-$([guid]::NewGuid()).json"
    $roleDefinition | ConvertTo-Json -Depth 5 | Set-Content -Path $tempFile -Encoding utf8

    try {
        if ($PSCmdlet.ShouldProcess($RoleName, "Create custom role definition")) {
            az role definition create --role-definition $tempFile

            if ($LASTEXITCODE -ne 0) {
                throw "Failed to create custom role '$RoleName'. See az CLI output above."
            }
        }
    }
    finally {
        Remove-Item -Path $tempFile -ErrorAction SilentlyContinue
    }
}
else {
    Write-Host "Custom role '$RoleName' already exists." -ForegroundColor DarkGray

    $assignableScopes = @($existingRole.assignableScopes)
    if ($assignableScopes -notcontains $vmScope) {
        Write-Host "Extending its AssignableScopes to include: $vmScope" -ForegroundColor Green

        $updatedScopes = $assignableScopes + $vmScope
        $roleDefinition = [ordered]@{
            Name             = $RoleName
            Id               = $existingRole.name  # role definition GUID, required by `az role definition update`
            IsCustom         = $true
            Description      = $existingRole.description
            Actions          = $RunCommandActions
            NotActions       = @()
            DataActions      = @()
            NotDataActions   = @()
            AssignableScopes = $updatedScopes
        }

        $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "sre-demo-runcommand-role-$([guid]::NewGuid()).json"
        $roleDefinition | ConvertTo-Json -Depth 5 | Set-Content -Path $tempFile -Encoding utf8

        try {
            if ($PSCmdlet.ShouldProcess($RoleName, "Update custom role AssignableScopes")) {
                az role definition update --role-definition $tempFile

                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to update custom role '$RoleName'. See az CLI output above."
                }
            }
        }
        finally {
            Remove-Item -Path $tempFile -ErrorAction SilentlyContinue
        }
    }
    else {
        Write-Host "AssignableScopes already includes: $vmScope" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "Checking existing role assignment at VM scope..." -ForegroundColor Yellow

$existingAssignment = az role assignment list `
    --assignee-object-id $UamiObjectId `
    --role $RoleName `
    --scope $vmScope `
    --query "[].id" `
    -o tsv

if ([string]::IsNullOrWhiteSpace($existingAssignment)) {
    Write-Host "No existing '$RoleName' assignment found at $vmScope. Creating..." -ForegroundColor Green

    if ($PSCmdlet.ShouldProcess($vmScope, "Assign role '$RoleName' to $UamiObjectId")) {
        az role assignment create `
            --assignee-object-id $UamiObjectId `
            --assignee-principal-type ServicePrincipal `
            --role $RoleName `
            --scope $vmScope

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to assign role '$RoleName' at scope '$vmScope'. See az CLI output above."
        }
    }
}
else {
    Write-Host "Role '$RoleName' is already assigned at this scope (assignment id: $existingAssignment). Skipping." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "Done. The agent's managed identity can now invoke/poll/delete Run Command on '$VmName' only -- it does not have Virtual Machine Contributor or any other VM-wide write rights." -ForegroundColor Cyan
Write-Host "Reminder: this role narrows *capability*, not *approval*. The agent must still show the exact script and wait for user confirmation before calling the Run Command REST API -- see docs/vm-alert-responder-instructions.md." -ForegroundColor Cyan
