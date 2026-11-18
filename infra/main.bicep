// main.bicep
// Subscription-scoped deployment that creates the resource group for the Azure SRE Agent demo
// VM and deploys the networking and VM modules into it.

targetScope = 'subscription'

@description('Azure region for all resources.')
param location string = 'eastus2'

@description('Name of the resource group to create.')
param resourceGroupName string = 'rg-sre-agent-demo'

@description('Name of the demo virtual machine.')
param vmName string = 'vm-sre-demo-01'

@description('VM size. Standard_B2s is the preferred low-cost default, but capacity availability varies by region/subscription - override if you hit a SkuNotAvailable error.')
param vmSize string = 'Standard_B2s'

@description('OS disk storage account type. Must be Standard_LRS/StandardSSD_LRS for non-premium-capable VM sizes (e.g. Dv3 without the "s" suffix).')
param osDiskStorageAccountType string = 'Premium_LRS'

@description('Windows Server 2022 marketplace image SKU. Use a "-g2"/"-core" Gen2 SKU only with Gen2-capable VM sizes (e.g. Dsv3/Bs); use the plain "2022-datacenter" Gen1 SKU for Gen1-only sizes (e.g. Dv3).')
param imageSku string = '2022-datacenter-azure-edition-core'

@description('Local administrator username for the VM.')
param adminUsername string

@description('Local administrator password for the VM.')
@secure()
param adminPassword string

@description('Whether to deploy Azure Bastion (Basic SKU) alongside the VM, which is the only way to reach the VM (the NSG allows no inbound internet traffic). Adds a Standard public IP + Bastion host (~$140/month). Only set to false if you provide another way in.')
param deployBastion bool = true

@description('Name of the Log Analytics Workspace to create.')
param logAnalyticsWorkspaceName string = 'law-sre-agent-demo'

@description('Windows Event Log source name written by the demo app.')
param eventSourceName string = 'SREDemoApp'

@description('Number of Error-level events within 5 minutes that triggers the error-count alert.')
param errorCountThreshold int = 10

@description('CPU percentage (sustained average over 5 minutes) that triggers the CPU metric alert.')
param cpuThresholdPercentage int = 50

@description('Memory "% Committed Bytes In Use" percentage (average over 5 minutes) that triggers the memory alert.')
param memoryThresholdPercentage int = 70

resource rg 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: resourceGroupName
  location: location
}

module networking 'modules/networking.bicep' = {
  name: 'networking'
  scope: rg
  params: {
    location: location
    deployBastion: deployBastion
  }
}

module bastion 'modules/bastion.bicep' = if (deployBastion) {
  name: 'bastion'
  scope: rg
  params: {
    location: location
    bastionSubnetId: networking.outputs.bastionSubnetId
  }
}

module vm 'modules/vm.bicep' = {
  name: 'vm'
  scope: rg
  params: {
    location: location
    vmName: vmName
    subnetId: networking.outputs.subnetId
    nsgId: networking.outputs.nsgId
    vmSize: vmSize
    osDiskStorageAccountType: osDiskStorageAccountType
    imageSku: imageSku
    adminUsername: adminUsername
    adminPassword: adminPassword
  }
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  scope: rg
  params: {
    location: location
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
    vmResourceId: vm.outputs.vmId
    vmName: vm.outputs.vmName
    eventSourceName: eventSourceName
  }
}

module alerts 'modules/alerts.bicep' = {
  name: 'alerts'
  scope: rg
  params: {
    location: location
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    vmResourceId: vm.outputs.vmId
    eventSourceName: eventSourceName
    errorCountThreshold: errorCountThreshold
    cpuThresholdPercentage: cpuThresholdPercentage
    memoryThresholdPercentage: memoryThresholdPercentage
  }
}

@description('Name of the resource group containing the demo VM and networking resources.')
output resourceGroupName string = rg.name

@description('Name of the demo virtual machine.')
output vmName string = vm.outputs.vmName

@description('Public IP address of the demo virtual machine.')
output vmPublicIp string = vm.outputs.publicIpAddress

@description('Resource ID of the demo virtual machine.')
output vmId string = vm.outputs.vmId

@description('Resource ID of the subnet used by the demo VM.')
output subnetId string = networking.outputs.subnetId

@description('Resource ID of the Log Analytics Workspace.')
output logAnalyticsWorkspaceId string = monitoring.outputs.logAnalyticsWorkspaceId

@description('Customer ID (workspace GUID) of the Log Analytics Workspace.')
output logAnalyticsWorkspaceCustomerId string = monitoring.outputs.logAnalyticsWorkspaceCustomerId

@description('DNS name of the Azure Bastion host (e.g. bst-<guid>.bastion.azure.com), empty string if deployBastion is false.')
output bastionFqdn string = bastion.?outputs.?bastionFqdn ?? ''
