<#
.SYNOPSIS
    CLI fallback/equivalent for granting an Azure SRE Agent's managed identity
    "Reader" permission level access to a resource group.

.DESCRIPTION
    When you add a resource group to an Azure SRE Agent via the onboarding wizard
    (https://sre.azure.com -> agent -> Quickstart -> Azure resources -> Add resources ->
    Resource group -> permission level "Reader"), the portal automatically assigns the
    agent's user-assigned managed identity (UAMI) the following roles at the resource
    group scope:
        - Reader
        - Log Analytics Reader
        - Monitoring Reader
    (plus any additional resource-type-specific *reader* roles the portal detects —
    this script does not attempt to replicate those, only the three base roles that are
    always assigned regardless of resource types present).

    This script is a manual/CLI equivalent of that step, for cases where:
        - The portal connector isn't available, or
        - You need to re-apply / verify the role assignments out of band, or
        - You're scripting environment setup/teardown for repeatable demos.

    It is idempotent: it checks existing role assignments via `az role assignment list`
    before creating each one, so re-running this script is safe and will not create
    duplicate assignments.

    IMPORTANT: This script intentionally does NOT assign the subscription-scope
    "Monitoring Contributor" role that Azure SRE Agent also needs for full alert
    lifecycle management (acknowledge/close alerts). That assignment requires Owner or
    User Access Administrator at the SUBSCRIPTION level -- a materially higher privilege
    than the resource-group-scoped roles this script grants -- so it should be run
    separately and deliberately by whoever holds that access. See the commented-out
    example near the bottom of this file.

    Reference (verified 2026-10-12):
        https://learn.microsoft.com/en-us/azure/sre-agent/permissions

.PARAMETER UamiObjectId
    The Object (principal) ID of the Azure SRE Agent's user-assigned managed identity.
    Find it in the agent portal: Settings > Azure settings > Go to Identity. Or in the
    Azure portal: the agent's Container App resource > Identity > Object (principal) ID.

.PARAMETER ResourceGroupName
    The resource group to grant access to. Defaults to 'rg-sre-agent-demo'.
    ASSUMPTION: this default matches docs/sre-agent-setup.md. If infra/README.md is
    published with a different resource group name, update the default here too.

.PARAMETER SubscriptionId
    The subscription ID that contains ResourceGroupName.

.EXAMPLE
    ./grant-sre-agent-access.ps1 `
        -UamiObjectId "11111111-2222-3333-4444-555555555555" `
        -ResourceGroupName "rg-sre-agent-demo" `
        -SubscriptionId "66666666-7777-8888-9999-aaaaaaaaaaaa"

.NOTES
    This is a TEMPLATE script. As of the time it was written, no Azure SRE Agent has
    been created yet in this environment, so no UAMI object ID exists and this script
    has not been executed against live Azure resources. Do not assume the role
    assignments below have been applied -- run this script (or use the portal wizard)
    once the agent exists.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string] $UamiObjectId,

    [Parameter(Mandatory = $false)]
    [string] $ResourceGroupName = "rg-sre-agent-demo",

    [Parameter(Mandatory = $true)]
    [string] $SubscriptionId
)

$ErrorActionPreference = "Stop"

# Base roles the Azure SRE Agent portal wizard always assigns at resource-group scope
# for the "Reader" permission level. Exact role-name strings confirmed via:
#   az role definition list --name "<role>" --query "[].roleName" -o tsv
$RolesToAssign = @(
    "Reader",
    "Log Analytics Reader",
    "Monitoring Reader"
)

$scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"

Write-Host "Granting Azure SRE Agent (UAMI objectId: $UamiObjectId) Reader-level access to scope: $scope" -ForegroundColor Cyan

foreach ($role in $RolesToAssign) {
    Write-Host ""
    Write-Host "Checking existing '$role' assignment..." -ForegroundColor Yellow

    # Idempotency check: skip creation if the assignment already exists.
    $existing = az role assignment list `
        --assignee-object-id $UamiObjectId `
        --role $role `
        --scope $scope `
        --query "[].id" `
        -o tsv

    if ([string]::IsNullOrWhiteSpace($existing)) {
        Write-Host "No existing '$role' assignment found. Creating..." -ForegroundColor Green

        if ($PSCmdlet.ShouldProcess($scope, "Assign role '$role' to $UamiObjectId")) {
            az role assignment create `
                --assignee-object-id $UamiObjectId `
                --assignee-principal-type ServicePrincipal `
                --role $role `
                --scope $scope

            if ($LASTEXITCODE -ne 0) {
                throw "Failed to assign role '$role' at scope '$scope'. See az CLI output above."
            }
        }
    }
    else {
        Write-Host "Role '$role' is already assigned at this scope (assignment id: $existing). Skipping." -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "Done. The agent's managed identity now has Reader, Log Analytics Reader, and Monitoring Reader on '$ResourceGroupName'." -ForegroundColor Cyan
Write-Host "Remember: this is the Reader permission level only. Any write/remediation action on resources in this" -ForegroundColor Cyan
Write-Host "resource group still requires the agent to request on-behalf-of (OBO) elevation from an SRE Agent Administrator." -ForegroundColor Cyan

# -----------------------------------------------------------------------------------
# SUBSCRIPTION-SCOPE "Monitoring Contributor" -- DO NOT RUN AS PART OF THIS SCRIPT
# -----------------------------------------------------------------------------------
# Azure SRE Agent also needs "Monitoring Contributor" at the SUBSCRIPTION scope so it
# can acknowledge/close Azure Monitor alerts as part of the incident lifecycle. This is
# a separate, more-privileged action: it requires Owner or User Access Administrator at
# the SUBSCRIPTION level (not just the resource group), and granting it hands the agent's
# identity the ability to modify monitoring settings across the entire subscription --
# not merely the one demo resource group.
#
# Because of that elevated blast radius, this script does NOT run it automatically.
# Whoever has subscription-level Owner/User Access Administrator access should run this
# deliberately, as a separate, explicit step:
#
#   az role assignment create `
#       --assignee-object-id $UamiObjectId `
#       --assignee-principal-type ServicePrincipal `
#       --role "Monitoring Contributor" `
#       --scope "/subscriptions/$SubscriptionId"
#
# Reference: https://learn.microsoft.com/en-us/azure/sre-agent/permissions
#            (see "Preconfigured roles (always assigned)" table)
# -----------------------------------------------------------------------------------
