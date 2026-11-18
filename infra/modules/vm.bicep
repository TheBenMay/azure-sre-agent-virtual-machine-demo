// vm.bicep
// Windows Server 2022 demo VM with a Standard public IP, NIC (attached to the supplied subnet
// and associated with the supplied NSG), managed boot diagnostics, and a Premium_LRS OS disk.

@description('Azure region for all resources in this module.')
param location string

@description('Name of the virtual machine.')
param vmName string

@description('Resource ID of the subnet to attach the VM NIC to.')
param subnetId string

@description('Resource ID of the NSG to associate with the VM NIC.')
param nsgId string

@description('VM size.')
param vmSize string = 'Standard_B2s'

@description('OS disk storage account type. Premium_LRS requires an "s"-suffixed (premium-storage-capable) VM size; use Standard_LRS/StandardSSD_LRS for non-premium sizes.')
param osDiskStorageAccountType string = 'Premium_LRS'

@description('Local administrator username for the VM.')
param adminUsername string

@description('Local administrator password for the VM.')
@secure()
param adminPassword string

@description('Windows Server 2022 Gen2 marketplace image SKU.')
param imageSku string = '2022-datacenter-azure-edition-core'

var publicIpName = 'pip-${vmName}'
var nicName = 'nic-${vmName}'
var osDiskName = 'osdisk-${vmName}'
var dnsLabel = toLower('${vmName}-${uniqueString(resourceGroup().id, vmName)}')

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: publicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: dnsLabel
    }
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: nicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
    networkSecurityGroup: {
      id: nsgId
    }
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  // System-assigned managed identity is required by the Azure Monitor Agent extension (in
  // monitoring.bicep) to authenticate and fetch its Data Collection Rule config - without it,
  // the AMA extension reports "succeeded" but the actual AMAService process never starts and
  // no telemetry reaches the Log Analytics workspace.
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: imageSku
        version: 'latest'
      }
      osDisk: {
        name: osDiskName
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: osDiskStorageAccountType
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
        // Omitting storageUri enables managed boot diagnostics (no explicit storage account needed).
      }
    }
  }
}

@description('Resource ID of the virtual machine.')
output vmId string = vm.id

@description('Name of the virtual machine.')
output vmName string = vm.name

@description('Public IP address of the VM.')
output publicIpAddress string = publicIp.properties.ipAddress

@description('Fully qualified domain name of the VM public IP.')
output publicIpFqdn string = publicIp.properties.dnsSettings.fqdn
