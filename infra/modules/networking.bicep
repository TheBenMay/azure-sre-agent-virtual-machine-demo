// networking.bicep
// Creates a VNet with a single subnet and an NSG with no custom inbound rules. All inbound
// traffic from the internet is denied by the NSG's implicit DenyAllInBound rule; the VM is reached
// through Azure Bastion (inside the VNet, allowed by the default AllowVnetInBound rule).
//
// Optionally (deployBastion = true, the default) also carves out the mandatory
// "AzureBastionSubnet" (/26 or larger) from a second VNet address range, so bastion.bicep can
// deploy Azure Bastion into this same VNet. This exists because direct inbound RDP/HTTP access to
// the VM's public IP is unreliable from some networks (observed: a corporate VPN/Global Secure
// Access tunnel silently blackholed all inbound traffic to Azure VM public IPs, regardless of
// port) - Bastion provides a portal-based, NSG/public-IP-independent way to reach the VM.

@description('Azure region for all resources in this module.')
param location string

@description('Base name used to derive resource names (VNet, subnet, NSG).')
param baseName string = 'sre-demo'

@description('Address space for the VNet (VM subnet range).')
param vnetAddressPrefix string = '10.20.0.0/24'

@description('Address prefix for the single subnet.')
param subnetAddressPrefix string = '10.20.0.0/24'

@description('Whether to provision the AzureBastionSubnet (required for bastion.bicep). Adds a second VNet address range since the primary /24 is fully consumed by the VM subnet.')
param deployBastion bool = true

@description('Second VNet address range reserved for AzureBastionSubnet (only used if deployBastion is true).')
param bastionVnetAddressPrefix string = '10.20.1.0/24'

@description('Address prefix for AzureBastionSubnet. Must be /26 or larger per Azure Bastion requirements (only used if deployBastion is true).')
param bastionSubnetAddressPrefix string = '10.20.1.0/26'

var vnetName = 'vnet-${baseName}'
var subnetName = 'snet-${baseName}'
var nsgName = 'nsg-${baseName}'

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: nsgName
  location: location
  properties: {
    // No custom rules: the default DenyAllInBound rule (priority 65500) blocks inbound
    // internet traffic, while the default AllowVnetInBound rule lets Azure Bastion reach the VM.
    securityRules: []
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: deployBastion ? [
        vnetAddressPrefix
        bastionVnetAddressPrefix
      ] : [
        vnetAddressPrefix
      ]
    }
    subnets: deployBastion ? [
      {
        name: subnetName
        properties: {
          addressPrefix: subnetAddressPrefix
        }
      }
      {
        // Name is a hard Azure requirement - Bastion only attaches to a subnet literally
        // named "AzureBastionSubnet".
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: bastionSubnetAddressPrefix
        }
      }
    ] : [
      {
        name: subnetName
        properties: {
          addressPrefix: subnetAddressPrefix
        }
      }
    ]
    // NSG is associated at the NIC level in vm.bicep (not at the subnet level) so that
    // this module can be reused independently of how/where the NSG gets attached.
  }
}

@description('Resource ID of the subnet the VM NIC should attach to.')
output subnetId string = vnet.properties.subnets[0].id

@description('Resource ID of the NSG applied to the subnet.')
output nsgId string = nsg.id

@description('Resource ID of AzureBastionSubnet, or empty string if deployBastion is false.')
output bastionSubnetId string = deployBastion ? vnet.properties.subnets[1].id : ''
